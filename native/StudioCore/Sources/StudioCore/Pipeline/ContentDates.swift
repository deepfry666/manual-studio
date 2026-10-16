import Foundation

// MARK: - 内容日期与最早日期
//
// 内容日期 = 截图里的「今天」，默认新建当天。
// 最早日期 = 历史记录最早能到哪天：项目填了企业成立 / 开发完成日期就用它，没填按内容日期往前推 30 天。
// 历史记录只能落在 [最早日期, 内容日期]；预约、截止这类未来安排可以晚于内容日期。
// 只有设置了内容日期的项目（v1.4.5 起新建的，或手动设过日期的历史项目）才套用这些规则。

/// 没填最早日期时，历史记录最多往前推几天。
public let DEFAULT_HISTORY_DAYS = 30

public func dateRuleActive(_ state: JSON) -> Bool {
    validContentDate(state["request"]?["contentDate"].text ?? "")
}

/// 项目自己填的最早日期（没填或不合法时为 nil）。
public func explicitEarliestDate(_ state: JSON) -> String? {
    let value = state["request"]?["earliestDate"].text.jsTrimmed ?? ""
    return validContentDate(value) ? value : nil
}

public func earliestDateOf(_ state: JSON) -> String {
    let base = contentDateOf(state)
    guard let explicit = explicitEarliestDate(state) else { return addDays(base, -DEFAULT_HISTORY_DAYS) }
    return min(explicit, base)
}

/// 日期规则涉及的项目设置；写进各步骤的增量判断，改了日期才重新生成。没设置时不出现，旧项目哈希不变。
func datePolicyFields(_ state: JSON) -> JSON? {
    guard dateRuleActive(state) else { return nil }
    return .obj(["contentDate": state["request"]?["contentDate"], "earliestDate": JSON.maybe(explicitEarliestDate(state))])
}

private func gregorian() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func dateOf(_ key: String) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return gregorian().date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

public func addDays(_ key: String, _ days: Int) -> String {
    guard let date = dateOf(key), let moved = gregorian().date(byAdding: .day, value: days, to: date) else { return key }
    let c = gregorian().dateComponents([.year, .month, .day], from: moved)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

public func daysBetween(_ from: String, _ to: String) -> Int {
    guard let a = dateOf(from), let b = dateOf(to) else { return 0 }
    return gregorian().dateComponents([.day], from: a, to: b).day ?? 0
}

private func dateKey(_ year: Int, _ month: Int, _ day: Int) -> String? {
    guard (1...12).contains(month), day >= 1 else { return nil }
    let key = String(format: "%04d-%02d-%02d", year, month, day)
    return validContentDate(key) ? key : nil
}

private func monthEnd(_ year: Int, _ month: Int) -> String? {
    guard (1...12).contains(month), let first = gregorian().date(from: DateComponents(year: year, month: month, day: 1)),
          let range = gregorian().range(of: .day, in: .month, for: first) else { return nil }
    return dateKey(year, month, range.count)
}

/// 出生日期、证件有效期、商品生产日期这类和「用这个软件」无关的事实日期不受最早日期限制。
private let FACT_DATE_CONTEXT = ["出生", "生日", "身份证", "证件", "有效期", "签发", "发证", "入职", "毕业", "入学", "成立于", "创立", "发行", "出版", "上映", "首播", "发售", "上市", "生产", "保质期", "建于", "纪念日"]

public struct DateMention: Sendable, Equatable {
    /// 原文里的写法
    public let text: String
    /// 用于比较的日期：精确到日的就是那天；只写到月的取当月最后一天
    public let key: String
    /// 年月日或年月写全了的为 true；「8月8日」「08-08 09:30」这种按内容日期所在年份推断
    public let hasYear: Bool
    public let factual: Bool
}

/// 找出文字里的日期。只认得出年月日、年月、月日三类常见写法。
public func dateMentions(_ texts: [String], base: String) -> [DateMention] {
    let baseYear = Int(base.prefix(4)) ?? 2026
    var found: [DateMention] = []
    for raw in texts {
        var text = raw
        for (from, to) in [("－", "-"), ("–", "-"), ("—", "-"), ("−", "-"), ("／", "/"), ("．", "."), ("：", ":")] { text = text.replacingAll(from, with: to) }
        text = String(text.unicodeScalars.map { scalar -> Character in
            (0xFF10...0xFF19).contains(scalar.value) ? Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!) : Character(scalar)
        })
        let ns = text as NSString
        var masked = Array(repeating: false, count: ns.length)
        func factual(_ range: NSRange) -> Bool {
            let before = ns.substring(with: NSRange(location: max(0, range.location - 10), length: min(10, range.location)))
            let afterStart = range.location + range.length
            let after = ns.substring(with: NSRange(location: afterStart, length: min(6, ns.length - afterStart)))
            let lineBefore = before.components(separatedBy: "\n").last ?? before
            let lineAfter = after.components(separatedBy: "\n").first ?? after
            return FACT_DATE_CONTEXT.contains { lineBefore.contains($0) } || ["出生", "生日"].contains { lineAfter.contains($0) }
        }
        func scan(_ pattern: String, _ make: ([String]) -> (String, Bool)?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range
                if (range.location..<(range.location + range.length)).contains(where: { masked[$0] }) { continue }
                let groups = (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
                guard let (key, hasYear) = make(groups) else { continue }
                for index in range.location..<(range.location + range.length) { masked[index] = true }
                found.append(DateMention(text: ns.substring(with: range).jsTrimmed, key: key, hasYear: hasYear, factual: factual(range)))
            }
        }
        // 2026-10-08、2026/10/8、2026.10.08、2026年10月8日
        scan(#"(?<![0-9])((?:19|20)[0-9]{2})\s*(?:[-/.]|年)\s*([0-9]{1,2})\s*(?:[-/.]|月)\s*([0-9]{1,2})(?![0-9])\s*[日号]?"#) { g in
            dateKey(Int(g[0])!, Int(g[1])!, Int(g[2])!).map { ($0, true) }
        }
        // 2026-08 期、2026年8月（不认小数点，避免把金额当成年月）
        scan(#"(?<![0-9¥￥.])((?:19|20)[0-9]{2})\s*(?:[-/]|年)\s*([0-9]{1,2})(?![0-9.])\s*月?"#) { g in
            monthEnd(Int(g[0])!, Int(g[1])!).map { ($0, true) }
        }
        // 8月8日、10月12号（没写年份：按内容日期所在年份）
        scan(#"(?<![0-9])([0-9]{1,2})\s*月\s*([0-9]{1,2})\s*[日号]"#) { g in
            dateKey(baseYear, Int(g[0])!, Int(g[1])!).map { ($0, false) }
        }
        // 08-08、09-28 09:30（列表里常见的月-日；10–12 月要后面跟着时间才认，免得把「10-12 人」当成日期）
        for pattern in [#"(?<![0-9.:/-])(0[1-9])-(0[1-9]|[12][0-9]|3[01])(?![0-9-])"#, #"(?<![0-9.:/-])(1[0-2])-(0[1-9]|[12][0-9]|3[01])(?=\s+[0-9]{1,2}:[0-9]{2})"#] {
            scan(pattern) { g in dateKey(baseYear, Int(g[0])!, Int(g[1])!).map { ($0, false) } }
        }
    }
    return found
}

/// 早于最早日期的日期（原文写法，去重）。allowed：截图里本来就有的日期，正文照实描述不算违规。
public func datesBefore(_ texts: [String], earliest: String, base: String, allowed: Set<String> = []) -> [String] {
    uniqued(dateMentions(texts, base: base).filter { mention in
        if mention.factual || allowed.contains(mention.key) { return false }
        // 没写年份又晚于内容日期的，当作未来安排
        if !mention.hasYear && mention.key > base { return false }
        return mention.key < earliest
    }.map(\.text))
}

public func dateKeys(_ texts: [String], base: String) -> Set<String> {
    Set(dateMentions(texts, base: base).map(\.key))
}

/// 程序复核：交给大模型的反馈（只在项目设置了内容日期时检查）。
public func dateProblems(_ state: JSON, _ label: String, _ texts: [String], allowed: Set<String> = []) -> [String] {
    guard dateRuleActive(state) else { return [] }
    let base = contentDateOf(state)
    let earliest = earliestDateOf(state)
    let hits = datesBefore(texts, earliest: earliest, base: base, allowed: allowed)
    if hits.isEmpty { return [] }
    return ["\(label)里出现了早于 \(earliest) 的日期：\(hits.prefix(8).joined(separator: "、"))。历史记录只能在 \(earliest) 至 \(base) 之间，请改到这个范围内；预约、截止等未来安排可以晚于 \(base)"]
}

/// 写进规划、生图提示词、正文和设计说明的日期规定。没设置内容日期的历史项目不加。
public func contentDateRule(_ state: JSON) -> String {
    guard dateRuleActive(state) else { return "" }
    let base = contentDateOf(state)
    let earliest = earliestDateOf(state)
    let span = max(0, daysBetween(earliest, base))
    let source = explicitEarliestDate(state) != nil ? "项目填写的最早日期" : "默认只往前 \(DEFAULT_HISTORY_DAYS) 天"
    return """


    统一日期规定（优先于旧规划、示例数据和旧正文）：本项目的内容日期（截图里的「今天」）是 \(base)（\(contentDateChinese(base))），历史记录最早只能到 \(earliest)（\(contentDateChinese(earliest))，\(source)）。
    1. 当前日期、日历选中日、「今天」、最新一条记录和封面编制时间用 \(base)。
    2. 历史记录（流水、订单、账单、缴费、打卡、消息、动态、操作日志等）只能在 \(earliest) 至 \(base) 之间，可以自然分布在这段时间里，不必都挤在同一天；不得出现早于 \(earliest) 的日期。
    3. 累计期数、连续天数、使用时长、历史统计等数字也不能暗示 \(earliest) 之前就已开始使用（这段时间只有 \(span) 天，不要写「已缴 10 期」「连续打卡 120 天」这类数字）。
    4. 预约、计划、截止、到期、提醒等未来安排可以晚于 \(base)，按业务合理安排。
    5. 出生日期、证件有效期、商品生产日期等与使用本软件无关的事实日期不受此限，但尽量少用。
    6. 不编造软件上线时间、企业成立时间或多年运营历史；不需要日期的地方不加日期；正文里的日期必须与截图一致。软件名称、版本号保持原样，不当作日期改写。
    """
}
