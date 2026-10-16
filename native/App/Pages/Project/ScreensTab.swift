import StudioCore
import SwiftUI

func gateTag(_ gate: JSON?) -> (String, Tone) {
    guard let gate else { return ("未验收", .neutral) }
    switch gate["status"]?.string ?? "" {
    case "passed": return (gate["method"]?.string == "imported-receipt" ? "沿用历史回执" : "验收通过", .green)
    case "manual-passed": return ("人工确认通过", .green)
    case "failed": return ("验收不通过", .red)
    case "needs-manual": return ("待人工确认", .orange)
    case "error": return ("验收出错", .red)
    default: return (gate["status"].text, .neutral)
    }
}

struct ScreensTab: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var preview: ScreenItem?
    @State private var promptEdit: ScreenItem?
    @State private var alternates: ScreenItem?
    @State private var regenerate: ScreenItem?
    @State private var history: ScreenItem?

    var body: some View {
        let readOnly = data.readOnly
        if data.screens.isEmpty {
            EmptyHint(title: readOnly ? "这个历史项目没有截图源文件" : "规划完成后会在这里显示截图", systemImage: "iphone")
                .frame(minHeight: 300)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(data.screens) { screen in
                    ScreenCard(screen: screen, data: data, running: running, readOnly: readOnly,
                               onPreview: { preview = screen },
                               onRegenerate: { regenerate = screen },
                               onAlternates: { alternates = screen },
                               onHistory: { history = screen },
                               onPrompt: { promptEdit = screen },
                               onManual: { passed in manual(screen, passed) })
                }
            }
            .sheet(item: $preview) { screen in ScreenPreviewSheet(screen: screen) }
            .sheet(item: $promptEdit) { screen in
                PromptSheet(screen: screen) { text in
                    Task {
                        let ok = await model.perform("提示词已保存，下次运行时会重新生成这一屏") { try await model.core?.pipeline.savePrompt(data.dir, screen.id, text) }
                        if ok { promptEdit = nil }
                        onChanged()
                    }
                }
            }
            .sheet(item: $alternates) { screen in
                AlternatesSheet(screen: screen) { file in
                    Task {
                        let ok = await model.perform("已替换，旧图已归档") { try await model.core?.pipeline.useAlternate(data.dir, screen.id, file) }
                        if ok { alternates = nil }
                        onChanged()
                    }
                }
            }
            .sheet(item: $history) { screen in
                ScreenHistorySheet(screen: screen) { file in
                    Task {
                        let ok = await model.perform("已换回，刚才那张也存进了「以前的截图」") { try await model.core?.pipeline.restoreScreen(data.dir, screen.id, file) }
                        if ok { history = nil }
                        onChanged()
                    }
                }
            }
            .confirmationDialog(regenerate.map { "重新生成 \($0.id)？" } ?? "", isPresented: Binding(get: { regenerate != nil }, set: { if !$0 { regenerate = nil } }), titleVisibility: .visible) {
                Button("重新生成") {
                    guard let screen = regenerate else { return }
                    Task { await model.perform { _ = try model.core?.pipeline.regenerateScreen(data.dir, screen.id) } }
                }
            } message: {
                Text("会花一张图的费用。现在这张会存进「以前的截图」，不满意可以换回来。新图生成后自动验收，文案会按新截图重写这一屏（人工改过的除外）。")
            }
        }
    }

    func manual(_ screen: ScreenItem, _ passed: Bool) {
        Task {
            guard await model.perform(nil, { try await model.core?.pipeline.manualGate(data.dir, screen.id, passed) }) else { return }
            let remaining = data.screens.filter { $0.id != screen.id && !["passed", "manual-passed"].contains($0.gate?["status"]?.string ?? "") }
            if passed && remaining.isEmpty {
                model.toast(.success, "全部截图已确认，继续生成文案和交付包")
                model.core?.run(data.dir)
            } else {
                model.toast(.success, passed ? "已确认没有软件名\(remaining.isEmpty ? "" : "，还剩 \(remaining.count) 张")" : "已标记为不合格，可以重生或换备选图")
            }
            onChanged()
        }
    }
}

struct ScreenCard: View {
    let screen: ScreenItem
    let data: ProjectData
    let running: Bool
    let readOnly: Bool
    let onPreview: () -> Void
    let onRegenerate: () -> Void
    let onAlternates: () -> Void
    let onHistory: () -> Void
    let onPrompt: () -> Void
    let onManual: (Bool) -> Void

    var body: some View {
        let gate = screen.gate
        let tag = gateTag(gate)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let file = screen.file {
                    ScreenImage(path: file, version: screen.mtime)
                        .onTapGesture(perform: onPreview)
                        .help("点击查看大图")
                } else {
                    Rectangle().fill(.quaternary)
                    Text(running ? "生成中…" : "未生成").foregroundStyle(.secondary)
                }
            }
            .frame(height: 340)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.06))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(screen.title).fontWeight(.semibold).lineLimit(1)
                    Text(screen.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 4) {
                    TagView(text: tag.0, tone: tag.1)
                    if let provider = screen.state["providerName"]?.string { TagView(text: provider) }
                    if screen.state["hedged"].isTruthy { TagView(text: "补发胜出", tone: .blue) }
                    if screen.state["promptEdited"].isTruthy && data.origin != "imported" { TagView(text: "提示词已改", tone: .purple) }
                }
                if ["failed", "error"].contains(gate?["status"]?.string ?? "") {
                    Text(gate?["reasons"].items.map(\.jsString).joined(separator: "；") ?? "").font(.caption).foregroundStyle(.red)
                }
                if gate?["status"]?.string == "needs-manual" {
                    HStack {
                        Button("没有软件名，通过") { onManual(true) }.buttonStyle(.borderedProminent).controlSize(.small)
                        Button("不合格", role: .destructive) { onManual(false) }.controlSize(.small)
                    }
                    .disabled(running)
                }
                if !screen.warnings.isEmpty {
                    Text("\(screen.warnings.count) 条提醒").font(.caption).foregroundStyle(.orange).help(screen.warnings.map { "• \($0)" }.joined(separator: "\n"))
                }
                if !readOnly {
                    HStack(spacing: 2) {
                        Button(action: onRegenerate) { Label("重新生成", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }.help("重新生成这一屏")
                        Button(action: onHistory) {
                            HStack(spacing: 3) {
                                Label("以前的截图", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
                                if !screen.history.isEmpty { Text("\(screen.history.count)") }
                            }
                        }
                        .help(screen.history.isEmpty ? "还没有以前的截图" : "以前的截图 \(screen.history.count) 张，可以换回")
                        .disabled(screen.history.isEmpty)
                        Button(action: onAlternates) {
                            HStack(spacing: 3) {
                                Label("备选图", systemImage: "arrow.left.arrow.right").labelStyle(.iconOnly)
                                if !screen.alternates.isEmpty { Text("\(screen.alternates.count)") }
                            }
                        }
                        .help(screen.alternates.isEmpty ? "没有备选图" : "备选图 \(screen.alternates.count) 张")
                        .disabled(screen.alternates.isEmpty)
                        Spacer()
                        Menu {
                            Button("以前的截图…", action: onHistory).disabled(screen.history.isEmpty)
                            Button("查看 / 编辑提示词", action: onPrompt)
                            Button("人工确认：没有软件名") { onManual(true) }
                            Button("人工判定：不合格") { onManual(false) }
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .buttonStyle(.borderless)
                    .disabled(running)
                    .padding(.top, 2)
                }
            }
            .padding(12)
        }
        .cardBackground()
    }
}

struct ScreenPreviewSheet: View {
    let screen: ScreenItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let gate = screen.gate
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(screen.id) · \(screen.title)").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 20) {
                ScreenImage(path: screen.file, version: screen.mtime)
                    .frame(width: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsGroup {
                            SettingsRow(label: "验收") { let tag = gateTag(gate); TagView(text: tag.0, tone: tag.1) }
                            SettingsRow(label: "线路") { Text("\(screen.state["providerName"]?.string ?? "—")\(screen.state["model"]?.string.map { "（\($0)）" } ?? "")") }
                            SettingsRow(label: "尺寸") { Text(screen.state["width"]?.int.map { "\($0)×\(screen.state["height"]?.int ?? 0)" } ?? "—") }
                            SettingsRow(label: "生成时间") { Text(formatTime(screen.state["generatedAt"]?.string)) }
                        }
                        if let inventory = gate?["inventory"]?.string {
                            Text("看图模型抄录的界面内容").font(.headline)
                            Text(inventory).textSelection(.enabled)
                        }
                        if let visible = gate?["visibleText"]?.array, !visible.isEmpty {
                            Text("可见文字：\(visible.map(\.jsString).joined(separator: " · "))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 960, height: 760)
    }
}

struct PromptSheet: View {
    let screen: ScreenItem
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(screen.id) 的生图提示词").font(.title2.weight(.semibold))
            Text("末尾的「不要渲染软件名」禁令由程序自动保留，删掉也会被加回去。").foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .padding(6)
                .cardBackground(cornerRadius: 8)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(text) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 820, height: 600)
        .onAppear { text = screen.prompt }
    }
}

struct AlternatesSheet: View {
    let screen: ScreenItem
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(screen.id) 的备选图").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("补发时另一条线路出的图，换上后要重新验收。").foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                    ForEach(screen.alternates, id: \.self) { item in
                        VStack(spacing: 8) {
                            ScreenImage(path: item["file"]?.string).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 10))
                            Button("用这张") { onUse(item["file"]?.string ?? "") }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 760, height: 560)
    }
}

/// 以前用过的截图：重新生成、换备选图时旧图存在项目的 archive 文件夹，这里可以换回
struct ScreenHistorySheet: View {
    let screen: ScreenItem
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(screen.id) 以前的截图").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("换回后要重新验收，这一屏的说明会按换回的截图重写（人工改过的除外）。现在这张也会存进来，随时能再换。").foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    VStack(spacing: 8) {
                        ScreenImage(path: screen.file, version: screen.mtime).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("现在用的").font(.caption.weight(.semibold))
                    }
                    ForEach(Array(screen.history.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 8) {
                            ScreenImage(path: item["file"]?.string).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(formatTime(item["at"]?.string)).font(.caption).foregroundStyle(.secondary)
                            Button("换回这张") { onUse(item["file"]?.string ?? "") }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 820, height: 620)
    }
}
