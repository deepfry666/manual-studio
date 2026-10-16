import Foundation

// MARK: - 代码文档版式：60 页 × 每页 50 行
//
// 「一行」按页面上印出来的行算，和 Word 里看到的一样：一行代码太长折成两行算 2 行，空行也算 1 行。
// 版式统一：A4，左右边距 1134 缇、上 1247、下 1440，行网格 283 缇（正文高 14151 ÷ 283 = 50 行），新宋体 9 磅。
// 新宋体英文半格、中文一格，正文宽 9638 缇 = 481.9 磅，9 磅半格 4.5 磅，每行 107 个半格。
// Word 里关掉孤行控制、允许西文在单词中间换行、关掉中英文之间的自动空格，折行位置就和这里算的一样；PDF 也按这里的折行逐行画。

public enum CodeLayout {
    public static let pages = 60
    public static let rowsPerPage = 50
    public static var totalRows: Int { pages * rowsPerPage }
    /// 每行能放的半格数
    public static let columns = 107
    public static let fontSize: Double = 9
    public static let pageWidthTwips = 11906
    public static let pageHeightTwips = 16838
    public static let marginLeftTwips = 1134
    public static let marginRightTwips = 1134
    public static let marginTopTwips = 1247
    public static let marginBottomTwips = 1440
    public static let headerTwips = 851
    public static let footerTwips = 992
    public static let linePitchTwips = 283
    public static var textWidthTwips: Int { pageWidthTwips - marginLeftTwips - marginRightTwips }
    /// 超过 60 页时前后各留多少行
    public static var headRows: Int { totalRows / 2 }
}

/// 一个字符占几个半格：中日韩文字、全角标点和符号占 2 格，其余占 1 格。
public func codeCellWidth(_ character: Character) -> Int {
    guard let scalar = character.unicodeScalars.first else { return 1 }
    let v = scalar.value
    if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
        || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
        || (0xFFE0...0xFFE6).contains(v) || (0x20000...0x3FFFD).contains(v) || (0x1F300...0x1FAFF).contains(v) {
        return 2
    }
    return 1
}

/// 代码模板里的一行在页面上折成几行（每段至少 1 行，空行也是 1 行）。行尾空格不折行。
public func codeRows(_ line: String) -> [String] {
    var text = line
    while let last = text.last, last == " " || last == "\u{3000}" { text.removeLast() }
    guard !text.isEmpty else { return [""] }
    var rows: [String] = []
    var current = ""
    var column = 0
    for character in text {
        let width = codeCellWidth(character)
        if column + width > CodeLayout.columns {
            rows.append(current)
            current = ""
            column = 0
        }
        current.append(character)
        column += width
    }
    rows.append(current)
    return rows
}

public func codeRowCount(_ line: String) -> Int { codeRows(line).count }

/// 把代码行选成正好 60 页 × 50 行：
/// 正好 3000 行的原样用；超出的取前约 1500 行和后约 1500 行（软著「前 30 页 + 后 30 页」）；不足的返回 nil。
/// 一行代码折成两行时不能从中间切开，所以前后两段各自可能差一两行，但加起来正好 3000 行。
public func selectCodeLines(_ lines: [String]) -> [String]? {
    let counts = lines.map(codeRowCount)
    let total = counts.reduce(0, +)
    let target = CodeLayout.totalRows
    if total == target { return lines }
    guard total > target else { return nil }
    var prefix = [0]
    for count in counts { prefix.append(prefix.last! + count) }
    var suffixLength: [Int: Int] = [0: 0]
    var running = 0
    for (index, count) in counts.enumerated().reversed() {
        running += count
        let taken = counts.count - index
        if suffixLength[running] == nil { suffixLength[running] = taken }
        if running > target { break }
    }
    let half = CodeLayout.headRows
    let candidates = prefix.indices.filter { abs(prefix[$0] - half) <= 40 }.sorted { abs(prefix[$0] - half) < abs(prefix[$1] - half) }
    for head in candidates {
        let need = target - prefix[head]
        guard let tail = suffixLength[need], head + tail <= lines.count else { continue }
        return Array(lines[0..<head]) + Array(lines[(lines.count - tail)...])
    }
    return nil
}
