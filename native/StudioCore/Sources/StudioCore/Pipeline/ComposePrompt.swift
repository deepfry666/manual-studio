import Foundation

/// S2：由程序把共享 UI 约束 + 单屏计划拼成生图提示词。
/// 末尾的品牌禁令段固定追加，界面上不能编辑。
public let BRAND_BAN_BLOCK = "Do NOT render the software name, App name, version string, name-bearing logo, wordmark, or recognizable project-name branding anywhere in the UI."

/// `array.join(sep)`（null 写成空串，其他按 String() 转换）
func jsJoin(_ values: [JSON], _ separator: String) -> String {
    values.map { $0.isNull ? "" : $0.jsString }.joined(separator: separator)
}

/// 模板字符串里的 `${x}`：undefined 写成 "undefined"，和 JS 一致。
func templateText(_ value: JSON?) -> String { value.map(\.jsString) ?? "undefined" }

func isAndroid(_ platform: String) -> Bool { Rx.test("android|安卓", platform, "i") }

func paletteText(_ palette: JSON?) -> String {
    (palette?.object ?? JSONObject()).compactMap { key, value -> String? in
        guard let text = value.string, !text.isEmpty else { return nil }
        return "\(key) \(text)"
    }.joined(separator: ", ")
}

func navigationSentence(_ ui: JSON?, _ screen: JSON) -> String {
    let nav = ui?["navigation"].flatMap { $0.truthy ? $0 : nil } ?? .emptyObject
    let labels = (nav["labels"]?.array ?? []).filter(\.truthy)
    let type = nav["type"].flatMap { $0.truthy ? $0.jsString : nil } ?? ""
    let activeTab = screen["activeTab"]
    if labels.isEmpty || Rx.test("none|stack", type, "i") || !(activeTab?.truthy ?? false) {
        return labels.isEmpty ? "" : "Hide the bottom tab bar on this screen; use a native top navigation bar with a back control where appropriate."
    }
    let iconSemantics = nav["iconSemantics"]?.array ?? []
    let icons = iconSemantics.isEmpty ? "" : " (icons: \(jsJoin(iconSemantics, ", ")))"
    return "Show bottom tabs exactly \(jsJoin(labels, "、")) in that order with \(templateText(activeTab)) active and matching line icons\(icons)."
}

public func composeScreenPrompt(softwareName: String, platform: String, targetSize: String, ui: JSON?, screen: JSON) -> String {
    let android = isAndroid(platform)
    let device = android ? "native Android" : "native iOS"
    let statusBar = android
        ? "Use one consistent Android status bar with the same time and battery style on every screen."
        : "Use one fixed iOS status bar at 9:41 with the same signal, Wi-Fi and icon-only battery style on every screen."
    func truthyText(_ key: String) -> String? { ui?[key].flatMap { $0.truthy ? $0.jsString : nil } }
    let visual = [
        truthyText("visualStyle").map { "Visual style: \($0)." },
        (ui?["palette"]?.truthy ?? false) ? "Palette: \(paletteText(ui?["palette"]))." : nil,
        truthyText("typography").map { "Typography: \($0)." },
        truthyText("radius").map { "Corner radius: \($0)." },
        truthyText("shadow").map { "Shadow: \($0)." },
        truthyText("density").map { "Density: \($0)." },
    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")

    let mustShow = screen["mustShow"]?.array ?? []
    let sampleData = screen["sampleData"]?.array ?? []
    let pageType = screen["pageType"].flatMap { $0.truthy ? $0.jsString : nil } ?? "app screen"
    let visualBrief = screen["visualBrief"].flatMap { $0.truthy ? $0.jsString : nil } ?? ""
    let lines = [
        "Use case: ui-mockup",
        "Asset type: Chinese software manual screenshot",
        "Create exactly one complete \(device) portrait app viewport as a PNG, no physical phone frame, no bezel, no collage, no multi-screen layout. Use \(platform) around \(targetSize). \(statusBar) \(visual)".jsTrimmed,
        "",
        "Screen: \(templateText(screen["title"])). Page type: \(pageType). \(visualBrief)".jsTrimmed,
        mustShow.isEmpty ? "" : "Must show: \(jsJoin(mustShow, "; ")).",
        sampleData.isEmpty ? "" : "Use these exact sample values where they appear: \(jsJoin(sampleData, "; ")). Keep figures consistent with the other screens.",
        navigationSentence(ui, screen),
        "All interface text must be natural Simplified Chinese with correct characters.",
        "",
        "Project context exact software name: \(softwareName). Use it only as context and never show it in the UI. No app name, version, logo, wordmark, physical phone shell, \(android ? "iOS status bar" : "Android navigation"), or watermark.",
        "",
        BRAND_BAN_BLOCK,
    ]
    let kept = lines.enumerated().filter { index, line in line != "" || (index > 0 && lines[index - 1] != "") }.map(\.element)
    return kept.joined(separator: "\n").jsTrimmed + "\n"
}

/// 用户在界面上编辑提示词后，保证禁令段仍在末尾。
public func ensureBrandBan(_ prompt: String) -> String {
    var text = prompt
    if let range = text.range(of: BRAND_BAN_BLOCK) { text.replaceSubrange(range, with: "") }
    return "\(text.jsTrimmedEnd)\n\n\(BRAND_BAN_BLOCK)\n"
}

/// 只替换程序管理的规则块，保留用户或反馈模型追加的其他指令。
public func ensureContentDateRule(_ prompt: String, _ state: JSON) -> String {
    let start = "<manual-content-policy>"
    let end = "</manual-content-policy>"
    var clean = prompt
    while let from = clean.range(of: start), let to = clean.range(of: end, range: from.upperBound..<clean.endIndex) {
        clean.removeSubrange(from.lowerBound..<to.upperBound)
    }
    // 兼容本次开发草稿中尚未带标记的规则；品牌禁令后的反馈文字必须保留。
    let oldMarker = "\n\n统一日期规定（优先于旧规划、示例数据和旧正文）："
    if let from = clean.range(of: oldMarker), let to = clean.range(of: BRAND_BAN_BLOCK, range: from.upperBound..<clean.endIndex) {
        clean.removeSubrange(from.lowerBound..<to.lowerBound)
    }
    let rule = start + contentDateRule(state) + platformNeutralRule(state["request"]?["softwareName"].text ?? "") + "\n" + end
    let withoutBan = clean.replacingAll(BRAND_BAN_BLOCK, with: "").jsTrimmed
    return ensureBrandBan(withoutBan + "\n\n" + rule)
}
