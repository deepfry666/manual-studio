import Foundation

/// 最小的 ZIP 写入器（docx 和交付包 zip 用）：文件用 DEFLATE 压缩。
public struct ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let method: UInt16
        let offset: UInt32
        let isDirectory: Bool
    }

    private var output = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16((components.hour ?? 0) << 11 | (components.minute ?? 0) << 5 | (components.second ?? 0) / 2)
        dosDate = UInt16(max(0, (components.year ?? 1980) - 1980) << 9 | (components.month ?? 1) << 5 | (components.day ?? 1))
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    public mutating func addDirectory(_ name: String) {
        let path = name.hasSuffix("/") ? name : name + "/"
        add(name: path, data: Data(), compress: false, isDirectory: true)
    }

    public mutating func addFile(_ name: String, _ data: Data, compress: Bool = true) {
        add(name: name, data: data, compress: compress, isDirectory: false)
    }

    public mutating func addFile(_ name: String, _ text: String) {
        addFile(name, Data(text.utf8))
    }

    private mutating func add(name: String, data: Data, compress: Bool, isDirectory: Bool) {
        let nameData = Data(name.utf8)
        let crc = Compress.crc32(data)
        var payload = data
        var method: UInt16 = 0
        if compress, !data.isEmpty, let deflated = try? Compress.deflate(data, raw: true) {
            payload = deflated
            method = 8
        }
        let offset = UInt32(output.count)
        var header = Data()
        header += ZipWriter.le32(0x04034b50)
        header += ZipWriter.le16(20)
        header += ZipWriter.le16(0x0800) // 文件名是 UTF-8
        header += ZipWriter.le16(method)
        header += ZipWriter.le16(dosTime)
        header += ZipWriter.le16(dosDate)
        header += ZipWriter.le32(crc)
        header += ZipWriter.le32(UInt32(payload.count))
        header += ZipWriter.le32(UInt32(data.count))
        header += ZipWriter.le16(UInt16(nameData.count))
        header += ZipWriter.le16(0)
        output += header
        output += nameData
        output += payload
        entries.append(Entry(name: nameData, crc: crc, compressedSize: UInt32(payload.count), size: UInt32(data.count), method: method, offset: offset, isDirectory: isDirectory))
    }

    public func finish() -> Data {
        var result = output
        let directoryOffset = UInt32(result.count)
        var directory = Data()
        for entry in entries {
            directory += ZipWriter.le32(0x02014b50)
            directory += ZipWriter.le16(0x0314) // made by: Unix, 2.0
            directory += ZipWriter.le16(20)
            directory += ZipWriter.le16(0x0800)
            directory += ZipWriter.le16(entry.method)
            directory += ZipWriter.le16(dosTime)
            directory += ZipWriter.le16(dosDate)
            directory += ZipWriter.le32(entry.crc)
            directory += ZipWriter.le32(entry.compressedSize)
            directory += ZipWriter.le32(entry.size)
            directory += ZipWriter.le16(UInt16(entry.name.count))
            directory += ZipWriter.le16(0)
            directory += ZipWriter.le16(0)
            directory += ZipWriter.le16(0)
            directory += ZipWriter.le16(0)
            directory += ZipWriter.le32(entry.isDirectory ? (0o040755 << 16) | 0x10 : (0o100644 << 16))
            directory += ZipWriter.le32(entry.offset)
            directory += entry.name
        }
        result += directory
        result += ZipWriter.le32(0x06054b50)
        result += ZipWriter.le16(0)
        result += ZipWriter.le16(0)
        result += ZipWriter.le16(UInt16(entries.count))
        result += ZipWriter.le16(UInt16(entries.count))
        result += ZipWriter.le32(UInt32(directory.count))
        result += ZipWriter.le32(directoryOffset)
        result += ZipWriter.le16(0)
        return result
    }
}

/// 最小的 ZIP 读取器（核对 docx 内容用）。
public struct ZipReader {
    public struct Entry: Sendable {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localOffset: Int
        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    public let data: Data
    public let entries: [Entry]

    public init(_ data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard bytes.count >= 22 else { throw StudioError("不是有效的 ZIP 文件") }
        var end = -1
        var index = bytes.count - 22
        while index >= max(0, bytes.count - 65_557) {
            if u32(index) == 0x06054b50 { end = index; break }
            index -= 1
        }
        guard end >= 0 else { throw StudioError("不是有效的 ZIP 文件") }
        let count = u16(end + 10)
        var offset = u32(end + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x02014b50 else { throw StudioError("ZIP 目录损坏") }
            let method = UInt16(u16(offset + 10))
            let compressedSize = u32(offset + 20)
            let size = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let localOffset = u32(offset + 42)
            guard offset + 46 + nameLength <= bytes.count else { throw StudioError("ZIP 目录损坏") }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compressedSize, size: size, localOffset: localOffset))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    public func read(_ entry: Entry) throws -> Data {
        let bytes = data
        let start = data.startIndex + entry.localOffset
        guard start + 30 <= bytes.endIndex else { throw StudioError("ZIP 条目损坏") }
        func u16(_ offset: Int) -> Int { Int(bytes[start + offset]) | Int(bytes[start + offset + 1]) << 8 }
        let nameLength = u16(26)
        let extraLength = u16(28)
        let payloadStart = start + 30 + nameLength + extraLength
        guard payloadStart + entry.compressedSize <= bytes.endIndex else { throw StudioError("ZIP 条目损坏") }
        let payload = bytes[payloadStart..<(payloadStart + entry.compressedSize)]
        switch entry.method {
        case 0: return Data(payload)
        case 8: return try Compress.inflate(Data(payload), raw: true, maxOutput: max(entry.size, 1) * 2 + 1024)
        default: throw StudioError("不支持的 ZIP 压缩方式 \(entry.method)")
        }
    }

    public func read(_ name: String) throws -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return try read(entry)
    }
}
