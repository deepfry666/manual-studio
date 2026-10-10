import StudioCore
import SwiftUI

private let QUEUE_LABEL: [String: String] = ["queued": "排队中", "paused": "已暂停"]

private let STATUS_FILTERS: [(value: String, label: String)] = [
    ("all", "全部状态"), ("running", "运行中"), ("queued", "排队中"), ("done", "已完成"), ("waiting", "等待确认"),
    ("needs-attention", "需要处理"), ("idle", "未完成"), ("font", "PDF 字体不对"), ("imported", "导入的历史项目"), ("readonly", "只读"),
]

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var statusFilter = "all"
    @State private var selection = Set<String>()
    @State private var exportDirs: ExportRequest?
    @State private var pdfTargets: [String]?
    @State private var removeTargets: [ProjectRow]?

    struct ExportRequest: Identifiable {
        let id = UUID()
        let dirs: [String]
    }

    var rows: [ProjectRow] {
        model.projects.filter { project in
            if !query.isEmpty, !project.name.lowercased().contains(query.lowercased()) { return false }
            switch statusFilter {
            case "all": return true
            case "imported": return project.origin == "imported"
            case "queued": return project.queue?["status"]?.string == "queued"
            case "font": return project.pdfFontProblem
            default: return project.status == statusFilter
            }
        }
    }

    var selectedRows: [ProjectRow] { model.projects.filter { selection.contains($0.dir) } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                SetupHint()
                QueueBar()
                if let job = model.pdfJob {
                    Banner(.info, "正在重新导出 PDF：\(job.index + 1)/\(job.total)（\(model.projects.first { $0.dir == job.current }?.name ?? "")）")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, hasTopContent ? 10 : 0)
            table
        }
        .navigationTitle("历史项目")
        .onChange(of: model.devSelection) { _, next in if let next { selection = next } }
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "按软件名搜索")
        .toolbar { toolbar }
        .sheet(item: $exportDirs) { request in
            ExportSheet(dirs: request.dirs) { selection = [] }
        }
        .confirmationDialog(pdfTargets.map { "重新导出 \($0.count) 个项目的 PDF？" } ?? "", isPresented: Binding(get: { pdfTargets != nil }, set: { if !$0 { pdfTargets = nil } }), titleVisibility: .visible) {
            Button("开始") { startPdfReexport(pdfTargets ?? []) }
        } message: {
            Text("只用交付包里现有的 Word 重新转 PDF（修正字体），Word、TXT 和截图都不动；旧 PDF 移到项目的 archive 文件夹。每个项目大约 10–40 秒，一个个来。")
        }
        .confirmationDialog(removeTargets.map { $0.count == 1 ? "移除「\($0[0].name)」？" : "移除 \($0.count) 个项目？" } ?? "", isPresented: Binding(get: { removeTargets != nil }, set: { if !$0 { removeTargets = nil } }), titleVisibility: .visible) {
            Button("只从列表移除") { remove(removeTargets ?? [], deleteFolder: false) }
            Button("移除并把文件夹移到废纸篓", role: .destructive) { remove(removeTargets ?? [], deleteFolder: true) }
        } message: {
            Text("只从列表移除：项目文件夹留在原处，以后可以在「设置 → 导入历史项目」里重新导入。\n移到废纸篓：项目文件夹（截图、文档、交付包）一起移到废纸篓，清空废纸篓前都可以恢复。")
        }
    }

    var hasTopContent: Bool { model.pdfJob != nil || !model.batchItems.isEmpty || setupMissing }
    var setupMissing: Bool { SetupHint.missing(model).isEmpty == false }

    var subtitle: String {
        let running = model.projects.filter { $0.status == "running" }.count
        return running > 0 ? "共 \(model.projects.count) 个 · \(running) 个运行中" : "共 \(model.projects.count) 个"
    }

    // MARK: 表格

    var table: some View {
        Table(rows, selection: $selection) {
            // 勾选框：不用按住 ⌘ 也能多选（点行本身仍是单选）
            TableColumn("") { row in
                Toggle("", isOn: Binding(
                    get: { selection.contains(row.dir) },
                    set: { checked in if checked { selection.insert(row.dir) } else { selection.remove(row.dir) } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("勾选多个项目")
            }
            .width(22)
            TableColumn("软件名") { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).fontWeight(.semibold).lineLimit(1)
                    let tags = rowTags(row)
                    if !tags.isEmpty {
                        HStack(spacing: 4) { ForEach(tags, id: \.0) { TagView(text: $0.0, tone: $0.1) } }
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 220, ideal: 320)
            TableColumn("状态") { row in statusTag(row) }
                .width(min: 80, ideal: 100)
            TableColumn("进度") { row in ProgressCell(row: row) }
                .width(min: 180, ideal: 250)
            TableColumn("用时") { row in
                if let timing = row.timing {
                    Text(formatDurationUI(row.mainDurationMs))
                        .monospacedDigit()
                        .help("\(timing["completedMs"]?.number.map { "完成用时 \(formatDuration($0))" } ?? "还没完成")；累计 \(formatDurationUI(timing["totalMs"]?.number))\(timing["lastMs"]?.number.map { "；最近一次运行 \(formatDuration($0))" } ?? "")")
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("交付") { row in
                if let files = row.bundleFiles {
                    Text("\(files) 个文件")
                } else if row.hasBundle {
                    Text("有")
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 80)
            TableColumn("最近构建") { row in Text(formatTime(row.lastBuildAt)).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 80, ideal: 100)
            TableColumn("") { row in
                Button {
                    model.open(row.dir)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在访达中打开")
            }
            .width(32)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if let dir = ids.first { model.openProject(dir) }
        }
        .overlay {
            if model.projectsLoaded && model.projects.isEmpty {
                EmptyHint(title: "还没有项目", systemImage: "square.grid.2x2", message: "在左边「新建项目」里创建；以前用 skill 做过的项目可以在「设置 → 导入历史项目」里接进来。")
            } else if model.projectsLoaded && rows.isEmpty {
                EmptyHint(title: "没有符合条件的项目", systemImage: "magnifyingglass")
            }
        }
    }

    func rowTags(_ row: ProjectRow) -> [(String, Tone)] {
        var tags: [(String, Tone)] = []
        if row.origin == "imported", let grade = row.grade, let info = GRADE_LABEL[grade] { tags.append(("历史 · \(info.label)", info.tone)) }
        if row.feedbackPending > 0 { tags.append(("\(row.feedbackPending) 条修改意见待处理", .blue)) }
        if row.pdfFontProblem { tags.append(("PDF 字体不对", .orange)) }
        return tags
    }

    @ViewBuilder
    func statusTag(_ row: ProjectRow) -> some View {
        if row.status != "running", let queue = row.queue, let label = QUEUE_LABEL[queue["status"]?.string ?? ""] {
            TagView(text: "\(label)\(queue["position"]?.int.map { " #\($0)" } ?? "")")
        } else {
            let info = PROJECT_STATUS[row.status] ?? (row.status, .neutral)
            TagView(text: info.label, tone: info.tone)
        }
    }

    func remove(_ targets: [ProjectRow], deleteFolder: Bool) {
        Task {
            var done = 0
            for target in targets {
                if await model.perform(nil, { try await model.core?.removeFromList(target.dir, deleteFolder: deleteFolder) }) { done += 1 }
            }
            selection.subtract(targets.map(\.dir))
            await model.reloadProjects()
            if done > 0 { model.toast(.success, deleteFolder ? "已移除 \(done) 个项目，文件夹已移到废纸篓" : "已从列表移除 \(done) 个项目") }
        }
    }

    /// 人工看过 PDF 觉得可以接受：不再标「PDF 字体不对」。
    func ignoreFonts(_ targets: [ProjectRow]) {
        let dirs = targets.filter(\.pdfFontProblem).map(\.dir)
        Task {
            var done = 0
            for dir in dirs {
                if await model.perform(nil, { try await model.core?.pipeline.ignorePdfFontWarning(dir) }) { done += 1 }
            }
            await model.reloadProjects()
            if done > 0 { model.toast(.success, "已忽略 \(done) 个项目的字体提示") }
        }
    }

    @ViewBuilder
    func contextMenu(_ ids: Set<String>) -> some View {
        let targets = model.projects.filter { ids.contains($0.dir) }
        if targets.count == 1, let row = targets.first {
            Button("打开") { model.openProject(row.dir) }
            Button("在访达中显示") { model.reveal(row.dir) }
            Divider()
        }
        Button("开始处理") { start(targets) }
        Button("导出…") { exportDirs = ExportRequest(dirs: targets.map(\.dir)) }
        Button("重新导出 PDF") { askPdf(targets) }
        if targets.contains(where: \.pdfFontProblem) {
            Button("忽略字体提示") { ignoreFonts(targets) }
        }
        if targets.count == 1, let row = targets.first {
            Divider()
            Button("从列表移除…") { removeTargets = [row] }
                .disabled(row.status == "running")
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("状态", selection: $statusFilter) {
                ForEach(STATUS_FILTERS, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
        }
        if selection.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let dirs = model.projects.filter { $0.hasBundle && $0.status != "missing" && ($0.status == "done" || $0.origin == "imported") }.map(\.dir)
                    if dirs.isEmpty { model.toast(.info, "还没有已完成的项目") } else { exportDirs = ExportRequest(dirs: dirs) }
                } label: {
                    Label("导出全部已完成", systemImage: "square.and.arrow.up")
                }
                .help("导出全部已完成")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { selection = Set(rows.map(\.dir)) } label: { Label("全选", systemImage: "checkmark.circle") }
                    .help("全选当前列表")
                    .disabled(rows.isEmpty)
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                Text("已选 \(selection.count) 个").foregroundStyle(.secondary)
                Button { start(selectedRows) } label: { Label("开始处理", systemImage: "play.fill") }
                    .help("开始处理")
                Button { exportDirs = ExportRequest(dirs: Array(selection)) } label: { Label("导出…", systemImage: "square.and.arrow.up") }
                    .help("导出…")
                Menu {
                    Button("重新导出 PDF") { askPdf(selectedRows) }
                    if selectedRows.contains(where: \.pdfFontProblem) {
                        Button("忽略字体提示") { ignoreFonts(selectedRows) }
                    }
                    if selectedRows.contains(where: { $0.queue != nil && $0.queue?["status"]?.string != "running" }) {
                        Button("移出队列") {
                            Task {
                                await model.core?.batchRemoveProjects(Array(selection))
                                model.toast(.success, "已移出队列")
                            }
                        }
                    }
                    Button("从列表移除…") { removeTargets = selectedRows.filter { $0.status != "running" } }
                        .disabled(selectedRows.allSatisfy { $0.status == "running" })
                    Divider()
                    Button("全选当前列表") { selection = Set(rows.map(\.dir)) }
                    Button("取消选择") { selection = [] }
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }
            }
        }
    }

    // MARK: 操作

    func start(_ targets: [ProjectRow]) {
        let dirs = targets.filter { !$0.readOnly && $0.status != "running" }.map(\.dir)
        guard !dirs.isEmpty else {
            model.toast(.info, "选中的项目都在运行或是只读的")
            return
        }
        Task {
            await model.core?.batch.enqueue(dirs)
            model.toast(.success, "已开始：\(dirs.count) 个项目，每次同时处理 \(model.settings.pipeline.batchConcurrency) 个")
            selection = []
        }
    }

    func askPdf(_ targets: [ProjectRow]) {
        let dirs = targets.filter { $0.hasBundle && $0.status != "running" }.map(\.dir)
        if dirs.isEmpty { model.toast(.info, "选中的项目没有交付包，或者正在运行") } else { pdfTargets = dirs }
    }

    func startPdfReexport(_ dirs: [String]) {
        selection = []
        guard let core = model.core else { return }
        Task {
            let result = await core.reexportPdfs(dirs)
            await model.reloadProjects()
            let failed = result["failed"].items.map(\.jsString)
            let done = result["done"].items
            let fontWarnings = done.filter { !($0["warnings"].items.isEmpty) }.count
            if !failed.isEmpty || fontWarnings > 0 {
                var lines: [String] = []
                if fontWarnings > 0 { lines.append("\(fontWarnings) 个项目转出来的字体仍然不对，可以在「设置 → PDF 与字体」里换一个替代字体再试。") }
                lines.append(contentsOf: failed)
                model.alert = AlertItem(title: "重新导出 PDF：成功 \(done.count) 个\(failed.isEmpty ? "" : "，失败 \(failed.count) 个")", message: lines.joined(separator: "\n"))
            } else {
                model.toast(.success, "已重新导出 \(done.count) 个项目的 PDF")
            }
        }
    }
}

/// 进度列：运行中显示当前步骤和已用时间（每秒刷新），否则显示完成几步。
struct ProgressCell: View {
    let row: ProjectRow

    var body: some View {
        if row.readOnly {
            Text("只有交付包，没有源文件").foregroundStyle(.secondary)
        } else if row.status == "running", let live = row.progress {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: row.livePercent).progressViewStyle(.linear)
                    let step = live["step"]?.string
                    let screens = live["screens"].truthyValue
                    let count = step.map { ["images", "gate"].contains($0) } == true && screens != nil ? " \(screens!["finished"]?.int ?? 0)/\(screens!["total"]?.int ?? 0)" : ""
                    Text("\(step.flatMap { UI_STEP_LABELS[$0] } ?? "准备中")\(count) · 已用 \(formatDuration(context.date.timeIntervalSince1970 * 1000 - (live["started"]?.number ?? 0)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } else {
            let summary = row.stepSummary
            Text("\(summary.done)/\(STEP_ORDER.count)\(summary.current.map { " · \(UI_STEP_LABELS[$0] ?? $0)" } ?? " · 完成")")
                .foregroundStyle(.secondary)
                .help(row.lastError ?? row.queue?["error"]?.string ?? (summary.current.map { "下一步：\(UI_STEP_LABELS[$0] ?? $0)" } ?? "全部完成"))
        }
    }
}

/// 批量处理：运行中 / 排队 / 完成数量，同时处理几个，暂停、继续。
struct QueueBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.batchItems
        if !items.isEmpty {
            let counts = Dictionary(grouping: items, by: { $0["status"]?.string ?? "" }).mapValues(\.count)
            let unfinished = (counts["running"] ?? 0) + (counts["queued"] ?? 0) + (counts["paused"] ?? 0)
            let attention = (counts["failed"] ?? 0) + (counts["needs-attention"] ?? 0)
            HStack(spacing: 14) {
                Text("批量处理").fontWeight(.semibold)
                HStack(spacing: 4) {
                    Text("运行中 \(counts["running"] ?? 0) · 排队 \(counts["queued"] ?? 0) · 完成 \(counts["done"] ?? 0)")
                    if attention > 0 { Text("· 需处理 \(attention)").foregroundStyle(.red) }
                    if let paused = counts["paused"], paused > 0 { Text("· 已暂停 \(paused)") }
                }
                .monospacedDigit()
                HStack(spacing: 6) {
                    Text("同时处理")
                    NumberField(value: model.settings.pipeline.batchConcurrency, range: 1...8, suffix: "个项目", width: 40) { value in
                        Task {
                            await model.perform { _ = try await model.core?.updateSettings(["pipeline": ["batchConcurrency": .number(Double(value))]]) }
                            await model.reloadSettings()
                        }
                    }
                }
                Spacer()
                if model.batchPaused {
                    Button("继续", systemImage: "play.fill") { Task { await model.core?.batch.resume() } }
                        .buttonStyle(.glassProminent)
                } else if unfinished > 0 {
                    Button("暂停全部", systemImage: "pause.fill") { Task { await model.core?.batch.pause() } }
                        .buttonStyle(.glass)
                }
                Button("清除已完成的记录") { Task { await model.core?.batch.clearFinished() } }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .cardBackground(cornerRadius: 12)
        }
    }
}

/// 首次使用：没有可用的生图线路或没有给规划/文案选模型时，提示先去配置。
struct SetupHint: View {
    @Environment(AppModel.self) private var model

    static func missing(_ model: AppModel) -> [(text: String, tab: String)] {
        let providers = model.settings.providers.filter { $0.enabled && (model.providerKeys[$0.id] ?? false) }
        var missing: [(String, String)] = []
        if providers.isEmpty { missing.append(("还没有可用的生图线路（需要启用并填好密钥）", "providers")) }
        if model.settings.llm.assignment("plan") == nil || model.settings.llm.assignment("content") == nil { missing.append(("还没有给「规划界面」和「撰写说明文字」选择大模型", "llm")) }
        return missing
    }

    var body: some View {
        let missing = SetupHint.missing(model)
        if !missing.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(.blue).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始之前先完成配置").fontWeight(.semibold)
                    ForEach(missing, id: \.tab) { item in
                        HStack(spacing: 4) {
                            Text(item.text)
                            Button("去配置") { model.go(.models, tab: item.tab) }.buttonStyle(.link)
                        }
                        .font(.callout)
                    }
                    if model.settings.llm.assignment("gate") == nil {
                        Text("截图验收没有配置看图模型时，需要人工逐张确认截图里没有软件名。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.blue.opacity(0.18)))
        }
    }
}
