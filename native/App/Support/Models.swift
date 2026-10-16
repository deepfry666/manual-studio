import Foundation
import StudioCore

/// 界面用的步骤名（比核心里的更短）。
let STEP_ORDER = PIPELINE_STEPS
let UI_STEP_LABELS: [String: String] = [
    "plan": "规划界面", "prompts": "提示词", "images": "生成截图", "gate": "截图验收",
    "content": "撰写文案", "design": "设计说明", "receipt": "审查回执", "build": "交付包",
]

enum Tone {
    case neutral, blue, green, orange, red, purple, cyan, gold

    init(_ name: String) {
        switch name {
        case "processing", "blue": self = .blue
        case "success", "green": self = .green
        case "warning", "orange": self = .orange
        case "error", "red": self = .red
        case "purple": self = .purple
        case "cyan": self = .cyan
        case "gold": self = .gold
        default: self = .neutral
        }
    }
}

let PROJECT_STATUS: [String: (label: String, tone: Tone)] = [
    "idle": ("未完成", .neutral),
    "running": ("运行中", .blue),
    "done": ("已完成", .green),
    "waiting": ("等待确认", .orange),
    "needs-attention": ("需要处理", .red),
    "canceled": ("已停止", .neutral),
    "missing": ("文件夹不见了", .red),
    "readonly": ("只读", .neutral),
]

let GRADE_LABEL: [String: (label: String, tone: Tone)] = [
    "ready": ("可直接编辑", .green),
    "needs-gate": ("待重新验收", .orange),
    "readonly": ("只读", .neutral),
]

let PLATFORMS: [(value: String, label: String)] = [
    ("iPhone 16 Pro Max / iOS 26", "iPhone 16 Pro Max / iOS 26"),
    ("Android 手机（原生 Android 界面）", "Android 手机"),
]

let TXT_LABELS: [(key: String, label: String)] = [
    ("devHardware", "开发的硬件环境"),
    ("devOs", "开发操作系统"),
    ("devTools", "开发环境 / 开发工具"),
    ("language", "编程语言"),
]

/// 历史项目列表的一行。
struct ProjectRow: Identifiable, Hashable {
    let json: JSON
    /// 新建、生成、完成、最近改动的时间（列表按日期筛选用，载入时解析一次）。导入的项目不算导入那天。
    let activityDates: [Date]

    init(json: JSON) {
        self.json = json
        let imported = json["origin"]?.string == "imported"
        let added = parseISO(json["addedAt"]?.string)
        var stamps = [parseISO(json["lastBuildAt"]?.string), parseISO(json["timing"]?["completedAt"]?.string)]
        if !imported { stamps.append(added) }
        if let updated = parseISO(json["updatedAt"]?.string), !imported || updated - (added ?? 0) > 10 * 60_000 { stamps.append(updated) }
        activityDates = stamps.compactMap { $0 }.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
    var id: String { dir }
    var dir: String { json["dir"]?.string ?? "" }
    var name: String { json["name"]?.jsString ?? Path.basename(dir) }
    var origin: String { json["origin"]?.string ?? "created" }
    var grade: String? { json["grade"]?.string }
    var readOnly: Bool { json["readOnly"].isTruthy }
    var status: String { json["status"]?.string ?? "idle" }
    func step(_ name: String) -> String { json["steps"]?[name]?.string ?? "pending" }
    var hasBundle: Bool { json["hasBundle"].isTruthy }
    var bundleFiles: Int? { json["bundleFiles"]?.int }
    var pdfFontProblem: Bool { json["pdfFontProblem"].isTruthy }
    var timing: JSON? { json["timing"].truthyValue }
    var queue: JSON? { json["queue"].truthyValue }
    var progress: JSON? { json["progress"].truthyValue }
    var feedbackPending: Int { json["feedbackPending"]?.int ?? 0 }
    var lastBuildAt: String? { json["lastBuildAt"]?.string }
    var lastError: String? { json["lastError"]?.string }
    var updatedAt: String { json["updatedAt"]?.string ?? "" }
    var addedAt: String { json["addedAt"]?.string ?? "" }
    /// 同一次批量新建的项目（没有批次时为 nil）
    var batchId: String? { json["batch"]?["id"]?.string }
    var batchLabel: String { json["batch"]?["label"]?.string ?? "" }
    var batchCount: Int { json["batch"]?["count"]?.int ?? 0 }

    /// 用时列：完成用时，没完成时显示累计
    var mainDurationMs: Double? { timing.flatMap { $0["completedMs"]?.number ?? $0["totalMs"]?.number } }

    var stepSummary: (done: Int, current: String?) {
        let done = STEP_ORDER.filter { ["done", "skipped"].contains(step($0)) }.count
        return (done, STEP_ORDER.first { !["done", "skipped"].contains(step($0)) })
    }

    var livePercent: Double {
        guard let live = progress, let current = live["step"]?.string, let index = STEP_ORDER.firstIndex(of: current) else { return 0.02 }
        var inside = 0.3
        if ["images", "gate"].contains(current), let screens = live["screens"].truthyValue {
            inside = (screens["finished"]?.number ?? 0) / max(1, screens["total"]?.number ?? 1)
        }
        return max(0.02, min(0.99, (Double(index) + inside) / Double(STEP_ORDER.count)))
    }

    static func == (lhs: ProjectRow, rhs: ProjectRow) -> Bool { lhs.json == rhs.json }
    func hash(into hasher: inout Hasher) { hasher.combine(dir) }
}

/// 项目详情（getProject 的结果）。
struct ProjectData {
    let json: JSON
    var dir: String { json["dir"]?.string ?? "" }
    var state: JSON { json["state"] ?? .emptyObject }
    var request: JSON { state["request"] ?? .emptyObject }
    var name: String { request["softwareName"]?.jsString ?? "" }
    var status: String { state["status"]?.string ?? "idle" }
    var runningFlag: Bool { json["running"].isTruthy }
    var readOnly: Bool { state["readOnly"].isTruthy }
    var origin: String { state["origin"]?.string ?? "created" }
    var plan: JSON? { json["plan"].truthyValue }
    var content: JSON? { json["content"].truthyValue }
    var screens: [ScreenItem] { json["screens"].items.map(ScreenItem.init) }
    var bundleDir: String { json["bundleDir"]?.string ?? "" }
    var bundleFiles: [String] { json["bundleFiles"].items.compactMap(\.string) }
    var codeSource: JSON { json["codeSource"] ?? .emptyObject }
    var warnings: [String] { state["warnings"].items.map(\.jsString) }
    var log: [JSON] { state["log"].items }
    var feedback: [JSON] { state["feedback"].items }
    var pendingFeedback: [JSON] { feedback.filter { $0["status"]?.string == "pending" } }
    /// 文字的历史版本（新的在前）
    var contentHistory: [JSON] { json["contentHistory"].items }
    /// 上次生成后在软件外被改过的交付文件
    var externalEdits: [String] { json["externalEdits"].items.compactMap(\.string) }
    var timing: JSON? { state["timing"].truthyValue }
    var lastBuild: JSON? { state["lastBuild"].truthyValue }
    func stepStatus(_ step: String) -> String { state["steps"]?[step]?["status"]?.string ?? "pending" }
    func stepMessage(_ step: String) -> String? { state["steps"]?[step]?["message"]?.string }
}

struct ScreenItem: Identifiable {
    let json: JSON
    init(_ json: JSON) { self.json = json }
    var id: String { json["id"]?.string ?? "" }
    var file: String? { json["file"]?.string }
    var mtime: Double? { json["mtime"]?.number }
    var prompt: String { json["prompt"]?.string ?? "" }
    var state: JSON { json["state"] ?? .emptyObject }
    var gate: JSON? { state["gate"].truthyValue }
    var alternates: [JSON] { json["alternates"].items }
    /// 以前用过的截图（新的在前）
    var history: [JSON] { json["history"].items }
    var plan: JSON? { json["plan"].truthyValue }
    var title: String { plan?["title"]?.jsString ?? id }
    var warnings: [String] { (state["imageWarnings"].items + (gate?["warnings"].items ?? [])).map(\.jsString) }
}

// MARK: - 格式化（和 Electron 版界面一致）

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter
}()

/// 10/09 14:05
func formatTime(_ iso: String?) -> String {
    guard let iso, let ms = parseISO(iso) else { return "—" }
    return timeFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
}

func formatTime(ms: Double) -> String { timeFormatter.string(from: Date(timeIntervalSince1970: ms / 1000)) }

/// 12.3 秒 / 123 秒
func formatSeconds(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value >= 100 ? "\(Int(jsRound(value))) 秒" : String(format: "%.1f 秒", value)
}

func formatDurationUI(_ ms: Double?) -> String {
    guard let ms, ms.isFinite else { return "—" }
    return formatDuration(ms)
}

/// 路径里的家目录写成 ~
func shortPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
