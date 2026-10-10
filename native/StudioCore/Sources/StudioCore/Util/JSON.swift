import Foundation

/// 有序的 JSON 对象：键的顺序和写入顺序一致（和 JS 对象一样），
/// 这样写回文件、算哈希时和 Electron 版逐字节一致。
public struct JSONObject: Sendable, Hashable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> JSON? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var values: [JSON] { keys.map { storage[$0]! } }

    public func makeIterator() -> AnyIterator<(key: String, value: JSON)> {
        var index = 0
        return AnyIterator {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            let key = keys[index]
            return (key, storage[key]!)
        }
    }

    public func contains(_ key: String) -> Bool { storage[key] != nil }

    /// `{ ...a, ...b }`：已有的键保持原位置，新键追加在后面。
    public func merging(_ other: JSONObject) -> JSONObject {
        var result = self
        for (key, value) in other { result[key] = value }
        return result
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.keys == rhs.keys && lhs.storage == rhs.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keys)
        for key in keys { hasher.combine(storage[key]) }
    }
}

/// 动态 JSON 值。项目状态、content.json、规划文件等都按 JS 的方式直接读写，未知字段原样保留。
public enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    // MARK: 访问

    public subscript(key: String) -> JSON? {
        get {
            if case .object(let object) = self { return object[key] }
            return nil
        }
        set {
            switch self {
            case .object(var object):
                object[key] = newValue
                self = .object(object)
            case .null:
                guard let newValue else { return }
                var object = JSONObject()
                object[key] = newValue
                self = .object(object)
            default:
                break
            }
        }
    }

    public subscript(index: Int) -> JSON? {
        get {
            if case .array(let array) = self, index >= 0, index < array.count { return array[index] }
            return nil
        }
        set {
            guard case .array(var array) = self, index >= 0, index < array.count else { return }
            array[index] = newValue ?? .null
            self = .array(array)
        }
    }

    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var int: Int? {
        if case .number(let value) = self, value.isFinite { return Int(exactly: value.rounded(.towardZero)) }
        return nil
    }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var array: [JSON]? { if case .array(let value) = self { return value }; return nil }
    public var object: JSONObject? { if case .object(let value) = self { return value }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
    public var isObject: Bool { object != nil }
    public var isArray: Bool { array != nil }

    /// JS 的真假判断：null、false、0、NaN、"" 为假。
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .number(let value): return value != 0 && !value.isNaN
        case .string(let value): return !value.isEmpty
        case .array, .object: return true
        }
    }

    /// JS 的 `String(x)`。
    public var jsString: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return JSON.formatNumber(value)
        case .string(let value): return value
        case .array(let items): return items.map { $0.isNull ? "" : $0.jsString }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// 字符串数组（非字符串的元素跳过）。
    public var stringArray: [String] { (array ?? []).compactMap(\.string) }

    // MARK: 构造

    public init(_ value: String) { self = .string(value) }
    public init(_ value: Int) { self = .number(Double(value)) }
    public init(_ value: Double) { self = .number(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ values: [String]) { self = .array(values.map(JSON.string)) }
    public init(_ value: String?) { self = value.map(JSON.string) ?? .null }
    public init(_ value: Int?) { self = value.map { .number(Double($0)) } ?? .null }

    /// 按顺序建对象；值为 nil 的键省略（相当于 JS 的 undefined）。
    public static func obj(_ pairs: KeyValuePairs<String, JSON?>) -> JSON {
        var object = JSONObject()
        for (key, value) in pairs { if let value { object[key] = value } }
        return .object(object)
    }

    public static func obj(_ pairs: [(String, JSON?)]) -> JSON {
        var object = JSONObject()
        for (key, value) in pairs { if let value { object[key] = value } }
        return .object(object)
    }

    public static var emptyObject: JSON { .object(JSONObject()) }

    /// 可选值 → JSON（nil 表示省略这个键）。
    public static func maybe(_ value: Int?) -> JSON? { value.map { .number(Double($0)) } }
    public static func maybe(_ value: Double?) -> JSON? { value.map { .number($0) } }
    public static func maybe(_ value: String?) -> JSON? { value.map { .string($0) } }
    public static func maybe(_ value: Bool?) -> JSON? { value.map { .bool($0) } }
    /// 可选值 → JSON（nil 写成 null）。
    public static func orNull(_ value: Int?) -> JSON { maybe(value) ?? .null }
    public static func orNull(_ value: Double?) -> JSON { maybe(value) ?? .null }
    public static func orNull(_ value: String?) -> JSON { maybe(value) ?? .null }
    public static func orNull(_ value: Bool?) -> JSON { maybe(value) ?? .null }

    /// `{ ...self, ...other }`
    public func merging(_ other: JSON?) -> JSON {
        guard let other = other?.object else { return self }
        return .object((object ?? JSONObject()).merging(other))
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - 序列化（和 JS 的 JSON.stringify 一致）

extension JSON {
    /// JS 的 `Number.prototype.toString()`。
    public static func formatNumber(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        let negative = value < 0
        let description = String(describing: abs(value))
        var mantissa = description
        var exponent = 0
        if let index = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(description[..<index])
            exponent = Int(description[description.index(after: index)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = String(parts[0])
        let fractionPart = parts.count > 1 ? String(parts[1]) : ""
        var digits = integerPart + fractionPart
        var leadingZeros = 0
        while digits.hasPrefix("0") {
            digits.removeFirst()
            leadingZeros += 1
        }
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.isEmpty { return "0" }
        let n = integerPart.count - leadingZeros + exponent
        let k = digits.count
        var result: String
        if k <= n && n <= 21 {
            result = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let index = digits.index(digits.startIndex, offsetBy: n)
            result = digits[..<index] + "." + digits[index...]
        } else if -6 < n && n <= 0 {
            result = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let sign = n - 1 >= 0 ? "+" : "-"
            let first = digits.prefix(1)
            let rest = digits.dropFirst()
            result = first + (rest.isEmpty ? "" : "." + rest) + "e" + sign + String(abs(n - 1))
        }
        return negative ? "-" + result : result
    }

    static func quote(_ value: String) -> String {
        var output = "\""
        output.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
        return output
    }

    /// `JSON.stringify(value)`；pretty 时等同 `JSON.stringify(value, null, 2)`。
    public func serialized(pretty: Bool = false) -> String {
        var output = ""
        write(into: &output, pretty: pretty, indent: "")
        return output
    }

    private func write(into output: inout String, pretty: Bool, indent: String) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let value): output += value.isFinite ? JSON.formatNumber(value) : "null"
        case .string(let value): output += JSON.quote(value)
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            let inner = indent + "  "
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                if pretty { output += "\n" + inner }
                item.write(into: &output, pretty: pretty, indent: inner)
            }
            if pretty { output += "\n" + indent }
            output += "]"
        case .object(let object):
            if object.isEmpty { output += "{}"; return }
            let inner = indent + "  "
            output += "{"
            var first = true
            for (key, value) in object {
                if !first { output += "," }
                first = false
                if pretty { output += "\n" + inner }
                output += JSON.quote(key)
                output += pretty ? ": " : ":"
                value.write(into: &output, pretty: pretty, indent: inner)
            }
            if pretty { output += "\n" + indent }
            output += "}"
        }
    }

    /// 键排序后的序列化，用于算哈希（和 Electron 版的 stableStringify 一致）。
    public func stableStringify() -> String {
        switch self {
        case .array(let items): return "[" + items.map { $0.stableStringify() }.joined(separator: ",") + "]"
        case .object(let object):
            let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + keys.map { JSON.quote($0) + ":" + object[$0]!.stableStringify() }.joined(separator: ",") + "}"
        default: return serialized()
        }
    }
}

// MARK: - 解析（保留键顺序）

public struct JSONParseError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

extension JSON {
    public static func parse(_ text: String) throws -> JSON {
        var parser = JSONParser(scalars: Array(text.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        if parser.index < parser.scalars.count { throw JSONParseError(message: "Unexpected non-whitespace character after JSON at position \(parser.index)") }
        return value
    }

    public static func parse(_ data: Data) throws -> JSON {
        guard let text = String(data: data, encoding: .utf8) else { throw JSONParseError(message: "不是 UTF-8 文本") }
        return try parse(text)
    }
}

private struct JSONParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    mutating func skipWhitespace() {
        while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
    }

    func error(_ message: String) -> JSONParseError {
        JSONParseError(message: index < scalars.count ? "\(message) at position \(index)" : "Unexpected end of JSON input")
    }

    mutating func parseValue() throws -> JSON {
        guard index < scalars.count else { throw error("Unexpected end") }
        switch scalars[index] {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t": try expect("true"); return .bool(true)
        case "f": try expect("false"); return .bool(false)
        case "n": try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: String) throws {
        for scalar in word.unicodeScalars {
            guard index < scalars.count, scalars[index] == scalar else { throw error("Unexpected token") }
            index += 1
        }
    }

    mutating func parseObject() throws -> JSON {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < scalars.count, scalars[index] == "}" { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard index < scalars.count, scalars[index] == "\"" else { throw error("Expected property name") }
            let key = try parseString()
            skipWhitespace()
            guard index < scalars.count, scalars[index] == ":" else { throw error("Expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard index < scalars.count else { throw error("Unterminated object") }
            if scalars[index] == "," { index += 1; continue }
            if scalars[index] == "}" { index += 1; return .object(object) }
            throw error("Expected ',' or '}'")
        }
    }

    mutating func parseArray() throws -> JSON {
        index += 1
        var items: [JSON] = []
        skipWhitespace()
        if index < scalars.count, scalars[index] == "]" { index += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard index < scalars.count else { throw error("Unterminated array") }
            if scalars[index] == "," { index += 1; continue }
            if scalars[index] == "]" { index += 1; return .array(items) }
            throw error("Expected ',' or ']'")
        }
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= scalars.count else { throw error("Bad unicode escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard scalars[index].isASCII, let digit = UInt32(String(scalars[index]), radix: 16) else { throw error("Bad unicode escape") }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    mutating func parseString() throws -> String {
        index += 1
        var output = String.UnicodeScalarView()
        while true {
            guard index < scalars.count else { throw error("Unterminated string") }
            let scalar = scalars[index]
            index += 1
            if scalar == "\"" { return String(output) }
            if scalar == "\\" {
                guard index < scalars.count else { throw error("Bad escape") }
                let escape = scalars[index]
                index += 1
                switch escape {
                case "\"": output.append("\"")
                case "\\": output.append("\\")
                case "/": output.append("/")
                case "b": output.append("\u{08}")
                case "f": output.append("\u{0C}")
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                case "u":
                    var code = try parseHex4()
                    if (0xD800...0xDBFF).contains(code), index + 6 <= scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                        let saved = index
                        index += 2
                        let low = try parseHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = saved
                        }
                    }
                    output.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: throw error("Bad escaped character")
                }
            } else {
                if scalar.value < 0x20 { throw error("Bad control character in string literal") }
                output.append(scalar)
            }
        }
    }

    mutating func parseNumber() throws -> JSON {
        let start = index
        if index < scalars.count, scalars[index] == "-" { index += 1 }
        while index < scalars.count, ("0"..."9").contains(scalars[index]) || [".", "e", "E", "+", "-"].contains(scalars[index]) { index += 1 }
        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        guard !text.isEmpty, let value = Double(text) else {
            index = start
            throw error("Unexpected token")
        }
        return .number(value)
    }
}

// MARK: - 和 Codable 互转（类型化的设置、界面数据）

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSON].self) {
            self = .object(JSONObject(value.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        } else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "不是 JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let object):
            var dictionary: [String: JSON] = [:]
            for (key, value) in object { dictionary[key] = value }
            try container.encode(dictionary)
        }
    }

    /// 类型化值 → JSON（键顺序按字母排序）。
    public static func encode<T: Encodable>(_ value: T) throws -> JSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSON.parse(try encoder.encode(value))
    }

    /// JSON → 类型化值。
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(serialized().utf8))
    }
}

// MARK: - JS 风格的小工具（`a || b`、`a?.x || ""`），让移植的代码读起来和原来一样

extension Optional where Wrapped == JSON {
    /// `a || fallback`
    public func or(_ fallback: @autoclosure () -> JSON) -> JSON {
        if let value = self, value.truthy { return value }
        return fallback()
    }

    /// 真值才返回，否则 nil（`a || undefined`）
    public var truthyValue: JSON? {
        if let value = self, value.truthy { return value }
        return nil
    }

    public var isTruthy: Bool { self?.truthy ?? false }

    /// 字符串值；不是字符串时 nil
    public var str: String? { self?.string }

    /// `a || ""`：真值转成字符串，否则空串
    public var text: String {
        if let value = self, value.truthy { return value.jsString }
        return ""
    }

    public var items: [JSON] { self?.array ?? [] }
    public var fields: JSONObject { self?.object ?? JSONObject() }
}

extension JSON {
    /// `a || b`
    public func or(_ fallback: @autoclosure () -> JSON) -> JSON { truthy ? self : fallback() }
    public var text: String { truthy ? jsString : "" }
    public var items: [JSON] { array ?? [] }
    public var fields: JSONObject { object ?? JSONObject() }
}

extension JSON {
    /// `obj[key][child] = { ...obj[key][child], ...patch }`
    public mutating func mergeChild(_ key: String, _ child: String, _ patch: JSON) {
        var parent = self[key] ?? .emptyObject
        parent[child] = (parent[child] ?? .emptyObject).merging(patch)
        self[key] = parent
    }

    /// `obj[key][child] = value`
    public mutating func setChild(_ key: String, _ child: String, _ value: JSON?) {
        var parent = self[key] ?? .emptyObject
        parent[child] = value
        self[key] = parent
    }
}
