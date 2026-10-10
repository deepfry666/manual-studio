import Foundation

// 各步骤给大模型的提示词和程序复核（系统提示词和 JSON Schema 在 LLMPrompts.generated.swift，由 Electron 版原样生成）。

// MARK: - S1 规划

public func planUserPrompt(softwareName: String, screenCount: Int?, emphasis: String, notes: String, platform: String) -> String {
    [
        "软件名（仅作上下文，界面里不能显示）：\(softwareName)",
        "平台：\(platform)",
        screenCount.map { "截图屏数：必须正好 \($0) 屏" } ?? "截图屏数：未指定，按功能覆盖决定（默认 7 屏）",
        emphasis.isEmpty ? "" : "用户强调的功能：\(emphasis)",
        notes.isEmpty ? "" : "补充说明：\(notes)",
        "",
        "输出 JSON 结构：",
        ##"{"profile":{"domain":"","targetUser":"","coreFlow":"A—B—C"},"coverageReason":"","features":[{"name":"","screenId":"screen-01","tier":"core"}],"uiContract":{"visualStyle":"","palette":{"primary":"#2563EB","background":"#F5F7FB","surface":"#FFFFFF","text":"#172033"},"typography":"","radius":"","shadow":"","density":"","navigation":{"type":"bottom-tabs","labels":[],"iconSemantics":[]}},"screens":[{"id":"screen-01","title":"","pageType":"","activeTab":null,"mustShow":[],"sampleData":[],"textContract":{"entry":"","action":"","feedback":"","exception":"","exit":""},"visualBrief":""}]}"##,
    ].filter { !$0.isEmpty }.joined(separator: "\n")
}

public func planCheck(_ plan: JSON, softwareName: String, screenCount: Int?) -> [String] {
    var problems: [String] = []
    let screens = plan["screens"].items
    if let screenCount, screens.count != screenCount { problems.append("screens 必须正好 \(screenCount) 屏，现在是 \(screens.count) 屏") }
    if screenCount == nil, screens.count < 4 || screens.count > 12 { problems.append("屏数 \(screens.count) 不合理，应在 5–10 之间") }
    for (index, screen) in screens.enumerated() {
        let expected = screenId(index)
        if screen["id"]?.string != expected { problems.append("第 \(index + 1) 屏 id 应为 \(expected)") }
    }
    let titles = screens.map { $0["title"] ?? .null }
    if Set(titles).count != titles.count { problems.append("各屏 title 不能重复") }
    let tokens = forbiddenBrandTokens(softwareName)
    var visible: [JSON] = plan["uiContract"]?["navigation"]?["labels"]?.array ?? []
    for screen in screens {
        // 画面描述会直接进生图提示词，里面出现软件名就很可能被画出来
        visible.append(screen["title"] ?? .null)
        visible.append(screen["visualBrief"].or(""))
        visible.append(contentsOf: screen["mustShow"].items)
        visible.append(contentsOf: screen["sampleData"].items)
    }
    let hits = findBrandHits([jsJoin(visible, "\n")], tokens)
    if !hits.isEmpty { problems.append("界面文字里出现了软件名/品牌词：\(hits.joined(separator: "、"))，请换成不含软件名的说法") }
    return problems
}

// MARK: - S4 截图品牌验收（看图模型）

public func gateUserPrompt(softwareName: String, tokens: [String], screen: JSON?) -> String {
    [
        "软件名：\(softwareName)",
        "禁词（界面里任何一个都不能出现）：\(tokens.joined(separator: "、"))",
        screen.map { "这张图计划是「\(templateText($0["title"]))」，应包含：\(jsJoin($0["mustShow"].items, "、"))" } ?? "",
        #"按要求输出 JSON：{"singleScreen":true,"portraitApp":true,"brandFound":false,"brandEvidence":"","screenTitle":"","visibleText":[],"inventory":"","warnings":[]}"#,
    ].filter { !$0.isEmpty }.joined(separator: "\n")
}

public struct GateVerdict: Sendable {
    public let passed: Bool
    public let reasons: [String]
    public let hits: [String]
}

/// 程序复核：看图模型说没有，但抄录的文字里含禁词，也判失败。
public func judgeGate(_ result: JSON, _ tokens: [String]) -> GateVerdict {
    let texts = result["visibleText"].items + [result["screenTitle"].or("")]
    let hits = findBrandHits([jsJoin(texts, "\n")], tokens)
    var reasons: [String] = []
    if result["brandFound"].isTruthy { reasons.append("看图模型发现品牌文字：\(result["brandEvidence"].or("未说明").jsString)") }
    if !hits.isEmpty { reasons.append("界面文字包含禁词：\(hits.joined(separator: "、"))") }
    if result["singleScreen"] == .bool(false) { reasons.append("不是单个完整界面") }
    if result["portraitApp"] == .bool(false) { reasons.append("不是竖屏 App 界面（可能带手机外壳或是海报）") }
    return GateVerdict(passed: reasons.isEmpty, reasons: reasons, hits: hits)
}

// MARK: - S5 文案

public func contentUserPrompt(softwareName: String, profile: JSON?, screens: [JSON], inventories: [String: String], needOverview: Bool, existingOverview: String, floor: Int, instructions: [String: String] = [:], currentTexts: [String: String] = [:]) -> String {
    let blocks = screens.map { screen -> String in
        let id = screen["id"]?.string ?? ""
        let contract = screen["textContract"]
        let inventory = inventories[id] ?? ""
        let instruction = instructions[id] ?? ""
        let current = currentTexts[id] ?? ""
        return [
            "【\(templateText(screen["id"]))｜\(templateText(screen["title"]))】",
            "计划：入口=\(templateText(contract?["entry"]))；操作=\(templateText(contract?["action"]))；反馈=\(templateText(contract?["feedback"]))；异常=\(templateText(contract?["exception"]))；去向=\(templateText(contract?["exit"]))",
            "应包含：\(jsJoin(screen["mustShow"].items, "、"))",
            "示例数据：\(jsJoin(screen["sampleData"].items, "、"))",
            inventory.isEmpty ? "截图实际内容：（未做看图对账，按计划写，避免写过细的数值）" : "截图实际内容：\(inventory)",
            instruction.isEmpty ? "" : "用户修改要求（必须照做）：\(instruction)",
            !instruction.isEmpty && !current.isEmpty ? "当前正文（在此基础上按要求修改，没提到的内容尽量保留）：\(current)" : "",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    let overviewInstruction = instructions["overview"] ?? ""
    var lines = [
        "软件名：\(softwareName)",
        "领域：\(profile?["domain"].text ?? "")；目标用户：\(profile?["targetUser"].text ?? "")；核心流程：\(profile?["coreFlow"].text ?? "")",
        needOverview ? "需要输出 overview（封面介绍）。" : "封面介绍已确定，不需要输出 overview：\(existingOverview)",
        needOverview && !overviewInstruction.isEmpty ? "封面介绍修改要求（必须照做）：\(overviewInstruction)\(existingOverview.isEmpty ? "" : "\n当前封面介绍（在此基础上修改）：\(existingOverview)")" : "",
        "功能说明每屏至少 \(floor) 个字符。",
        "",
    ]
    lines.append(contentsOf: blocks)
    lines.append("")
    lines.append("输出 JSON：{\(needOverview ? #""overview":"","# : "")\"screens\":[{\"id\":\"screen-01\",\"title\":\"\",\"text\":\"\"}]}，screens 只包含上面列出的屏，顺序一致。")
    return lines.joined(separator: "\n")
}

public func contentCheck(_ result: JSON, screens: [JSON], needOverview: Bool, floor: Int) -> [String] {
    var problems: [String] = []
    let ids = screens.map { $0["id"] ?? .null }
    let got = result["screens"].items.map { $0["id"] ?? .null }
    if JSON.array(got).serialized() != JSON.array(ids).serialized() { problems.append("screens 必须正好是 \(jsJoin(ids, ","))，顺序一致") }
    if needOverview {
        let overview = result["overview"].text
        if textLength(overview) < 120 { problems.append("overview 太短，至少 150 个字符") }
        if hasFigureReference(overview) { problems.append("overview 里不能出现「图N」") }
    }
    for screen in result["screens"].items {
        let text = screen["text"].text
        let id = templateText(screen["id"])
        let length = textLength(text)
        if length < floor { problems.append("\(id) 的 text 只有 \(length) 个字符，至少需要 \(floor) 个，请补充该界面专属的操作与状态细节") }
        if hasFigureReference(text) { problems.append("\(id) 的 text 出现了「图N」字样") }
        if mentionsFictional(text) { problems.append("\(id) 的 text 不能说软件是虚构或示例") }
    }
    return problems
}

// MARK: - S6 设计说明（可选）

public func designUserPrompt(softwareName: String, profile: JSON?, features: [JSON], screens: [JSON], instruction: String?, current: String) -> String {
    let instruction = instruction ?? ""
    return [
        "软件名：\(softwareName)",
        "领域：\(templateText(profile?["domain"]))；目标用户：\(templateText(profile?["targetUser"]))；核心流程：\(templateText(profile?["coreFlow"]))",
        "功能：\(jsJoin(features.map { $0["name"] ?? .null }, "、"))",
        "界面：\(screens.map { "\(templateText($0["title"]))（\($0["textContract"]?["action"].text ?? "")）" }.joined(separator: "；"))",
        instruction.isEmpty ? "" : "用户修改要求（必须照做）：\(instruction)",
        !instruction.isEmpty && !current.isEmpty ? "当前设计说明（在此基础上修改）：\n\(current)" : "",
        #"输出 JSON：{"sections":[{"title":"软件基本处理流程","text":""}]}"#,
    ].filter { !$0.isEmpty }.joined(separator: "\n")
}

public func designCheck(_ result: JSON) -> [String] {
    result["sections"].items.compactMap { section in
        hasFigureReference("\(templateText(section["title"]))\(templateText(section["text"]))") ? "「\(templateText(section["title"]))」里出现了「图N」字样" : nil
    }
}

// MARK: - 修改意见：整理

public struct FeedbackScreen: Sendable {
    public let figure: String
    public let id: String
    public let title: String
    public let inventory: String
    public let visual: String
    public let text: String
}

public func feedbackUserPrompt(softwareName: String, screens: [FeedbackScreen], overview: String, hasDesign: Bool, items: [String]) -> String {
    var lines = ["软件名：\(softwareName)", "当前截图："]
    for screen in screens {
        let picture = !screen.inventory.isEmpty ? "；画面：\(screen.inventory)" : !screen.visual.isEmpty ? "；画面计划：\(screen.visual)" : ""
        lines.append("- \(screen.figure)（\(screen.id)）「\(screen.title)」\(picture)\(screen.text.isEmpty ? "" : "；说明开头：\(screen.text)")")
    }
    lines.append(overview.isEmpty ? "" : "封面介绍：\(overview)")
    lines.append(hasDesign ? "手册里有「软件设计说明」章节。" : "手册里没有「软件设计说明」章节。")
    lines.append("")
    lines.append("修改意见：")
    for (index, item) in items.enumerated() { lines.append("意见\(index + 1)：\(item)") }
    lines.append("")
    lines.append(#"输出 JSON：{"summary":"","actions":[{"type":"image","target":"screen-03","instruction":"","items":[1]}],"questions":[{"question":"","items":[2]}]}"#)
    return lines.filter { !$0.isEmpty }.joined(separator: "\n")
}

public func feedbackCheck(_ result: JSON, screenIds: [String], itemCount: Int) -> [String] {
    var problems: [String] = []
    var seen = Set<String>()
    var covered = Set<Double>()
    for action in result["actions"].items {
        let target = action["target"].text
        let type = templateText(action["type"])
        if type == "image", target != "all", !screenIds.contains(target) { problems.append("image 动作的 target 必须是 \(screenIds.joined(separator: "/")) 或 all，现在是 \(target)") }
        if type == "text", !screenIds.contains(target) { problems.append("text 动作的 target 必须是 \(screenIds.joined(separator: "/")) 之一，现在是 \(target)") }
        let key = "\(type):\(target)"
        if seen.contains(key) { problems.append("\(key) 出现了两次，请合并成一个动作") }
        seen.insert(key)
        for index in action["items"].items { if let number = index.number { covered.insert(number) } }
    }
    for question in result["questions"].items {
        for index in question["items"].items { if let number = index.number { covered.insert(number) } }
    }
    if itemCount >= 1 {
        for index in 1...itemCount where !covered.contains(Double(index)) { problems.append("意见\(index) 没有对应的动作或问题") }
    }
    return problems
}

// MARK: - 修改意见：改生图提示词

public func promptEditUserPrompt(prompt: String, instruction: String) -> String {
    ["修改要求：\(instruction)", "", "原提示词：", prompt, "", #"输出 JSON：{"prompt":"完整的新提示词"}"#].joined(separator: "\n")
}
