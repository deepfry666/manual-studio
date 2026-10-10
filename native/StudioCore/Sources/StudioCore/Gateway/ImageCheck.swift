import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let PNG_SIGNATURE = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
let MAX_EDGE = 8192
let MAX_PIXELS = 40_000_000

public func detectImageType(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    if bytes.count >= 8, Data(bytes[0..<8]) == PNG_SIGNATURE { return "png" }
    if bytes.count >= 3, bytes[0] == 0xff, bytes[1] == 0xd8, bytes[2] == 0xff { return "jpeg" }
    if bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF", String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" { return "webp" }
    if bytes.count >= 6, String(decoding: bytes[0..<3], as: UTF8.self) == "GIF" { return "gif" }
    return nil
}

/// 非 PNG 用系统的 ImageIO 转成 PNG（JPEG、WebP、GIF 都能读）。
public func convertToPng(_ data: Data) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw StudioError("系统无法读取这张图")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw StudioError("无法生成 PNG") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw StudioError("无法生成 PNG") }
    return output as Data
}

/// 给看图模型用的缩小版（宽 720 的 JPEG，质量 80），省流量也省钱。
public func visionDataUrl(_ file: String) throws -> String {
    let data = try FS.read(file)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        throw StudioError("截图无法读取")
    }
    let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
    var image: CGImage?
    if width > 720 {
        let maxEdge = Int((Double(max(width, height)) * 720 / Double(width)).rounded())
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    } else {
        image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    guard let image else { throw StudioError("截图无法读取") }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw StudioError("截图无法转换") }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw StudioError("截图无法转换") }
    return "data:image/jpeg;base64,\((output as Data).base64EncodedString())"
}

public struct PngInfo: Sendable {
    public let width: Int
    public let height: Int
    public let blank: Bool?
}

private func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
    let p = a + b - c
    let pa = abs(p - a)
    let pb = abs(p - b)
    let pc = abs(p - c)
    if pa <= pb && pa <= pc { return a }
    return pb <= pc ? b : c
}

private func unfilter(_ raw: [UInt8], _ width: Int, _ height: Int, _ bpp: Int) throws -> [UInt8] {
    let stride = width * bpp
    guard raw.count == (stride + 1) * height else { throw StudioError("PNG 像素数据长度不符") }
    var pixels = [UInt8](repeating: 0, count: stride * height)
    var input = 0
    for y in 0..<height {
        let filter = raw[input]
        input += 1
        guard filter <= 4 else { throw StudioError("不支持的 PNG 滤波类型 \(filter)") }
        let row = y * stride
        for x in 0..<stride {
            let value = Int(raw[input])
            input += 1
            let left = x >= bpp ? Int(pixels[row + x - bpp]) : 0
            let up = y > 0 ? Int(pixels[row - stride + x]) : 0
            let upLeft = y > 0 && x >= bpp ? Int(pixels[row - stride + x - bpp]) : 0
            var decoded = value
            switch filter {
            case 1: decoded += left
            case 2: decoded += up
            case 3: decoded += (left + up) / 2
            case 4: decoded += paeth(left, up, upLeft)
            default: break
            }
            pixels[row + x] = UInt8(decoded & 0xff)
        }
    }
    return pixels
}

/// 解析 PNG 并做空白检测（逻辑来自旧 skill 的校验器）。
public func inspectPng(_ data: Data) throws -> PngInfo {
    let buffer = [UInt8](data)
    guard buffer.count >= 33, Data(buffer[0..<8]) == PNG_SIGNATURE else { throw StudioError("不是有效的 PNG 文件") }
    func u32(_ offset: Int) -> Int { Int(buffer[offset]) << 24 | Int(buffer[offset + 1]) << 16 | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3]) }
    var offset = 8
    var width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0
    var palette: [UInt8]?
    var sawEnd = false
    var idat = Data()
    var sawIdat = false
    while offset + 12 <= buffer.count {
        let length = u32(offset)
        let end = offset + 12 + length
        guard end <= buffer.count else { throw StudioError("PNG 文件被截断") }
        let typeBytes = Data(buffer[(offset + 4)..<(offset + 8)])
        let type = String(decoding: typeBytes, as: UTF8.self)
        let chunk = buffer[(offset + 8)..<(offset + 8 + length)]
        guard Compress.crc32(typeBytes + Data(chunk)) == UInt32(u32(offset + 8 + length)) else { throw StudioError("PNG \(type) 块校验失败") }
        if type == "IHDR" {
            let base = offset + 8
            width = u32(base)
            height = u32(base + 4)
            bitDepth = Int(buffer[base + 8])
            colorType = Int(buffer[base + 9])
            interlace = Int(buffer[base + 12])
            guard width > 0, height > 0 else { throw StudioError("PNG 宽或高为 0") }
            if width > MAX_EDGE || height > MAX_EDGE || width * height > MAX_PIXELS { throw StudioError("PNG 尺寸过大：\(width)x\(height)") }
        } else if type == "PLTE" {
            palette = Array(chunk)
        } else if type == "IDAT" {
            idat.append(contentsOf: chunk)
            sawIdat = true
        } else if type == "IEND" {
            sawEnd = true
            break
        }
        offset = end
    }
    guard width > 0, sawIdat, sawEnd else { throw StudioError("PNG 缺少必要的数据块") }

    var blank: Bool?
    let bppByType = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4]
    if bitDepth == 8, interlace == 0, let bpp = bppByType[colorType] {
        let raw = [UInt8](try Compress.inflate(idat, raw: false, maxOutput: (width * bpp + 1) * height))
        let pixels = try unfilter(raw, width, height, bpp)
        var minimum = [255, 255, 255]
        var maximum = [0, 0, 0]
        var visible = 0
        let step = max(1, (width * height) / 200_000)
        var index = 0
        while index < width * height {
            defer { index += step }
            let position = index * bpp
            var rgb: [Int]
            var alpha = 255
            if colorType == 0 || colorType == 4 {
                rgb = [Int(pixels[position]), Int(pixels[position]), Int(pixels[position])]
                if colorType == 4 { alpha = Int(pixels[position + 1]) }
            } else if colorType == 2 || colorType == 6 {
                rgb = [Int(pixels[position]), Int(pixels[position + 1]), Int(pixels[position + 2])]
                if colorType == 6 { alpha = Int(pixels[position + 3]) }
            } else if let palette {
                let p = Int(pixels[position]) * 3
                rgb = [p < palette.count ? Int(palette[p]) : 0, p + 1 < palette.count ? Int(palette[p + 1]) : 0, p + 2 < palette.count ? Int(palette[p + 2]) : 0]
            } else {
                continue
            }
            if alpha <= 8 { continue }
            visible += 1
            for c in 0..<3 {
                if rgb[c] < minimum[c] { minimum[c] = rgb[c] }
                if rgb[c] > maximum[c] { maximum[c] = rgb[c] }
            }
        }
        blank = visible == 0 || (maximum[0] - minimum[0] <= 3 && maximum[1] - minimum[1] <= 3 && maximum[2] - minimum[2] <= 3)
    }
    return PngInfo(width: width, height: height, blank: blank)
}

public struct ImageCheck: Sendable {
    public var ok: Bool
    public var png: Data?
    public var width: Int?
    public var height: Int?
    public var warnings: [String] = []
    public var reason: String?
}

/// 技术验收：能解码、不是空白、是竖屏手机界面比例。
public func checkScreenImage(_ data: Data, toPng: (Data) throws -> Data = convertToPng) -> ImageCheck {
    guard let type = detectImageType(data) else { return ImageCheck(ok: false, reason: "返回的不是图片") }
    var png = data
    if type != "png" {
        do { png = try toPng(data) } catch { return ImageCheck(ok: false, reason: "图片无法转换为 PNG：\(messageOf(error))") }
    }
    let info: PngInfo
    do { info = try inspectPng(png) } catch { return ImageCheck(ok: false, reason: "图片无法解码：\(messageOf(error))") }
    var warnings: [String] = []
    if info.blank == true { return ImageCheck(ok: false, width: info.width, height: info.height, reason: "图片是空白的") }
    let aspect = Double(info.height) / Double(info.width)
    if aspect < 1.5 || aspect > 2.7 {
        return ImageCheck(ok: false, width: info.width, height: info.height, reason: "不是竖屏手机界面比例（\(info.width)x\(info.height)）")
    }
    if aspect < 1.8 || aspect > 2.4 { warnings.append("宽高比 \(String(format: "%.2f", aspect)) 偏离常见手机长屏") }
    if info.width < 500 { warnings.append("宽度只有 \(info.width)px，清晰度可能不够") }
    return ImageCheck(ok: true, png: png, width: info.width, height: info.height, warnings: warnings)
}

// MARK: - 生成 PNG（测试看图模型、测试用图）

private func pngChunk(_ type: String, _ data: Data) -> Data {
    var length = UInt32(data.count).bigEndian
    var output = Data(bytes: &length, count: 4)
    let body = Data(type.utf8) + data
    output += body
    var crc = Compress.crc32(body).bigEndian
    output += Data(bytes: &crc, count: 4)
    return output
}

public func encodeRGBPng(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Data {
    var raw = Data(count: (width * 3 + 1) * height)
    raw.withUnsafeMutableBytes { buffer in
        let bytes = buffer.bindMemory(to: UInt8.self)
        for y in 0..<height {
            let row = y * (width * 3 + 1)
            bytes[row] = 0
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                bytes[row + 1 + x * 3] = r
                bytes[row + 2 + x * 3] = g
                bytes[row + 3 + x * 3] = b
            }
        }
    }
    var header = Data(count: 13)
    header[0] = UInt8((width >> 24) & 0xff); header[1] = UInt8((width >> 16) & 0xff); header[2] = UInt8((width >> 8) & 0xff); header[3] = UInt8(width & 0xff)
    header[4] = UInt8((height >> 24) & 0xff); header[5] = UInt8((height >> 16) & 0xff); header[6] = UInt8((height >> 8) & 0xff); header[7] = UInt8(height & 0xff)
    header[8] = 8
    header[9] = 2
    return PNG_SIGNATURE + pngChunk("IHDR", header) + pngChunk("IDAT", (try? Compress.deflate(raw, raw: false)) ?? Data()) + pngChunk("IEND", Data())
}

/// 生成一张纯色 PNG（用于测试看图模型是否可用）。
public func solidPng(_ width: Int, _ height: Int, _ color: (UInt8, UInt8, UInt8)) -> Data {
    encodeRGBPng(width: width, height: height) { _, _ in color }
}
