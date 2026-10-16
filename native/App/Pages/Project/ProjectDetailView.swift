import StudioCore
import SwiftUI

enum ProjectTab: String, CaseIterable, Identifiable {
    case overview, plan, editor, delivery
    var id: String { rawValue }

    /// 旧的「截图」「文案」两页合并成了「编辑」
    init?(name: String) {
        if ["screens", "content"].contains(name) { self = .editor } else if let tab = ProjectTab(rawValue: name) { self = tab } else { return nil }
    }
}

struct ProjectDetailView: View {
    let dir: String
    @Environment(AppModel.self) private var model
    @State private var data: ProjectData?
    @State private var loadError: String?
    @State private var tab: ProjectTab?
    @State private var feedbackOpen = false
    @State private var renameOpen = false
    @State private var removeConfirm = false

    var live: JSON? { model.live[dir] }
    var running: Bool { (data?.runningFlag ?? false) || data?.status == "running" || live != nil }

    var body: some View {
        Group {
            if let data {
                content(data)
            } else if let loadError {
                ContentUnavailableView("项目打不开", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(data?.name ?? "项目")
        .task(id: model.revisions[dir, default: 0]) { await reload() }
        .onChange(of: model.devProjectTab) { _, next in if let next { tab = next } }
        .onChange(of: model.devFeedbackOpen) { _, next in if let next { feedbackOpen = next } }
    }

    func reload() async {
        guard let core = model.core else { return }
        do {
            data = ProjectData(json: try await core.getProject(dir))
            loadError = nil
        } catch {
            loadError = messageOf(error)
        }
    }

    /// 没选过时沿用上一个项目停留的页面（逐个检查时翻到下一个项目还在同一页），否则有截图就进编辑页
    var activeTab: ProjectTab {
        tab ?? model.lastProjectTab ?? ((data?.screens.contains { $0.file != nil } ?? false) ? .editor : .overview)
    }

    /// 历史项目列表当前顺序里的上一个 / 下一个（跟着列表的搜索和筛选）
    func neighbor(_ step: Int) -> String? {
        let order = model.navigationOrder
        guard let index = order.firstIndex(of: dir) else { return nil }
        let next = index + step
        return order.indices.contains(next) ? order[next] : nil
    }

    func go(_ step: Int) {
        guard let target = neighbor(step) else { return }
        model.lastProjectTab = activeTab
        model.projectPath = [target]
    }

    @ViewBuilder
    func content(_ data: ProjectData) -> some View {
        let readOnly = data.readOnly
        let statusKey = running ? "running" : readOnly ? "readonly" : data.status
        let status = PROJECT_STATUS[statusKey] ?? (data.status, .neutral)
        let waitingStep = STEP_ORDER.first { data.stepStatus($0) == "review" }
        let refresh: () -> Void = { Task { await reload() } }
        PageScroll {
            HStack(spacing: 6) {
                TagView(text: status.label, tone: status.tone)
                if data.origin == "imported" { TagView(text: "历史") }
                if let timing = data.timing {
                    if let completed = timing["completedMs"]?.number {
                        TagView(text: "用时 \(formatDuration(completed))", tone: .green)
                            .help("累计 \(formatDurationUI(timing["totalMs"]?.number))（含之后的修改和更新），共运行 \(timing["runs"].items.count) 次")
                    } else if let total = timing["totalMs"]?.number, total > 0 {
                        TagView(text: "已用时 \(formatDuration(total))")
                    }
                }
                Spacer()
            }
            if readOnly {
                Banner(.info, "这个历史项目只有交付包，没有文案和截图源文件，只能查看。")
            }
            if let lastError = data.state["lastError"]?.string, !running {
                Banner(.error, "需要处理", message: lastError)
            }
            if waitingStep == "build", !running {
                // 交付包在软件外被改过（比如 WPS 里手改）：问清楚再覆盖
                Banner(.warning, "交付包里有文件在软件外改过", message: data.stepMessage("build")) {
                    Button("保留我的修改") {
                        Task { await model.perform("已保留，这次没有更新交付包") { _ = try await model.core?.pipeline.resolveExternalEdits(dir, overwrite: false) }; refresh() }
                    }
                    .buttonStyle(.glass)
                    Button("覆盖并更新") {
                        Task { await model.perform("已开始更新，手改的文件另存在项目的 archive 文件夹") { _ = try await model.core?.pipeline.resolveExternalEdits(dir, overwrite: true) } }
                    }
                    .buttonStyle(.glassProminent)
                }
            } else if let step = waitingStep, !running {
                Banner(.warning, step == "plan" ? "界面规划已生成，请在「规划」里检查，确认后继续生图" : data.stepMessage(step) ?? "「\(UI_STEP_LABELS[step] ?? step)」等待确认") {
                    if step == "plan" {
                        Button("确认规划，继续") {
                            Task { await model.perform { _ = try await model.core?.pipeline.confirmPlan(dir) } }
                        }
                        .buttonStyle(.glassProminent)
                    } else {
                        Button("去确认截图") { tab = .editor }
                            .buttonStyle(.glass)
                    }
                }
            }
            if let live {
                LivePanel(live: live, data: data)
            }
            switch activeTab {
            case .overview: OverviewTab(data: data, running: running, onChanged: refresh)
            case .plan: PlanTab(data: data, running: running, onChanged: refresh)
            case .editor: EditorTab(data: data, running: running, onChanged: refresh)
            case .delivery: DeliveryTab(data: data, running: running, onChanged: refresh)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: Binding(get: { activeTab }, set: { tab = $0; model.lastProjectTab = $0 })) {
                    Text("概览").tag(ProjectTab.overview)
                    Text("规划").tag(ProjectTab.plan)
                    Text(data.screens.isEmpty ? "编辑" : "编辑 \(data.screens.count) 屏").tag(ProjectTab.editor)
                    Text("交付").tag(ProjectTab.delivery)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .navigation) {
                // 逐个检查：不用回列表就能翻到上一个 / 下一个项目
                ControlGroup {
                    Button { go(-1) } label: { Label("上一个项目", systemImage: "chevron.up") }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                        .help("上一个项目（⌥⌘↑）")
                        .disabled(neighbor(-1) == nil)
                    Button { go(1) } label: { Label("下一个项目", systemImage: "chevron.down") }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                        .help("下一个项目（⌥⌘↓）")
                        .disabled(neighbor(1) == nil)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !readOnly {
                    Button {
                        feedbackOpen.toggle()
                    } label: {
                        Label("修改意见", systemImage: "text.bubble")
                    }
                    .badge(data.pendingFeedback.count)
                    .help("修改意见")
                }
                Button { model.open(dir) } label: { Label("在访达中打开", systemImage: "folder") }
                    .help("在访达中打开")
                Menu {
                    if !readOnly { Button("改软件名…") { renameOpen = true }.disabled(running) }
                    Button("从列表移除…") { removeConfirm = true }.disabled(running)
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }
                if running {
                    Button(role: .destructive) {
                        model.core?.cancel(dir)
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .help("停止")
                } else if !readOnly {
                    Button {
                        model.core?.run(dir)
                    } label: {
                        Label(data.status == "done" ? "检查并更新" : "继续运行", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("r")
                    .help("\(data.status == "done" ? "检查并更新" : "继续运行")（⌘R）")
                }
            }
        }
        .toolbarTitleMenu {
            if !readOnly {
                Button("改软件名…") { renameOpen = true }.disabled(running)
            }
            Button("在访达中打开") { model.open(dir) }
        }
        .inspector(isPresented: $feedbackOpen) {
            FeedbackPanel(data: data, running: running, onChanged: refresh)
                .inspectorColumnWidth(min: 320, ideal: 360, max: 560)
        }
        .sheet(isPresented: $renameOpen) {
            RenameSheet(dir: dir, name: data.name)
        }
        .confirmationDialog("移除「\(data.name)」？", isPresented: $removeConfirm, titleVisibility: .visible) {
            Button("只从列表移除") { remove(deleteFolder: false) }
            Button("移除并把文件夹移到废纸篓", role: .destructive) { remove(deleteFolder: true) }
        } message: {
            Text("只从列表移除：项目文件夹留在原处，以后可以在「设置 → 导入历史项目」里重新导入。\n移到废纸篓：项目文件夹（截图、文档、交付包）一起移到废纸篓，清空废纸篓前都可以恢复。")
        }
    }

    func remove(deleteFolder: Bool) {
        Task {
            if await model.perform(deleteFolder ? "已移除，项目文件夹已移到废纸篓" : "已从列表移除", { try await model.core?.removeFromList(dir, deleteFolder: deleteFolder) }) {
                await model.reloadProjects()
                model.projectPath = []
            }
        }
    }
}

/// 改软件名：不重新规划和生图；用新名字重新验收截图，再重建交付包。
struct RenameSheet: View {
    let dir: String
    let name: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("改软件名").font(.title2.weight(.semibold))
            Text("不会重新规划和生图；会用新名字重新验收截图，再重建交付包。").foregroundStyle(.secondary)
            TextField("软件名（含版本号）", text: $value).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("改名") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            guard let core = model.core else { return }
                            let newDir = try await core.renameSoftware(dir, value.jsTrimmed)
                            dismiss()
                            model.toast(.success, "已改名。截图会按新名字重新验收，然后重建交付包。")
                            await model.reloadProjects()
                            model.projectPath = [newDir]
                            core.run(newDir)
                        } catch {
                            model.toast(.error, messageOf(error))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || value.jsTrimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { value = name }
    }
}
