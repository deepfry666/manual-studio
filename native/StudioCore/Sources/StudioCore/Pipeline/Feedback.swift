import Foundation

// MARK: - 修改意见：整理（原生版）
//
// 旧版完全靠大模型判断每条意见改哪一屏：拿不准就反问，输出格式差一点就整次失败，
// 用户只能看到「没有对应的动作」。现在：
// - 意见可以直接指定改哪里（某一屏 / 全部截图 / 封面介绍 / 设计说明），指定了就一定改那里；
// - 大模型拿到每屏完整的画面描述和图上文字，默认直接执行，尽量不反问；
// - 大模型的结果由程序补全：目标写错的纠正，漏掉的意见按原话补上，实在判断不了的留给用户在确认窗口里选位置；
// - 大模型调用本身失败时也不报错退出，照样给出可以确认的清单。

/// 意见可以指定的位置：screen-XX、all（全部截图）、overview、design。nil 表示让软件判断。
public func feedbackTargetValid(_ target: String?, screenIds: [String], hasDesign: Bool) -> String? {
    guard let target, !target.isEmpty else { return nil }
    if target == "all" || target == "overview" || screenIds.contains(target) { return target }
    if target == "design" { return hasDesign ? target : nil }
    return nil
}

public let FEEDBACK_SYSTEM_NATIVE = """
你负责把用户对一个《软件用户手册》项目提的修改意见整理成可以直接执行的修改动作。手册由若干张手机 App 截图和每张图的说明文字组成，图N 就是第 N 张截图。
动作类型：
- image：改截图画面本身（颜色、布局、控件、图上的文字、数据、日期、风格）。target 写 screen-XX；所有截图都要改时 target 写 all。图改了以后这一屏的说明会自动按新图重写，不需要再加 text 动作，除非用户对文字另有要求。
- text：只改某一屏的说明文字，不改图。target 写 screen-XX。
- overview：改封面介绍。target 写 overview。
- design：改「软件设计说明」章节。target 写 design。
- replan：只有用户明确要求增加或删除界面、改屏数、整体换功能方向时才用。target 写 all。
规则：
1. 用户已经指定位置的意见，target 必须用指定的位置，不要改到别处。
2. 没指定位置的意见，根据各屏的标题、画面描述和图上文字找到对应的屏；说的是「所有截图」「每张图」「整体风格」时 target 写 all；说的是日期、颜色这类每屏都可能有、又没说哪一屏的，也按 all 处理。
3. 尽量直接执行，不要反问。只有意见之间互相矛盾、或者完全看不出要改什么时，才放进 questions。
4. 同一屏、同一类型只出一个动作；多条意见说的是同一屏时合并，instruction 里把要求写全。
5. instruction 用中文，写清楚改什么、怎么改、哪些保持不变；保留用户原话里的具体文字和数字，不要扩大用户没提到的修改范围。
6. items 写这个动作来自哪几条意见（意见编号）。
7. summary 用一两句话概括这次要改什么。
"""

public let FEEDBACK_SCHEMA_NATIVE: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": ["actions"],
  "properties": {
    "summary": { "type": "string" },
    "actions": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["type", "target"],
        "properties": {
          "type": { "type": "string", "enum": ["image", "text", "overview", "design", "replan"] },
          "target": { "type": "string" },
          "instruction": { "type": "string" },
          "items": { "type": "array", "items": { "type": "number" } }
        }
      }
    },
    "questions": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "question": { "type": "string" },
          "items": { "type": "array", "items": { "type": "number" } }
        }
      }
    }
  }
}
"""#)

public struct FeedbackInput: Sendable {
    public let text: String
    /// 用户指定的位置（已校验）；nil 表示让软件判断
    public let target: String?
    public init(text: String, target: String?) {
        self.text = text
        self.target = target
    }
}

public struct FeedbackScreenInfo: Sendable {
    public let figure: String
    public let id: String
    public let title: String
    /// 看图模型对截图的完整描述（没有时用规划里的画面计划）
    public let picture: String
    /// 图上能读到的文字
    public let visibleText: [String]
    /// 现在的说明文字
    public let text: String
    public init(figure: String, id: String, title: String, picture: String, visibleText: [String], text: String) {
        self.figure = figure
        self.id = id
        self.title = title
        self.picture = picture
        self.visibleText = visibleText
        self.text = text
    }
}

public func feedbackTargetLabel(_ target: String, screens: [FeedbackScreenInfo]) -> String {
    switch target {
    case "all": return "全部截图"
    case "overview": return "封面介绍"
    case "design": return "设计说明"
    default:
        guard let index = screens.firstIndex(where: { $0.id == target }) else { return target }
        return "\(screens[index].figure)「\(screens[index].title)」"
    }
}

public func feedbackUserPromptNative(softwareName: String, screens: [FeedbackScreenInfo], overview: String, hasDesign: Bool, items: [FeedbackInput]) -> String {
    var lines = ["软件名：\(softwareName)", "当前截图："]
    for screen in screens {
        lines.append("- \(screen.figure)（\(screen.id)）「\(screen.title)」")
        if !screen.picture.isEmpty { lines.append("  画面：\(screen.picture.jsSlice(0, 700))") }
        if !screen.visibleText.isEmpty { lines.append("  图上文字：\(screen.visibleText.prefix(40).joined(separator: " / ").jsSlice(0, 500))") }
        if !screen.text.isEmpty { lines.append("  说明：\(screen.text.jsSlice(0, 300))") }
    }
    if !overview.isEmpty { lines.append("封面介绍：\(overview.jsSlice(0, 300))") }
    lines.append(hasDesign ? "手册里有「软件设计说明」章节。" : "手册里没有「软件设计说明」章节，不要出 design 动作。")
    lines.append("")
    lines.append("修改意见：")
    for (index, item) in items.enumerated() {
        let pinned = item.target.map { "（用户指定改：\(feedbackTargetLabel($0, screens: screens))，target 必须是 \($0)）" } ?? ""
        lines.append("意见\(index + 1)\(pinned)：\(item.text)")
    }
    lines.append("")
    lines.append(#"输出 JSON：{"summary":"","actions":[{"type":"image","target":"screen-03","instruction":"","items":[1]}],"questions":[{"question":"","items":[2]}]}"#)
    return lines.joined(separator: "\n")
}

/// 把大模型的整理结果补全成一定能执行的动作（意见编号从 1 开始）：
/// 用户指定了位置的意见一定落到那个位置；目标写错的纠正或去掉；
/// 没被任何动作认领的意见，有指定位置就按原话改，没有的列为待指定的问题。
public func repairFeedbackResult(_ result: JSON, items: [FeedbackInput], screenIds: [String], hasDesign: Bool) -> (actions: [JSON], questions: [JSON]) {
    struct Action {
        var type: String
        var target: String
        var instruction: String
        var items: [Int]
        let hadItems: Bool
    }
    let count = items.count
    func numbers(_ value: JSON?) -> [Int] {
        uniqued((value?.array ?? []).compactMap { $0.number.map { Int($0) } }.filter { (1...max(1, count)).contains($0) && $0 <= count })
    }
    func fits(_ type: String, _ target: String) -> Bool {
        switch type {
        case "image": return target == "all" || screenIds.contains(target)
        case "text": return screenIds.contains(target)
        case "overview", "replan": return true
        case "design": return hasDesign
        default: return false
        }
    }
    func matches(_ action: Action, pinned target: String) -> Bool {
        switch target {
        case "all": return action.type == "image" && action.target == "all"
        case "overview": return action.type == "overview"
        case "design": return action.type == "design"
        default: return ["image", "text"].contains(action.type) && action.target == target
        }
    }
    func defaultType(_ target: String) -> String { ["overview", "design"].contains(target) ? target : "image" }

    var actions: [Action] = []
    for raw in result["actions"].items {
        let type = raw["type"].text
        var target = raw["target"].text.jsTrimmed
        if ["overview", "design"].contains(type) { target = type }
        if type == "replan" { target = "all" }
        let nums = numbers(raw["items"])
        if !fits(type, target) {
            // 目标写错了：这几条意见里用户指定过同一屏，就改到那一屏
            let pinned = Set(nums.compactMap { items[$0 - 1].target }.filter { screenIds.contains($0) })
            guard ["image", "text"].contains(type), pinned.count == 1 else { continue }
            target = pinned.first!
        }
        var instruction = raw["instruction"].text.jsTrimmed
        if instruction.isEmpty { instruction = nums.map { items[$0 - 1].text }.joined(separator: "；") }
        if instruction.isEmpty { continue }
        actions.append(Action(type: type, target: target, instruction: instruction, items: nums, hadItems: !nums.isEmpty))
    }
    var questions: [(question: String, items: [Int])] = result["questions"].items.map { ($0["question"].text.jsTrimmed, numbers($0["items"])) }

    // 用户指定了位置的意见：从别处的动作和问题里拿出来，一定落到指定位置
    for (index, item) in items.enumerated() {
        guard let pinned = item.target else { continue }
        let number = index + 1
        for position in actions.indices where !matches(actions[position], pinned: pinned) {
            actions[position].items.removeAll { $0 == number }
        }
        for position in questions.indices { questions[position].items.removeAll { $0 == number } }
        if let position = actions.firstIndex(where: { matches($0, pinned: pinned) }) {
            if !actions[position].items.contains(number) {
                actions[position].items.append(number)
                if !actions[position].instruction.contains(item.text) { actions[position].instruction += "；\(item.text)" }
            }
        } else {
            actions.append(Action(type: defaultType(pinned), target: pinned, instruction: item.text, items: [number], hadItems: true))
        }
    }
    // 意见被挪走后空了的动作去掉；本来就没写来源的动作，按内容认领没被认领的意见（只剩一条时直接记到它名下）
    actions.removeAll { $0.hadItems && $0.items.isEmpty }
    var covered = Set(actions.flatMap(\.items))
    for position in actions.indices where actions[position].items.isEmpty {
        let unclaimed = (1...max(1, count)).filter { $0 <= count && !covered.contains($0) && items[$0 - 1].target == nil }
        let instruction = actions[position].instruction
        let similar = unclaimed.filter { !items[$0 - 1].text.isEmpty && (instruction.contains(items[$0 - 1].text) || items[$0 - 1].text.contains(instruction)) }
        actions[position].items = !similar.isEmpty ? similar : unclaimed.count == 1 ? unclaimed : []
        covered.formUnion(actions[position].items)
    }
    actions.removeAll { $0.items.isEmpty }
    covered = Set(actions.flatMap(\.items))

    questions = questions.map { ($0.question, $0.items.filter { !covered.contains($0) }) }.filter { !$0.question.isEmpty && !$0.items.isEmpty }
    let asked = Set(questions.flatMap(\.items))
    for number in 1...max(1, count) where number <= count && !covered.contains(number) && !asked.contains(number) {
        questions.append(("没能判断这条意见要改哪里，请在下面选择位置", [number]))
    }
    return (
        actions.map { .obj(["type": .string($0.type), "target": .string($0.target), "instruction": .string($0.instruction), "items": .array($0.items.map { .number(Double($0)) })]) },
        questions.map { .obj(["question": .string($0.question), "items": .array($0.items.map { .number(Double($0)) })]) }
    )
}
