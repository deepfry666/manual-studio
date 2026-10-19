import Foundation
import CryptoKit
import Synchronization

/// 带中文说明的错误（直接显示给用户）。
public struct StudioError: Error, LocalizedError, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// 报错里不直接写临时文件夹路径（对用户没用），而是挂一个标记，界面上换成「查看诊断文件」按钮。
public func diagnosticsTag(_ path: String) -> String { "\n[诊断文件:\(path)]" }

public func splitDiagnostics(_ message: String) -> (text: String, path: String?) {
    guard let match = Rx.match(#"\n?\[诊断文件:([^\]]+)\]\s*$"#, message), let path = match[1] else { return (message, nil) }
    return (message.replacingOccurrences(of: match[0] ?? "", with: ""), path)
}

/// 错误的中文说明（和 JS 的 error.message 一致）。
public func messageOf(_ error: Error) -> String {
    if let error = error as? LocalizedError, let text = error.errorDescription { return text }
    return String(describing: error)
}

// MARK: - 路径（和 node:path 一致的几个函数）

public enum Path {
    public static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = parts.last, last != ".." { parts.removeLast() } else if !absolute { parts.append("..") }
                continue
            }
            parts.append(String(part))
        }
        let joined = parts.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    public static func join(_ parts: String...) -> String { join(parts) }
    public static func join(_ parts: [String]) -> String {
        normalize(parts.filter { !$0.isEmpty }.joined(separator: "/"))
    }

    public static func resolve(_ path: String) -> String {
        path.hasPrefix("/") ? normalize(path) : normalize(FileManager.default.currentDirectoryPath + "/" + path)
    }

    public static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") }

    public static func basename(_ path: String, _ ext: String? = nil) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        var name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        if let ext, !ext.isEmpty, name.hasSuffix(ext), name != ext { name = String(name.dropLast(ext.count)) }
        return name
    }

    public static func dirname(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let index = trimmed.lastIndex(of: "/") else { return "." }
        let head = String(trimmed[..<index])
        return head.isEmpty ? "/" : head
    }

    public static func extname(_ path: String) -> String {
        let name = basename(path)
        guard let index = name.lastIndex(of: "."), index != name.startIndex else { return "" }
        return String(name[index...])
    }

    public static func relative(_ from: String, _ to: String) -> String {
        let a = resolve(from).split(separator: "/").map(String.init)
        let b = resolve(to).split(separator: "/").map(String.init)
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        let ups = Array(repeating: "..", count: a.count - common)
        return (ups + b[common...]).joined(separator: "/")
    }

    public static func isInside(_ parent: String, _ candidate: String) -> Bool {
        let relative = relative(parent, candidate)
        return relative.isEmpty || (!relative.hasPrefix("..") && !isAbsolute(relative))
    }
}

// MARK: - 文件

public enum FS {
    public static var fileManager: FileManager { FileManager.default }

    public static func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: path) }

    public static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    public static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    public static func mkdirp(_ path: String) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public static func read(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw StudioError("文件不存在或无法读取：\(path)")
        }
    }

    public static func readText(_ path: String) throws -> String {
        let data = try read(path)
        return String(decoding: data, as: UTF8.self)
    }

    public static func readTextIfExists(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 读 JSON：文件不存在返回 nil；内容损坏时报错（和 Electron 版一样）。
    public static func readJSON(_ path: String) throws -> JSON? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        do {
            return try JSON.parse(String(decoding: data, as: UTF8.self))
        } catch {
            throw StudioError("JSON 文件损坏：\(path)（\(messageOf(error))）")
        }
    }

    /// 读 JSON，任何问题都返回 nil（对应 `readJson(...).catch(() => null)`）。
    public static func readJSONQuiet(_ path: String) -> JSON? {
        (try? readJSON(path)) ?? nil
    }

    /// 先写临时文件再改名，中途崩溃也不会留下半截文件。
    public static func writeAtomic(_ path: String, _ data: Data, mode: Int? = nil) throws {
        try mkdirp(Path.dirname(path))
        let temp = "\(path).\(ProcessInfo.processInfo.processIdentifier).\(randomHex(4)).tmp"
        var attributes: [FileAttributeKey: Any]? = nil
        if let mode { attributes = [.posixPermissions: mode] }
        guard fileManager.createFile(atPath: temp, contents: data, attributes: attributes) else {
            throw StudioError("无法写入文件：\(path)")
        }
        if rename(temp, path) != 0 {
            try? fileManager.removeItem(atPath: temp)
            throw StudioError("无法写入文件：\(path)（\(String(cString: strerror(errno)))）")
        }
    }

    public static func writeAtomic(_ path: String, _ text: String, mode: Int? = nil) throws {
        try writeAtomic(path, Data(text.utf8), mode: mode)
    }

    /// `JSON.stringify(value, null, 2) + "\n"`
    public static func writeJSONAtomic(_ path: String, _ value: JSON, mode: Int? = nil) throws {
        try writeAtomic(path, value.serialized(pretty: true) + "\n", mode: mode)
    }

    public static func write(_ path: String, _ data: Data) throws {
        try mkdirp(Path.dirname(path))
        try data.write(to: URL(fileURLWithPath: path))
    }

    public static func write(_ path: String, _ text: String) throws {
        try write(path, Data(text.utf8))
    }

    public static func appendJSONLine(_ path: String, _ value: JSON) throws {
        try mkdirp(Path.dirname(path))
        let line = Data((value.serialized() + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 只追加的 JSONL：跳过崩溃时写了一半的行。
    public static func readJSONLines(_ path: String) -> [JSON] {
        guard let text = readTextIfExists(path) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let trimmed = String(line).jsTrimmed
            guard !trimmed.isEmpty else { return nil }
            return try? JSON.parse(trimmed)
        }
    }

    /// 文件夹里的条目名（不含 . 和 ..），读不了返回 nil。
    public static func list(_ path: String) -> [String]? {
        try? fileManager.contentsOfDirectory(atPath: path)
    }

    public static func remove(_ path: String) {
        try? fileManager.removeItem(atPath: path)
    }

    public static func copy(_ from: String, _ to: String) throws {
        if exists(to) { try fileManager.removeItem(atPath: to) }
        try fileManager.copyItem(atPath: from, toPath: to)
    }

    /// 改名；跨卷时退回复制 + 删除。
    public static func move(_ from: String, _ to: String) throws {
        if Darwin.rename(from, to) == 0 { return }
        if errno == EXDEV {
            try fileManager.copyItem(atPath: from, toPath: to)
            try fileManager.removeItem(atPath: from)
            return
        }
        throw StudioError("无法移动 \(from) → \(to)：\(String(cString: strerror(errno)))")
    }

    public static func size(_ path: String) -> Int? {
        (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
    }

    /// 修改时间（毫秒）。
    public static func mtimeMs(_ path: String) -> Double? {
        guard let date = try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    public static func makeTempDirectory(prefix: String) throws -> String {
        let path = Path.join(NSTemporaryDirectory(), "\(prefix)\(randomHex(4))")
        try mkdirp(path)
        return path
    }
}

// MARK: - 哈希、时间、随机

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }

public func sha256File(_ path: String) throws -> String { sha256Hex(try FS.read(path)) }

public func sha1Hex(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 对象哈希：键排序后的 JSON 再算 SHA-256（和 Electron 版一致，导入的项目不会被误判为「有改动」）。
public func hashObject(_ value: JSON) -> String { sha256Hex(value.stableStringify()) }

public func randomHex(_ bytes: Int) -> String {
    (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
}

nonisolated(unsafe) private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let isoLock = NSLock()

/// `new Date().toISOString()`
public func isoString(_ date: Date = Date()) -> String {
    isoLock.lock()
    defer { isoLock.unlock() }
    return isoFormatter.string(from: date)
}

public func isoNow() -> String { isoString(Date()) }

/// `Date.parse(iso)`（毫秒），解析不了返回 nil。
public func parseISO(_ text: String?) -> Double? {
    guard let text else { return nil }
    // 软件自己写的时间都是 2026-10-16T06:26:35.359Z 这种格式：直接按位置算，比系统的日期解析快几十倍（列表每次刷新要解析上千个）
    if let fast = fastParseISO(text) { return fast }
    isoLock.lock()
    defer { isoLock.unlock() }
    if let date = isoFormatter.date(from: text) { return date.timeIntervalSince1970 * 1000 }
    let plain = ISO8601DateFormatter()
    return plain.date(from: text).map { $0.timeIntervalSince1970 * 1000 }
}

/// 只认 UTC 的 `YYYY-MM-DDTHH:MM:SS[.fff]Z`，别的格式返回 nil 交给系统解析。
func fastParseISO(_ text: String) -> Double? {
    let bytes = Array(text.utf8)
    guard bytes.count == 20 || bytes.count == 24, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58, bytes.last == 90 else { return nil }
    func number(_ from: Int, _ count: Int) -> Int? {
        var value = 0
        for index in from..<(from + count) {
            let digit = Int(bytes[index]) - 48
            guard (0...9).contains(digit) else { return nil }
            value = value * 10 + digit
        }
        return value
    }
    guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2), let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
          (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
    var millis = 0
    if bytes.count == 24 {
        guard bytes[19] == 46, let fraction = number(20, 3) else { return nil }
        millis = fraction
    }
    // 公历日期换算成 1970-01-01 起的天数（Howard Hinnant 的 days_from_civil）
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    return Double(((days * 24 + hour) * 60 + minute) * 60 + second) * 1000 + Double(millis)
}

/// `date.toISOString().replace(/[:.]/g, "-")`
public func timestampSlug(_ date: Date = Date()) -> String {
    isoString(date).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
}

public func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

// MARK: - 串行队列（同一个文件的写操作排队执行）

public final class SerialQueue: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)

    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task: Task<T, Error> = tail.withLock { tail in
            let previous = tail
            let task = Task<T, Error> {
                await previous?.value
                return try await operation()
            }
            tail = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }
}

/// 加锁的可变状态（同步读写，供 actor 外的同步查询用）。
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    @discardableResult
    public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }
}
