import Foundation
import zlib

public enum Compress {
    public static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer -> UInt32 in
            guard let base = buffer.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, base, uInt(buffer.count)))
        }
    }

    /// raw=true 是裸 DEFLATE（ZIP 用），false 是带 zlib 头的流（PNG 用）。
    public static func deflate(_ data: Data, raw: Bool, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(&stream, level, Z_DEFLATED, raw ? -MAX_WBITS : MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw StudioError("压缩初始化失败") }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))) + 64)
        let produced: Int = try data.withUnsafeBytes { input in
            try output.withUnsafeMutableBytes { out in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(out.count)
                status = zlib.deflate(&stream, Z_FINISH)
                guard status == Z_STREAM_END else { throw StudioError("压缩失败（\(status)）") }
                return Int(stream.total_out)
            }
        }
        output.count = produced
        return output
    }

    /// 解压；maxOutput 限制最大输出（防止解压炸弹）。
    public static func inflate(_ data: Data, raw: Bool, maxOutput: Int? = nil) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(&stream, raw ? -MAX_WBITS : MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw StudioError("解压初始化失败") }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunkSize = 1 << 16
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            repeat {
                let written: Int = chunk.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if status != Z_OK && status != Z_STREAM_END && !(status == Z_BUF_ERROR && written > 0) {
                    throw StudioError("数据解压失败（\(status)）")
                }
                output.append(contentsOf: chunk[0..<written])
                if let maxOutput, output.count > maxOutput { throw StudioError("解压后的数据超过上限") }
                if written == 0 && status != Z_STREAM_END { if stream.avail_in == 0 { break } }
            } while status != Z_STREAM_END
        }
        return output
    }
}
