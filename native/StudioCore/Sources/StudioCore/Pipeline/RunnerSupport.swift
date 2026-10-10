import Foundation

public let STEP_LABELS: [String: String] = [
    "plan": "规划界面",
    "prompts": "生成提示词",
    "images": "生成截图",
    "gate": "截图验收",
    "content": "撰写文案",
    "design": "设计说明",
    "receipt": "审查回执",
    "build": "构建交付包",
]

/// 2026年10月9日（本地时间）
public func chineseDate(_ date: Date = Date()) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return "\(components.year!)年\(components.month!)月\(components.day!)日"
}

public func normalizedUi(_ plan: JSON?) -> JSON {
    guard let ui = plan?["uiContract"], ui.truthy else { return .emptyObject }
    var merged = ui.merging(ui["visual"].truthyValue)
    if let palette = ui["palette"].truthyValue ?? ui["visual"]?["palette"] {
        merged["palette"] = palette
    } else {
        merged["palette"] = nil
    }
    return merged
}

public func planRowHash(_ screen: JSON, _ ui: JSON, _ platform: String, _ targetSize: String) -> String {
    hashObject(.obj(["screen": screen, "ui": ui, "platform": .string(platform), "target": .string(targetSize)]))
}

/// 提示词身份：把软件名替换掉再算哈希，改名时不会因此重新生图。
public func promptIdentity(_ prompt: String, _ softwareName: String) -> String {
    sha256Hex(prompt.replacingAll(softwareName, with: "{{SOFTWARE}}"))
}

/// 用时显示：4分10秒、1小时2分。
public func formatDuration(_ ms: Double?) -> String {
    let seconds = max(0, Int(jsRound((ms ?? 0) / 1000)))
    if seconds < 60 { return "\(seconds)秒" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)分\(seconds % 60 != 0 ? "\(seconds % 60)秒" : "")" }
    return "\(minutes / 60)小时\(minutes % 60 != 0 ? "\(minutes % 60)分" : "")"
}

/// 这个项目生成代码文档用哪个代码来源。
/// 代码来源在总设置里设；项目第一次生成交付包时记下当时用的来源（锁定），以后改总设置不影响已完成的项目。
/// 本软件做过交付包的项目、导入的历史项目，都视为已锁定。
public func codeSourceFor(_ state: JSON, _ settings: Settings) -> (source: JSON?, locked: Bool) {
    let request = state["request"]
    let locked: Bool
    if let explicit = request?["codeSourceLocked"], !explicit.isNull {
        locked = explicit.truthy
    } else {
        locked = state["lastBuild"].isTruthy || state["origin"]?.string == "imported"
    }
    if locked {
        let source = request?["codeSource"]
        return (source?["path"].isTruthy == true ? source : nil, true)
    }
    let global = settings.codeSource
    guard !global.path.isEmpty else { return (nil, false) }
    return (.obj(["path": .string(global.path), "extensions": JSON(global.extensions.isEmpty ? [".java"] : global.extensions)]), false)
}

/// 软件名里有没有版本号（V1.0、1.0.0 这类）。
public func detectVersion(_ softwareName: String) -> String? {
    Rx.matches(#"(?:V|v)\s?[0-9]+(?:\.[0-9]+)*|[0-9]+(?:\.[0-9]+)+"#, softwareName).last?[0] ?? nil
}

/// 限制并发数地处理一组任务，结果按原顺序返回。
func mapLimit<T: Sendable, R: Sendable>(_ items: [T], _ limit: Int, _ worker: @escaping @Sendable (T, Int) async -> R) async -> [R] {
    guard !items.isEmpty else { return [] }
    return await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(limit, items.count) {
            let index = next
            next += 1
            group.addTask { (index, await worker(items[index], index)) }
        }
        while let (index, result) = await group.next() {
            results[index] = result
            if next < items.count {
                let nextIndex = next
                next += 1
                group.addTask { (nextIndex, await worker(items[nextIndex], nextIndex)) }
            }
        }
        return results.map { $0! }
    }
}

public struct RunOptions: Sendable {
    public var from: String?
    public var until: String?
    public var force: [String] = []
    public var forceScreens: [String]?
    public var forceContent: [String]?
    public var contentInstructions: [String: String]?
    public var designInstruction: String?
    public var reviewPlan: Bool?
    public var batchId: String?
    public var reason: String?

    public init(from: String? = nil, until: String? = nil, force: [String] = [], forceScreens: [String]? = nil, forceContent: [String]? = nil, contentInstructions: [String: String]? = nil, designInstruction: String? = nil, reviewPlan: Bool? = nil, batchId: String? = nil, reason: String? = nil) {
        self.from = from
        self.until = until
        self.force = force
        self.forceScreens = forceScreens
        self.forceContent = forceContent
        self.contentInstructions = contentInstructions
        self.designInstruction = designInstruction
        self.reviewPlan = reviewPlan
        self.batchId = batchId
        self.reason = reason
    }
}

public struct RunResult: Sendable, Hashable {
    public var status: String
    public var step: String?
    public var error: String?

    public init(status: String, step: String? = nil, error: String? = nil) {
        self.status = status
        self.step = step
        self.error = error
    }
}

struct StepContext: Sendable {
    let projectDir: String
    var state: JSON
    let settings: Settings
    let batchId: String
    let reviewPlan: Bool
    let forceScreens: [String]?
    let forceContent: [String]?
    let contentInstructions: [String: String]?
    let designInstruction: String?
    let forceDesign: Bool
}

struct StepOutcome: Sendable {
    var status: String
    var message: String?
    var screenCountReason: String?
}
