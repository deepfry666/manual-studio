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
