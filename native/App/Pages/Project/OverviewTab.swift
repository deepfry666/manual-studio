import StudioCore
import SwiftUI

/// 项目设置：改了就保存，下次运行只重做受影响的步骤。
struct OverviewTab: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model

    var disabled: Bool { running || data.readOnly }
    var request: JSON { data.request }

    func update(_ patch: JSON) {
        Task {
            await model.perform { try await model.core?.pipeline.updateRequest(data.dir, patch) }
            onChanged()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "进度") {
                StepsIndicator(data: data).padding(14)
            }
            AdaptiveColumns(breakpoint: 760, trailingWidth: 320) {
                VStack(alignment: .leading, spacing: 18) {
                    settingsGroup
                    extrasGroup
                    TimingCard(data: data)
                    if !data.warnings.isEmpty {
                        SettingsGroup(title: "提醒") {
                            ForEach(data.warnings, id: \.self) { warning in
                                Text(warning).font(.callout).padding(.horizontal, 14).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                LogCard(log: data.log)
            }
        }
    }

    var settingsGroup: some View {
        let screenCount = request["screenCount"]?.int
        return SettingsGroup(title: "项目设置", footer: "改截图数、重点功能或平台，下次运行会重新规划并重新生图。") {
            SettingsRow(label: "截图数") {
                Picker("", selection: Binding(get: { screenCount == nil ? "auto" : "fixed" }, set: { value in update(["screenCount": value == "auto" ? .null : .number(Double(screenCount ?? 7))]) })) {
                    Text("固定").tag("fixed")
                    Text("按功能决定").tag("auto")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let screenCount {
                    NumberField(value: screenCount, range: 2...15, suffix: "屏", width: 44) { update(["screenCount": .number(Double($0))]) }
                }
            }
            .disabled(disabled)
            SettingsRow(label: "重点功能") {
                CommitTextField(placeholder: "", value: request["emphasis"].text) { update(["emphasis": .string($0)]) }
                    .frame(minWidth: 160, idealWidth: 300, maxWidth: 300)
            }
            .disabled(disabled)
            SettingsRow(label: "补充说明") {
                CommitTextField(placeholder: "", value: request["notes"].text, axis: .vertical) { update(["notes": .string($0)]) }
                    .frame(minWidth: 160, idealWidth: 300, maxWidth: 300)
            }
            .disabled(disabled)
            SettingsRow(label: "平台") {
                Picker("", selection: Binding(get: { request["platform"].text }, set: { update(["platform": .string($0)]) })) {
                    Text("用设置里的默认平台").tag("")
                    ForEach(PLATFORMS, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .frame(width: 260, alignment: .trailing)
            }
            .disabled(disabled)
        }
    }

    var extrasGroup: some View {
        let version = detectVersion(data.name)
        return SettingsGroup {
            SettingsRow(label: "设计说明章节") {
                Toggle("", isOn: Binding(get: { request["wantDesign"].isTruthy }, set: { update(["wantDesign": .bool($0)]) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .disabled(disabled)
            SettingsRow(label: "额外禁词", info: "截图里也不能出现的词。默认已禁止：完整软件名、去掉版本号的名字\(version.map { "、版本号 \($0)" } ?? "")。", vertical: true) {
                TokenEditor(tokens: Binding(get: { request["extraBrandTokens"].items.map(\.jsString) }, set: { update(["extraBrandTokens": JSON($0)]) }))
            }
            .disabled(disabled)
            SettingsRow(label: "编制时间", hint: "留空用生成当天") {
                CommitTextField(placeholder: "例如 2026年10月3日", value: request["compileDate"].text) { update(["compileDate": .string($0)]) }
                    .frame(width: 200)
            }
            .disabled(disabled)
        }
    }
}

/// 八个步骤的进度条。
struct StepsIndicator: View {
    let data: ProjectData

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(STEP_ORDER.enumerated()), id: \.element) { index, step in
                let status = data.stepStatus(step)
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(fill(status)).frame(width: 26, height: 26)
                        icon(status, index: index)
                    }
                    Text(UI_STEP_LABELS[step] ?? step).font(.caption.weight(.medium)).foregroundStyle(status == "pending" ? .secondary : .primary)
                    if status == "skipped" {
                        Text("不需要").font(.caption2).foregroundStyle(.secondary)
                    } else if status == "review" {
                        Text("待确认").font(.caption2).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity)
                if index < STEP_ORDER.count - 1 {
                    Rectangle().fill(["done", "skipped"].contains(status) ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)).frame(height: 2).padding(.top, 12).frame(maxWidth: 40)
                }
            }
        }
    }

    func fill(_ status: String) -> Color {
        switch status {
        case "done", "skipped": .accentColor
        case "running", "review": .accentColor.opacity(0.18)
        case "failed": .red
        default: .secondary.opacity(0.15)
        }
    }

    @ViewBuilder
    func icon(_ status: String, index: Int) -> some View {
        switch status {
        case "done", "skipped": Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
        case "failed": Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white)
        case "running": ProgressView().controlSize(.mini)
        case "review": Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
        default: Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.secondary)
        }
    }
}

/// 用时：完成用时、累计用时、每次运行和各步骤用时。
struct TimingCard: View {
    let data: ProjectData

    var body: some View {
        if let timing = data.timing, !timing["runs"].items.isEmpty {
            let runs = Array(timing["runs"].items.reversed().prefix(10))
            SettingsGroup(title: "用时", trailing: AnyView(
                Text("\(timing["completedMs"]?.number.map { "完成 \(formatDuration($0)) · " } ?? "")累计 \(formatDurationUI(timing["totalMs"]?.number))").foregroundStyle(.secondary)
            )) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("开始"); Text("原因"); Text("结果"); Text("用时"); Text("各步骤")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        GridRow {
                            Text(formatTime(run["startedAt"]?.string)).monospacedDigit()
                            Text(run["reason"]?.string ?? "运行")
                            Text(["done": "完成", "waiting": "待确认", "failed": "失败", "canceled": "已停止", "idle": "未完"][run["status"]?.string ?? ""] ?? run["status"].text)
                            Text(formatDurationUI(run["ms"]?.number)).monospacedDigit()
                            Text(STEP_ORDER.filter { (run["steps"]?[$0]?.number ?? 0) >= 1000 }.map { "\(UI_STEP_LABELS[$0] ?? $0) \(formatDuration(run["steps"]?[$0]?.number ?? 0))" }.joined(separator: " · ").ifEmpty("—"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .padding(14)
            }
        }
    }
}

struct LogCard: View {
    let log: [JSON]

    var body: some View {
        SettingsGroup(title: "日志") {
            if log.isEmpty {
                Text("还没有日志").foregroundStyle(.secondary).padding(14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(log.reversed().enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(formatTime(entry["at"]?.string)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(entry["message"]?.jsString ?? "")
                                    .font(.callout)
                                    .foregroundStyle(entry["level"]?.string == "error" ? Color.red : entry["level"]?.string == "warn" ? Color.orange : Color.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 560)
            }
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
