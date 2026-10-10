import Foundation

let VERSION_PATTERN = "(?:V|v)?[0-9]+(?:\\.[0-9]+)+"

/// 禁词与旧 skill 校验器一致：完整软件名、版本号、去掉版本后的名称，外加用户手动添加的词。
public func forbiddenBrandTokens(_ softwareName: String, _ extraTokens: [String] = []) -> [String] {
    var tokens: [String] = []
    let name = softwareName.jsTrimmed
    if !name.isEmpty { tokens.append(name) }
    for version in Rx.matches(VERSION_PATTERN, name).compactMap({ $0[0] }) { tokens.append(version) }
    let base = baseSoftwareName(name)
    if base.jsLength >= 2 { tokens.append(base) }
    for token in extraTokens {
        let value = token.jsTrimmed
        if value.jsLength >= 2 { tokens.append(value) }
    }
    return uniqued(tokens).filter { $0.jsLength >= 2 }
}

public func baseSoftwareName(_ softwareName: String) -> String {
    Rx.replace(#"[\s._\-+]+$"#, in: Rx.replace(VERSION_PATTERN, in: softwareName, with: ""), with: "").jsTrimmed
}

func normalizeForBrand(_ text: String) -> String {
    Rx.replace(#"\s+"#, in: text.precomposedStringWithCompatibilityMapping.lowercased(), with: "")
}

public func findBrandHits(_ texts: [String], _ tokens: [String]) -> [String] {
    let haystack = normalizeForBrand(texts.joined(separator: "\n"))
    return tokens.filter { haystack.contains(normalizeForBrand($0)) }
}

/// 正文字数按普通字符串长度计（不是只数汉字），与旧 skill 一致。
public func textLength(_ text: String?) -> Int { (text ?? "").jsTrimmed.jsLength }

public func hasFigureReference(_ text: String?) -> Bool { Rx.test(#"图\s*[0-9]+"#, text ?? "") }

public func mentionsFictional(_ text: String?) -> Bool { Rx.test("虚构|虚拟的软件|示例软件|假想", text ?? "") }

// MARK: - 系统字样

/// 系统、设备、应用商店字样。软件名没有特指某个系统时，文案、设计说明和界面文字里一个都不能出现
/// （平台设置只决定截图的界面样式，不代表软件只能在某个系统上用）。
/// 英文词前后不能紧挨字母，避免把普通单词里的片段当成命中。
public let PLATFORM_TERMS_PATTERN = [
    "iPhone", "iPad", "iPadOS", "iOS", "Android", "HarmonyOS", "Windows", "macOS", "Mac\\s*OS", "App\\s*Store", "Google\\s*Play", "Apple\\s*Watch", "Pro\\s*Max",
].map { "(?<![A-Za-z])\($0)(?![A-Za-z])" }.joined(separator: "|") + "|安卓|鸿蒙|苹果手机|苹果系统|苹果设备|苹果用户|华为手机|应用宝|华为应用市场|谷歌商店|微信小程序"

/// 软件名本身就指明了系统（例如「XX 安卓版」「iPad 记账」），这时允许出现系统字样。
public func softwareNameNamesPlatform(_ softwareName: String) -> Bool {
    Rx.test(PLATFORM_TERMS_PATTERN, softwareName, "i")
}

/// 文本里出现的系统字样（去重，保留原文写法）。
public func findPlatformTerms(_ texts: [String]) -> [String] {
    uniqued(texts.flatMap { text in Rx.matches(PLATFORM_TERMS_PATTERN, text, "i").compactMap { $0[0] } })
}

/// 追加在提示词末尾的要求；软件名指明了系统时为空。
public func platformNeutralRule(_ softwareName: String, forPlan: Bool = false) -> String {
    if softwareNameNamesPlatform(softwareName) { return "" }
    let what = forPlan ? "profile（领域、目标用户、核心流程）、界面标题、导航文字、mustShow、sampleData、textContract" : "所有输出文字"
    return "\n\n系统字样要求：软件名没有指明运行系统，\(forPlan ? "上面的「平台」只用来决定界面样式；" : "")\(what)里不要出现 iPhone、iPad、iOS、Android、安卓、鸿蒙、HarmonyOS、Windows、macOS、App Store、应用商店名称或具体机型等任何系统、设备字样。需要指代时说「手机」「移动端」「App」「用户」。"
}

/// 程序复核：软件名没有指明系统时，出现系统字样就打回重写。
public func platformProblems(_ softwareName: String, _ label: String, _ texts: [String]) -> [String] {
    if softwareNameNamesPlatform(softwareName) { return [] }
    let hits = findPlatformTerms(texts)
    return hits.isEmpty ? [] : ["\(label)里出现了系统或设备字样：\(hits.joined(separator: "、"))。软件名没有指明系统，请改成「手机」「移动端」「App」等通用说法"]
}

/// 规划结果里会流进文案和截图文字的部分（不含画面描述：那里写界面风格可以提到系统）。
public func planVisibleTexts(_ plan: JSON) -> [String] {
    var texts: [JSON] = [plan["profile"]?["domain"] ?? .null, plan["profile"]?["targetUser"] ?? .null, plan["profile"]?["coreFlow"] ?? .null]
    texts.append(contentsOf: plan["uiContract"]?["navigation"]?["labels"].items ?? [])
    texts.append(contentsOf: plan["features"].items.map { $0["name"] ?? .null })
    for screen in plan["screens"].items {
        texts.append(screen["title"] ?? .null)
        texts.append(contentsOf: screen["mustShow"].items)
        texts.append(contentsOf: screen["sampleData"].items)
        texts.append(contentsOf: screen["textContract"].fields.map(\.value))
    }
    return texts.map(\.jsString)
}

/// 已有文字里出现系统字样时，给大模型的修改要求（只改这些字样，其余保持）。
public func platformFixInstruction(_ hits: [String]) -> String {
    "去掉文中的系统或设备字样（\(hits.joined(separator: "、"))），改成「手机」「移动端」「App」等通用说法；其余内容和结构尽量保持不变"
}
