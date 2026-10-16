import StudioCore
import SwiftUI

private let QUEUE_LABEL: [String: String] = ["queued": "排队中", "paused": "已暂停"]

private let STATUS_FILTERS: [(value: String, label: String)] = [
    ("all", "全部状态"), ("running", "运行中"), ("queued", "排队中"), ("done", "已完成"), ("waiting", "等待确认"),
    ("needs-attention", "需要处理"), ("idle", "未完成"), ("font", "PDF 字体不对"), ("imported", "导入的历史项目"), ("readonly", "只读"),
]

/// 时间筛选：项目在那段时间里新建、完成、生成交付包或有改动，任意一样都算；用本机时区的自然日。
private let TIME_FILTERS: [(value: String, label: String)] = [("all", "全部时间"), ("today", "今天"), ("yesterday", "昨天"), ("week", "最近 7 天")]

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var statusFilter = "all"
    @State private var timeFilter = "all"
    @State private var batchFilter = "all"
    @State private var pickedDate = Date()
    @State private var datePickerOpen = false
    @State private var selection = Set<String>()
    @State private var exportDirs: ExportRequest?
    @State private var pdfTargets: [String]?
    @State private var removeTargets: [ProjectRow]?
    @State private var codeTemplateTargets: [String]?
    @State private var applyingCodeTemplate = false
    /// 用勾选框勾过：之后单击行也是「加选 / 取消」，不会把已勾选的清掉
    @State private var checkMode = false
    /// 最近一次单击的行和单击前的选择：双击打开时恢复选择，只打开双击的那一行
    @State private var lastClicked: String?
    @State private var beforeClick: Set<String>?
    @State private var handledClick: TimeInterval = 0
    @State private var startPlan: StartPlan?

    /// 开始处理前的清单：哪些会开始，哪些跳过、为什么
    struct StartPlan: Identifiable {
        let id = UUID()
        let dirs: [String]
        let skipped: [String]
    }

    struct ExportRequest: Identifiable {
        let id = UUID()
        let dirs: [String]
    }

    var rows: [ProjectRow] {
        model.projects.filter { project in
            if !query.isEmpty, !project.name.lowercased().contains(query.lowercased()) { return false }
            if !matchesTime(project) { return false }
            if batchFilter != "all", project.batchId != batchFilter { return false }
            switch statusFilter {
            case "all": return true
            case "imported": return project.origin == "imported"
            case "queued": return project.queue?["status"]?.string == "queued"
            case "font": return project.pdfFontProblem
            default: return project.status == statusFilter
            }
        }
    }

    /// 所有批次，最新的在前
    var batches: [(id: String, label: String, count: Int)] {
        var seen: [String: (label: String, count: Int, at: Double)] = [:]
        for project in model.projects {
            guard let id = project.batchId, seen[id] == nil else { continue }
            seen[id] = (project.batchLabel, project.batchCount, project.json["batch"]?["at"]?.number ?? 0)
        }
        return seen.sorted { $0.value.at > $1.value.at }.map { (id: $0.key, label: $0.value.label, count: $0.value.count) }
    }

    var rangeLabel: String {
        if batchFilter != "all", let batch = batches.first(where: { $0.id == batchFilter }) { return "\(batch.label)（\(batch.count)）" }
        if timeFilter == "date" { return pickedDate.formatted(.dateTime.month(.defaultDigits).day().locale(Locale(identifier: "zh_CN"))) }
        return TIME_FILTERS.first { $0.value == timeFilter }?.label ?? "全部时间"
    }

    func matchesTime(_ project: ProjectRow) -> Bool {
        guard timeFilter != "all" else { return true }
        let times = project.activityDates
        let calendar = Calendar.current
        switch timeFilter {
        case "today": return times.contains { calendar.isDateInToday($0) }
        case "yesterday": return times.contains { calendar.isDateInYesterday($0) }
        case "week":
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!
            return times.contains { $0 >= start }
        case "date": return times.contains { calendar.isDate($0, inSameDayAs: pickedDate) }
        default: return true
        }
    }

    var selectedRows: [ProjectRow] { model.projects.filter { selection.contains($0.dir) } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                SetupHint()
                QueueBar()
                if applyingCodeTemplate {
                    Banner(.info, "正在批量应用当前代码模板，逐份验收 PDF 正好 60 页；完成后会显示结果")
                }
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
        .onChange(of: model.devSelection) { _, next in if let next { selection = next; checkMode = next.count > 1 } }
        // 搜索、筛选后看不见的项目不再算选中，批量操作只作用于列表里看得到的（和访达一样）
        .onChange(of: selection.isEmpty) { _, empty in if empty { checkMode = false } }
        .onChange(of: rows.map(\.dir), initial: true) { _, order in model.navigationOrder = order }
        .onChange(of: rows.map(\.dir)) { _, visible in
            let shown = Set(visible)
            if !selection.isSubset(of: shown) { selection.formIntersection(shown) }
            if selection.isEmpty { checkMode = false }
        }
        .onChange(of: batches.map(\.id)) { _, ids in
            // 选中的那一批已经不存在（项目都移除了），退回全部，免得列表莫名其妙是空的
            if batchFilter != "all", !ids.contains(batchFilter) { batchFilter = "all" }
        }
        .onChange(of: model.devTimeFilter) { _, next in
            guard let value = next?.components(separatedBy: "#").first else { return }
            if value == "picker" { datePickerOpen = true }
            else if value.hasPrefix("date:"), let date = ISO8601DateFormatter().date(from: value.dropFirst(5) + "T12:00:00Z") { pickedDate = date; timeFilter = "date" }
            else { timeFilter = value }
        }
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "按软件名搜索")
        .toolbar { toolbar }
        .sheet(item: $exportDirs) { request in
            ExportSheet(dirs: request.dirs) { clearSelection() }
        }
        .confirmationDialog(pdfTargets.map { "重新导出 \($0.count) 个项目的 PDF？" } ?? "", isPresented: Binding(get: { pdfTargets != nil }, set: { if !$0 { pdfTargets = nil } }), titleVisibility: .visible) {
            Button("开始") { startPdfReexport(pdfTargets ?? []) }
        } message: {
            Text("重新导出 PDF；旧指南存在截图超宽时，用已有截图和正文重排指南 Word。TXT、代码 Word 和原截图不变，不调用 AI，旧文件先归档。每个项目依次处理。")
        }
        .confirmationDialog(codeTemplateTargets.map { "将当前代码模板应用到 \($0.count) 个项目？" } ?? "", isPresented: Binding(get: { codeTemplateTargets != nil }, set: { if !$0 { codeTemplateTargets = nil } }), titleVisibility: .visible) {
            Button("应用模板并更新代码材料") { startCodeTemplateBatch(codeTemplateTargets ?? []) }
        } message: {
            Text("使用设置中的 Word 模板，逐份验收代码 PDF 正好 60 页、非空白代码超过 3000 行。更新代码 Word、PDF 和 TXT 的编程语言、源程序量，旧材料先归档。指南和截图保留；不调用 AI。正在运行或排队的项目会跳过，失败项目保留原材料。")
        }
        .confirmationDialog(removeTargets.map { $0.count == 1 ? "移除「\($0[0].name)」？" : "移除 \($0.count) 个项目？" } ?? "", isPresented: Binding(get: { removeTargets != nil }, set: { if !$0 { removeTargets = nil } }), titleVisibility: .visible) {
            Button("只从列表移除") { remove(removeTargets ?? [], deleteFolder: false) }
            Button("移除并把文件夹移到废纸篓", role: .destructive) { remove(removeTargets ?? [], deleteFolder: true) }
        } message: {
            Text("\((removeTargets?.count ?? 0) > 1 ? "\(nameList(removeTargets ?? []))\n\n" : "")只从列表移除：项目文件夹留在原处，以后可以在「设置 → 导入历史项目」里重新导入。\n移到废纸篓：项目文件夹（截图、文档、交付包）一起移到废纸篓，清空废纸篓前都可以恢复。")
        }
        .confirmationDialog(startPlan.map { "开始处理 \($0.dirs.count) 个项目？" } ?? "", isPresented: Binding(get: { startPlan != nil }, set: { if !$0 { startPlan = nil } }), titleVisibility: .visible) {
            Button("开始处理 \(startPlan?.dirs.count ?? 0) 个") { if let plan = startPlan { enqueue(plan.dirs) } }
        } message: {
            Text("跳过 \(startPlan?.skipped.count ?? 0) 个：\n\(startPlan?.skipped.joined(separator: "\n") ?? "")")
        }
    }

    var hasTopContent: Bool { applyingCodeTemplate || model.pdfJob != nil || QueueBar.visible(model) || setupMissing }
    var setupMissing: Bool { SetupHint.missing(model).isEmpty == false }

    var subtitle: String {
        let running = model.projects.filter { $0.status == "running" }.count
        let filtered = !query.isEmpty || statusFilter != "all" || timeFilter != "all" || batchFilter != "all"
        let total = filtered ? "显示 \(rows.count) / 共 \(model.projects.count) 个" : "共 \(model.projects.count) 个"
        return running > 0 ? "\(total) · \(running) 个运行中" : total
    }

    // MARK: 表格

    var table: some View {
        Table(rows, selection: Binding(get: { selection }, set: { tableSelectionChanged($0) })) {
            // 勾选框：不用按住 ⌘ 也能多选；勾过之后单击行也是加选 / 取消
            TableColumn("") { row in
                Toggle("", isOn: Binding(
                    get: { selection.contains(row.dir) },
                    set: { checked in
                        if checked { selection.insert(row.dir); checkMode = true } else { selection.remove(row.dir) }
                        if selection.isEmpty { checkMode = false }
                    }
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
            .width(min: 200, ideal: 260)
            TableColumn("状态") { row in statusTag(row) }
                .width(min: 76, ideal: 90)
            TableColumn("进度") { row in ProgressCell(row: row) }
                .width(min: 150, ideal: 180)
            TableColumn("用时") { row in
                if let timing = row.timing {
                    Text(formatDurationUI(row.mainDurationMs))
                        .monospacedDigit()
                        .help("\(timing["completedMs"]?.number.map { "完成用时 \(formatDuration($0))" } ?? "还没完成")；累计 \(formatDurationUI(timing["totalMs"]?.number))\(timing["lastMs"]?.number.map { "；最近一次运行 \(formatDuration($0))" } ?? "")")
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 64, ideal: 80)
            TableColumn("交付") { row in
                if let files = row.bundleFiles {
                    Text("\(files) 个文件")
                } else if row.hasBundle {
                    Text("有")
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 56, ideal: 70)
            TableColumn("最近构建") { row in Text(formatTime(row.lastBuildAt)).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 76, ideal: 90)
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
            // 双击（或回车）只打开双击的那一行；多选时第一下单击带来的加选 / 取消要撤回
            if let clicked = lastClicked, ids.contains(clicked) || beforeClick?.contains(clicked) == true {
                if let before = beforeClick, before.count > 1 || checkMode { selection = before }
                model.openProject(clicked)
            } else if ids.count == 1, let dir = ids.first {
                model.openProject(dir)
            }
        }
        .onDeleteCommand { askRemove(selectedRows) }
        .onExitCommand { clearSelection() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty { selectionBar }
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
        actionItems(targets)
    }

    /// 右键菜单和底部操作栏「更多」共用同一份操作，内容一致
    @ViewBuilder
    func actionItems(_ targets: [ProjectRow], primary: Bool = true) -> some View {
        if primary {
            Button("开始处理") { start(targets) }
            Button("导出…") { exportDirs = ExportRequest(dirs: targets.map(\.dir)) }
        }
        Button("重新导出 PDF") { askPdf(targets) }
        Button("批量应用当前代码模板…") { askCodeTemplate(targets) }
            .disabled(applyingCodeTemplate || model.pdfJob != nil)
        if targets.contains(where: \.pdfFontProblem) {
            Button("忽略字体提示") { ignoreFonts(targets) }
        }
        if targets.contains(where: { $0.queue != nil && $0.queue?["status"]?.string != "running" }) {
            Button("移出队列") {
                Task {
                    await model.core?.batchRemoveProjects(targets.map(\.dir))
                    model.toast(.success, "已移出队列")
                }
            }
        }
        if let batchId = targets.first?.batchId {
            let members = model.projects.filter { $0.batchId == batchId }
            Divider()
            Button("选中同一批（\(members.count) 个，\(targets[0].batchLabel)）") {
                selection = Set(members.map(\.dir))
                checkMode = true
            }
        }
        Divider()
        Button("从列表移除…") { askRemove(targets) }
            .disabled(targets.allSatisfy { $0.status == "running" })
    }

    /// 选中项目后出现在底部：带文字的批量操作，和右键菜单内容一致
    var selectionBar: some View {
        let targets = selectedRows
        let count = targets.count
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("已选 \(count) 个").fontWeight(.semibold).monospacedDigit()
                if checkMode || count > 1 {
                    Text("单击行加选或取消，双击打开").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("开始处理（\(count)）", systemImage: "play.fill") { start(targets) }
                .buttonStyle(.glassProminent)
            Button("导出（\(count)）…", systemImage: "square.and.arrow.up") { exportDirs = ExportRequest(dirs: targets.map(\.dir)) }
                .buttonStyle(.glass)
            Menu {
                actionItems(targets, primary: false)
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            Divider().frame(height: 20)
            Button("全选当前列表（\(rows.count)）") {
                selection = Set(rows.map(\.dir))
                checkMode = true
            }
            .buttonStyle(.borderless)
            .disabled(selection == Set(rows.map(\.dir)))
            Button("取消选择", systemImage: "xmark.circle.fill") { clearSelection() }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("取消选择（Esc）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// 表格里的点选。已经在多选（勾选过，或选了不止一个）时，不按修饰键的单击是「加选 / 取消」这一行，
    /// 和勾选框一致，不会把已勾选的清掉；只选了一个或没选时，单击仍是只选这一行（和访达一样）。
    /// ⌘ 点选、⇧ 连选、键盘上下键保持系统行为。
    /// 系统表格在多选时单击已选中的行会报告「什么都没选」，所以点的是哪一行按鼠标位置自己算。
    func tableSelectionChanged(_ next: Set<String>) {
        let previous = selection
        let event = NSApp.currentEvent
        let plainClick = event.map { [.leftMouseDown, .leftMouseUp].contains($0.type) && $0.modifierFlags.intersection([.command, .shift]).isEmpty } ?? false
        if plainClick, checkMode || previous.count > 1, let event, let clicked = clickedRow(event) ?? (next.count == 1 ? next.first : nil) {
            // 同一次点击可能回调多次，只处理一次
            if handledClick == event.timestamp { return }
            handledClick = event.timestamp
            beforeClick = previous
            lastClicked = clicked
            selection = previous.contains(clicked) ? previous.subtracting([clicked]) : previous.union([clicked])
        } else {
            beforeClick = previous
            lastClicked = next.subtracting(previous).first ?? (next.count == 1 ? next.first : nil)
            selection = next
        }
        if selection.isEmpty { checkMode = false }
    }

    /// 鼠标点在表格的哪一行（按当前列表顺序）
    func clickedRow(_ event: NSEvent) -> String? {
        guard let content = event.window?.contentView, let hit = content.hitTest(event.locationInWindow) else { return nil }
        var view: NSView? = hit
        while let current = view, !(current is NSTableView) { view = current.superview }
        guard let table = view as? NSTableView else { return nil }
        let index = table.row(at: table.convert(event.locationInWindow, from: nil))
        let list = rows
        return list.indices.contains(index) ? list[index].dir : nil
    }

    func clearSelection() {
        selection = []
        checkMode = false
    }

    func askRemove(_ targets: [ProjectRow]) {
        let removable = targets.filter { $0.status != "running" }
        if removable.isEmpty {
            if !targets.isEmpty { model.toast(.info, "选中的项目都在运行，先停止再移除") }
            return
        }
        removeTargets = removable
    }

    /// 确认框里列出项目名，最多 8 个
    func nameList(_ targets: [ProjectRow]) -> String {
        let names = targets.prefix(8).map { "· \($0.name)" }
        return (names + (targets.count > 8 ? ["… 等 \(targets.count) 个"] : [])).joined(separator: "\n")
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
        ToolbarItem(placement: .navigation) {
            // 时间和批次合在一个菜单里，免得工具栏太挤
            Menu {
                Picker("时间", selection: $timeFilter) {
                    ForEach(TIME_FILTERS, id: \.value) { Text($0.label).tag($0.value) }
                    if timeFilter == "date" { Text(rangeLabel).tag("date") }
                }
                .pickerStyle(.inline)
                Button("选择日期…") { datePickerOpen = true }
                if !batches.isEmpty {
                    Picker("批量新建的批次", selection: $batchFilter) {
                        Text("全部批次").tag("all")
                        ForEach(batches, id: \.id) { batch in Text("\(batch.label)（\(batch.count) 个）").tag(batch.id) }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label(rangeLabel, systemImage: "calendar")
                    .labelStyle(.titleAndIcon)
            }
            .help("按时间或批次筛选：选一批后点「全选」就能一起导出")
            .popover(isPresented: $datePickerOpen, arrowEdge: .bottom) {
                VStack(alignment: .trailing, spacing: 10) {
                    DatePicker("", selection: $pickedDate, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    HStack {
                        Button("取消") { datePickerOpen = false }
                        Button("筛选这一天") {
                            timeFilter = "date"
                            batchFilter = "all"
                            datePickerOpen = false
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14)
            }
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
                Button {
                    selection = Set(rows.map(\.dir))
                    checkMode = true
                } label: { Label("全选", systemImage: "checkmark.circle") }
                    .help("全选当前列表（⌘A）")
                    .disabled(rows.isEmpty)
            }
        }
    }

    // MARK: 操作

    func start(_ targets: [ProjectRow]) {
        var dirs: [String] = []
        var skipped: [String] = []
        for row in targets {
            if row.readOnly { skipped.append("· \(row.name)（只读的历史项目）") }
            else if row.status == "running" { skipped.append("· \(row.name)（正在运行）") }
            else if row.queue?["status"]?.string == "queued" { skipped.append("· \(row.name)（已经在排队）") }
            else { dirs.append(row.dir) }
        }
        guard !dirs.isEmpty else {
            model.toast(.info, "选中的项目都在运行、排队或是只读的")
            return
        }
        // 全部能开始就直接开始；有要跳过的先说清楚
        if skipped.isEmpty { enqueue(dirs) } else { startPlan = StartPlan(dirs: dirs, skipped: Array(skipped.prefix(10)) + (skipped.count > 10 ? ["… 等 \(skipped.count) 个"] : [])) }
    }

    func enqueue(_ dirs: [String]) {
        startPlan = nil
        Task {
            await model.core?.batch.enqueue(dirs)
            model.toast(.success, "已开始：\(dirs.count) 个项目，同时处理 \(concurrencyText(model.settings.pipeline.batchConcurrency))")
            clearSelection()
        }
    }

    func askPdf(_ targets: [ProjectRow]) {
        let dirs = targets.filter { $0.hasBundle && $0.status != "running" }.map(\.dir)
        if dirs.isEmpty { model.toast(.info, "选中的项目没有交付包，或者正在运行") } else {
            if dirs.count < targets.count { model.toast(.info, "跳过 \(targets.count - dirs.count) 个没有交付包或正在运行的项目") }
            pdfTargets = dirs
        }
    }

    func askCodeTemplate(_ targets: [ProjectRow]) {
        guard !targets.isEmpty else { return }
        if Path.extname(model.settings.codeSource.path).lowercased() != ".docx" {
            model.toast(.info, "请先在「设置 → 代码来源」选择新的 Word 代码模板")
        } else { codeTemplateTargets = targets.map(\.dir) }
    }

    func startCodeTemplateBatch(_ dirs: [String]) {
        codeTemplateTargets = nil
        guard let core = model.core, !applyingCodeTemplate else { return }
        applyingCodeTemplate = true
        Task {
            let result = await core.applyCurrentCodeTemplate(dirs)
            await model.reloadProjects()
            applyingCodeTemplate = false
            let done = result["done"].items
            let failed = result["failed"].items.map(\.jsString)
            let skipped = result["skipped"].items.map(\.jsString)
            let fontWarnings = done.flatMap { $0["warnings"].items.map(\.jsString) }
            selection.subtract(done.compactMap { $0["dir"]?.string })
            let details = skipped.map { "跳过：\($0)" } + failed.map { "失败：\($0)" } + fontWarnings
            if !details.isEmpty {
                model.alert = AlertItem(title: "代码模板：成功 \(done.count) 个，跳过 \(skipped.count) 个，失败 \(failed.count) 项", message: details.joined(separator: "\n"))
            } else {
                model.toast(.success, "已更新 \(done.count) 个项目，代码 PDF 均为 60 页，旧材料已归档")
            }
        }
    }

    func startPdfReexport(_ dirs: [String]) {
        clearSelection()
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

    /// 空闲时（没有运行、排队、暂停或需要处理的）不占位置
    static func visible(_ model: AppModel) -> Bool {
        model.batchPaused || model.batchItems.contains { ["running", "queued", "paused", "failed", "needs-attention"].contains($0["status"]?.string ?? "") }
    }

    var body: some View {
        let items = model.batchItems
        if QueueBar.visible(model) {
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
                    ConcurrencyPicker(value: model.settings.pipeline.batchConcurrency, presets: PROJECT_CONCURRENCY_PRESETS, unit: "个项目") { value in
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
