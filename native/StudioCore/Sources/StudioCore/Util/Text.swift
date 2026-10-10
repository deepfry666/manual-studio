import Foundation

/// 和 JS 字符串语义一致的小工具：长度和截取按 UTF-16 计（JS 的 length / slice），trim 的空白集合和 JS 一样。
extension String {
    public var jsLength: Int { utf16.count }

    /// `str.slice(start, end)`
    public func jsSlice(_ start: Int, _ end: Int? = nil) -> String {
        let units = Array(utf16)
        let count = units.count
        func clamp(_ value: Int) -> Int { value < 0 ? max(0, count + value) : min(value, count) }
        let from = clamp(start)
        let to = clamp(end ?? count)
        guard from < to else { return "" }
        return String(decoding: units[from..<to], as: UTF16.self)
    }

    static let jsWhitespace: Set<Unicode.Scalar> = {
        var set: Set<Unicode.Scalar> = ["\u{09}", "\u{0B}", "\u{0C}", "\u{20}", "\u{A0}", "\u{FEFF}", "\u{0A}", "\u{0D}", "\u{2028}", "\u{2029}", "\u{1680}", "\u{202F}", "\u{205F}", "\u{3000}"]
        for value in 0x2000...0x200A { set.insert(Unicode.Scalar(value)!) }
        return set
    }()

    /// `str.trim()`
    public var jsTrimmed: String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !String.jsWhitespace.contains($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !String.jsWhitespace.contains($0) })!
        return String(scalars[first...last])
    }

    /// `str.trimEnd()`
    public var jsTrimmedEnd: String {
        let scalars = unicodeScalars
        guard let last = scalars.lastIndex(where: { !String.jsWhitespace.contains($0) }) else { return "" }
        return String(scalars[...last])
    }

    /// `str.split(sep).join(rep)`：字面量全部替换。
    public func replacingAll(_ target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        return components(separatedBy: target).joined(separator: replacement)
    }

    /// `str.padStart(2, "0")`
    public func padStart(_ length: Int, _ pad: Character = "0") -> String {
        count >= length ? self : String(repeating: pad, count: length - count) + self
    }
}

/// JS 正则的 Swift 版本（NSRegularExpression，下标按 UTF-16 计，和 JS 一致）。
/// 注意：移植时 `\d` 写成 `[0-9]`、`\b` 写成 ASCII 断言，避免 ICU 按 Unicode 处理和 JS 不一样。
public enum Rx {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSRegularExpression>()

    public static func regex(_ pattern: String, _ flags: String = "") -> NSRegularExpression {
        let key = "\(flags)/\(pattern)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        let compiled = try! NSRegularExpression(pattern: pattern, options: options)
        cache.setObject(compiled, forKey: key)
        return compiled
    }

    public static func test(_ pattern: String, _ text: String, _ flags: String = "") -> Bool {
        regex(pattern, flags).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 第一个匹配的各分组（0 是整个匹配），没有匹配返回 nil。
    public static func match(_ pattern: String, _ text: String, _ flags: String = "") -> [String?]? {
        guard let result = regex(pattern, flags).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return groups(result, text)
    }

    /// 所有匹配（相当于 matchAll / match(/g)）。
    public static func matches(_ pattern: String, _ text: String, _ flags: String = "") -> [[String?]] {
        regex(pattern, flags).matches(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, text) }
    }

    public static func count(_ pattern: String, _ text: String, _ flags: String = "") -> Int {
        regex(pattern, flags).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// 全部替换；template 用 `$1` 引用分组。
    public static func replace(_ pattern: String, in text: String, with template: String, _ flags: String = "") -> String {
        regex(pattern, flags).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// 只替换第一个。
    public static func replaceFirst(_ pattern: String, in text: String, with template: String, _ flags: String = "") -> String {
        let expression = regex(pattern, flags)
        guard let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return text }
        let replacement = expression.replacementString(for: result, in: text, offset: 0, template: template)
        return (text as NSString).replacingCharacters(in: result.range, with: replacement)
    }

    /// 用闭包替换每个匹配。
    public static func replace(_ pattern: String, in text: String, _ flags: String = "", using transform: ([String?]) -> String) -> String {
        let expression = regex(pattern, flags)
        let ns = text as NSString
        var output = ""
        var last = 0
        for result in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: last, length: result.range.location - last))
            output += transform(groups(result, text))
            last = result.range.location + result.range.length
        }
        output += ns.substring(from: last)
        return output
    }

    /// `str.split(/re/)`
    public static func split(_ pattern: String, _ text: String, _ flags: String = "") -> [String] {
        let ns = text as NSString
        var parts: [String] = []
        var last = 0
        for result in regex(pattern, flags).matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if result.range.length == 0 { continue }
            parts.append(ns.substring(with: NSRange(location: last, length: result.range.location - last)))
            last = result.range.location + result.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }

    private static func groups(_ result: NSTextCheckingResult, _ text: String) -> [String?] {
        let ns = text as NSString
        return (0..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }
}

/// JS 的 `Math.round`（.5 向正无穷取整）。
public func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

/// 只出现一次的值（按首次出现的顺序去重）。
public func uniqued<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}
