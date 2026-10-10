import StudioCore
import SwiftUI

private let SCREEN_STATUS: [String: (label: String, tone: Tone)] = [
    "waiting": ("排队", .neutral),
    "kept": ("沿用", .neutral),
    "generating": ("生成中", .blue),
    "regenerating": ("重新生成", .orange),
    "generated": ("已出图", .green),
    "failed": ("失败", .red),
    "waiting-check": ("待验收", .neutral),
    "checking": ("验收中", .blue),
    "passed": ("验收通过", .green),
]

/// 运行中的实时进度：当前步骤、已用时、预计剩余、每张截图的状态。
struct LivePanel: View {
    let live: JSON
    let data: ProjectData
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.timeIntervalSince1970 * 1000
            panel(now: now)
        }
    }

    func panel(now: Double) -> some View {
        let planned = live["plannedSteps"].items.compactMap(\.string)
        let steps = planned.isEmpty ? STEP_ORDER : planned
        let done = live["doneSteps"].items.compactMap(\.string)
        let step = live["step"]?.string
        let remainingSteps = steps.filter { !done.contains($0) && $0 != step }
        let estimates = model.core?.stepEstimates() ?? [:]
        let currentEst = step.flatMap { estimates[$0] }
        let stepStarted = live["stepStarted"]?.number
        let currentElapsed = stepStarted.map { now - $0 } ?? 0
        // 只对「上次实际跑过」的步骤做估算；没有历史数据时不显示，免得乱报
        let hasEstimate = step != nil && currentEst != nil && remainingSteps.allSatisfy { estimates[$0] != nil || ["design", "receipt", "prompts"].contains($0) }
        let remainingMs: Double? = hasEstimate ? max(0, (currentEst ?? 0) - currentElapsed) + remainingSteps.reduce(0) { $0 + (estimates[$1] ?? 0) } : nil
        let index = step.flatMap { steps.firstIndex(of: $0) } ?? 0
        var screens: [String: JSON] = [:]
        for (id, screen) in live["screens"].fields where screen["status"]?.string != "kept" { screens[id] = screen }
        let finished = screens.filter { ["generated", "passed"].contains($0.value["status"]?.string ?? "") }.count
        let inside = !screens.isEmpty && step.map { ["images", "gate"].contains($0) } == true ? Double(finished) / Double(screens.count) : 0.3
        let percent = max(0.02, min(0.99, (Double(max(0, index)) + inside) / Double(max(1, steps.count))))
        var titles: [String: String] = [:]
        for (order, screen) in (data.plan?["screens"].items ?? []).enumerated() {
            titles[screen["id"]?.jsString ?? ""] = "图\(order + 1) \(screen["title"]?.jsString ?? "")"
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("正在运行").font(.headline)
                if let reason = live["reason"]?.string { TagView(text: reason, tone: .blue) }
                Spacer()
                Text("\(Int(percent * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: percent)
            HStack(spacing: 18) {
                HStack(spacing: 0) {
                    Text("当前：")
                    Text(step.flatMap { UI_STEP_LABELS[$0] } ?? "准备中").fontWeight(.semibold)
                    if let detail = live["detail"]?.string { Text("（\(detail)）") }
                    if let step, ["images", "gate"].contains(step), !screens.isEmpty { Text("  \(finished)/\(screens.count) 张") }
                }
                Text("本步 \(formatDuration(currentElapsed))").foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Text("已用时 ")
                    Text(formatDuration(now - (live["started"]?.number ?? now))).fontWeight(.semibold)
                }
                if let remainingMs {
                    Text("预计还要约 \(formatDuration(max(remainingMs, 5000)))（按以往用时估算）").foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .font(.callout)
            if !screens.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(screens.keys.sorted(), id: \.self) { id in
                        let screen = screens[id]!
                        let status = SCREEN_STATUS[screen["status"]?.string ?? ""] ?? (screen["status"]?.jsString ?? "", .neutral)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(titles[id] ?? id).font(.callout.weight(.semibold)).lineLimit(1)
                            HStack(spacing: 4) {
                                TagView(text: status.label, tone: status.tone)
                                if let started = screen["startedAt"]?.number, ["generating", "regenerating", "generated"].contains(screen["status"]?.string ?? "") {
                                    Text(formatDuration((screen["finishedAt"]?.number ?? now) - started)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            if screen["provider"]?.string != nil || screen["hedged"].isTruthy {
                                Text("\(screen["provider"]?.jsString ?? "")\(screen["hedged"].isTruthy ? " · 补发过" : "")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
