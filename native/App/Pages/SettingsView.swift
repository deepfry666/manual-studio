import StudioCore
import SwiftUI

private let CODE_EXTENSIONS = [".java", ".kt", ".swift", ".dart", ".js", ".ts", ".vue", ".py", ".go", ".cs"]

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.settingsTab {
            case "code": PageScroll(maxWidth: 1000) { CodeSourceSettings() }
            case "pdf": PageScroll(maxWidth: 1000) { PdfSettings() }
            case "txt": PageScroll(maxWidth: 1000) { TxtSettings() }
            case "import": ImportPanel()
            default: PageScroll(maxWidth: 1000) { GeneralSettings() }
            }
        }
        .navigationTitle("设置")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $model.settingsTab) {
                    Text("通用").tag("general")
                    Text("代码来源").tag("code")
                    Text("PDF 与字体").tag("pdf")
                    Text("TXT 字段").tag("txt")
                    Text("导入历史项目").tag("import")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

extension AppModel {
    /// 改了就保存（macOS 设置没有「保存」按钮）。
    func saveSettings(_ patch: JSON) {
        Task {
            await perform { _ = try await core?.updateSettings(patch) }
            await reloadSettings()
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateController.self) private var updater
    @State private var libreOffice: String??

    var body: some View {
        let pipeline = model.settings.pipeline
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "位置") {
                SettingsRow(label: "项目存放位置", info: "新建的项目都放在这里，和以前 skill 用的是同一个文件夹。") {
                    PathText(path: model.settings.workspaceDir).frame(maxWidth: 360, alignment: .trailing)
                    Button("更改…") {
                        if let dir = Panels.chooseDirectory("选择项目存放位置", at: model.settings.workspaceDir) { model.saveSettings(["workspaceDir": .string(dir)]) }
                    }
                }
                SettingsRow(label: "软件数据", info: "设置、加密的密钥、调用记录和项目状态。和 Electron 旧版的数据分开存放。") {
                    PathText(path: model.dataDir).frame(maxWidth: 360, alignment: .trailing)
                    Button("在访达中显示") { model.reveal(model.dataDir) }.buttonStyle(.borderless)
                }
            }
            SettingsGroup(title: "生成") {
                SettingsRow(label: "规划确认", hint: "规划完先停下，让我检查后再继续") {
                    Toggle("", isOn: Binding(get: { pipeline.reviewPlanSingle }, set: { model.saveSettings(["pipeline": ["reviewPlanSingle": .bool($0)]]) })).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(label: "批量同时处理", info: "比如 50 个项目设 3：3 个同时跑，跑完一个补一个。生图总并发由生图线路控制，调大这里不会把线路挤爆。") {
                    ConcurrencyPicker(value: pipeline.batchConcurrency, presets: PROJECT_CONCURRENCY_PRESETS, unit: "个项目") { model.saveSettings(["pipeline": ["batchConcurrency": .number(Double($0))]]) }
                }
                SettingsRow(label: "默认截图数", hint: "新建项目时默认用这个屏数") {
                    NumberField(value: pipeline.defaultScreenCount, range: 2...15, suffix: "屏") { model.saveSettings(["pipeline": ["defaultScreenCount": .number(Double($0))]]) }
                }
                SettingsRow(label: "默认平台") {
                    Picker("", selection: Binding(get: { pipeline.platform }, set: { model.saveSettings(["pipeline": ["platform": .string($0)]]) })) {
                        ForEach(PLATFORMS, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    .frame(width: 240, alignment: .trailing)
                }
                SettingsRow(label: "每屏说明最少字数", info: "按普通字符串长度计。排版模板要求至少 300。") {
                    NumberField(value: pipeline.featureTextFloor, range: 300...1000) { model.saveSettings(["pipeline": ["featureTextFloor": .number(Double($0))]]) }
                }
            }
            SettingsGroup(title: "PDF") {
                SettingsRow(label: "LibreOffice", info: (libreOffice ?? nil) ?? "没有找到 LibreOffice，交付包里不会有 PDF") {
                    switch libreOffice {
                    case .none: StatusDot(kind: .idle, text: "检测中")
                    case .some(.some): StatusDot(kind: .ok, text: "已就绪")
                    case .some(.none): StatusDot(kind: .error, text: "未找到")
                    }
                    Button("重新检测") { detect() }.buttonStyle(.borderless)
                }
            }
            SettingsGroup(title: "更新") {
                SettingsRow(label: "当前版本", hint: "新版本发布在 GitHub：\(Updater.repo)") {
                    Text(updater.currentVersion).monospacedDigit()
                    Button {
                        Task { await updater.check(manual: true) }
                    } label: {
                        if updater.phase == .checking { ProgressView().controlSize(.small) } else { Text("检查更新") }
                    }
                    .disabled(updater.phase == .checking || updater.phase == .downloading)
                }
                SettingsRow(label: "自动检查更新", hint: "打开软件时检查，有新版本会提示") {
                    Toggle("", isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 })).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .task { detect() }
    }

    func detect() {
        libreOffice = .none
        Task { libreOffice = .some(await model.core?.libreOfficeStatus()) }
    }
}

struct CodeSourceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var info: JSON?

    var body: some View {
        let source = model.settings.codeSource
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "代码来源", footer: "所有项目共用。项目第一次生成交付包时会记下当时的来源，之后修改不影响已完成的项目。") {
                SettingsRow(label: "源码 / Word 模板", info: "支持源码文件夹、TXT 或代码 Word（.docx）。Word 模板保留代码正文，非空代码超过3,000行；代码PDF采用固定60页打印布局，不符合要求时停止交付。") {
                    PathText(path: source.path).frame(maxWidth: 360, alignment: .trailing)
                    Button("选择…") {
                        if let picked = Panels.choosePath("选择源码文件夹、TXT 或代码 Word 模板（.docx）", at: source.path) {
                            if Path.extname(picked).lowercased() == ".docx" {
                                importTemplate(picked)
                            } else {
                                model.saveSettings(["codeSource": .obj(["path": .string(picked), "extensions": JSON(source.extensions)])])
                            }
                        }
                    }
                    if !source.path.isEmpty {
                        Button("清除", role: .destructive) { model.saveSettings(["codeSource": .obj(["path": "", "extensions": JSON(source.extensions)])]) }.buttonStyle(.borderless)
                    }
                }
                SettingsRow(label: "文件类型", vertical: true) {
                    TokenEditor(tokens: Binding(get: { source.extensions }, set: { model.saveSettings(["codeSource": .obj(["path": .string(source.path), "extensions": JSON($0)])]) }), suggestions: CODE_EXTENSIONS)
                }
                SettingsRow(label: "跳过的文件夹", vertical: true) {
                    TokenEditor(tokens: Binding(get: { model.settings.codeDefaults.excludeDirs }, set: { model.saveSettings(["codeDefaults": ["excludeDirs": JSON($0)]]) }))
                }
            }
            if let info {
                SettingsGroup(title: "统计") {
                    SettingsRow(label: "文件") { Text("\(info["fileCount"]?.int ?? 0) 个") }
                    SettingsRow(label: "行数") { Text("\((info["lineCount"]?.int ?? 0).formatted()) 行") }
                    SettingsRow(label: "代码文档", info: info["wordTemplate"].isTruthy ? "实际PDF必须正好60页，非空代码超过3,000行才交付。" : "按新宋体9磅估算，用替代字体时页数会有出入。") { Text("\(info["wordTemplate"].isTruthy ? "正好" : "约") \(info["estimatedPages"]?.int ?? 0) 页") }
                    if !info["warnings"].items.isEmpty {
                        SettingsRow(label: "提醒", hint: info["warnings"].items.map(\.jsString).joined(separator: "；"))
                    }
                }
            }
        }
        .task(id: "\(source.path)|\(source.extensions.joined(separator: ","))") {
            guard !source.path.isEmpty else { info = nil; return }
            info = try? await model.core?.inspectCodeSource(path: source.path, extensions: source.extensions)
        }
    }

    private func importTemplate(_ path: String) {
        Task {
            await model.perform { try await model.core?.importCodeTemplate(path) }
            await model.reloadSettings()
        }
    }
}

struct PdfSettings: View {
    @Environment(AppModel.self) private var model
    @State private var fonts: JSON?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "字体", footer: "没装原版字体时固定换成下面的系统字体，转完自动核对 PDF 里实际用的字体。", trailing: AnyView(Button("重新检测") { reload() }.buttonStyle(.borderless))) {
                ForEach(DOC_FONT_ORDER, id: \.self) { kind in
                    let doc = fonts?["docs"]?[kind] ?? .emptyObject
                    SettingsRow(label: doc["label"].text.ifEmpty(DOC_FONTS[kind]!.label), hint: "模板字体：\(DOC_FONTS[kind]!.original)") {
                        if fonts == nil {
                            StatusDot(kind: .idle, text: "检测中")
                        } else if doc["installed"].isTruthy {
                            StatusDot(kind: .ok, text: "使用原版")
                        } else {
                            StatusDot(kind: .warn, text: "未安装原版，改用")
                            Picker("", selection: Binding(get: { doc["choice"].text }, set: { value in
                                Task {
                                    await model.perform { _ = try await model.core?.updateSettings(["pdf": .obj([kind: .string(value)])]) }
                                    await model.reloadSettings()
                                    reload()
                                }
                            })) {
                                ForEach(doc["choices"].items, id: \.self) { choice in
                                    Text(Rx.replace("（.*）", in: choice["label"].text, with: "")).tag(choice["value"].text)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150, alignment: .trailing)
                        }
                    }
                }
            }
            SettingsGroup(title: "原版字体") {
                SettingsRow(label: "安装字体文件", info: "微软雅黑 msyh.ttc、msyhbd.ttc，新宋体在 simsun.ttc 里，Windows 的 C:\\Windows\\Fonts 里都有。微软商业字体，软件不能自带。装好后 PDF 和 Word 完全一致（包括代码文档页数）。") {
                    Button("选择文件…") {
                        let files = Panels.chooseFiles("选择字体文件（可多选）", extensions: ["ttf", "ttc", "otf"])
                        guard !files.isEmpty, let result = model.core?.installFonts(files) else { return }
                        let installed = result["installed"].items.count
                        let skipped = result["skipped"].items.map(\.jsString)
                        if installed > 0 { model.toast(.success, "已安装 \(installed) 个字体") }
                        if !skipped.isEmpty { model.toast(.warning, skipped.joined(separator: "；")) }
                        reload()
                    }
                }
                SettingsRow(label: "已做好的项目", hint: "在历史项目里勾选，点「重新导出 PDF」") {
                    Button("前往") { model.go(.projects) }
                }
            }
        }
        .task { reload() }
    }

    func reload() {
        Task { fonts = try? await model.core?.fontStatus() }
    }
}

struct TxtSettings: View {
    @Environment(AppModel.self) private var model

    func field(_ key: String) -> some View {
        SettingsRow(label: TXT_LABELS.first { $0.key == key }?.label ?? key) {
            CommitTextField(placeholder: "", value: model.settings.txtFields[key] ?? "") { model.saveSettings(["txtFields": .obj([key: .string($0)])]) }
                .frame(minWidth: 160, idealWidth: 260, maxWidth: 260)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                SettingsGroup(title: "开发环境") { ForEach(["devHardware", "devOs", "devTools", "language"], id: \.self) { field($0) } }
            }
            Text("TXT 不再输出运行硬件、运行平台和运行支撑环境。【源程序量】按代码来源的实际行数统计；有代码来源时【编程语言】自动判断。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ScanRow: Identifiable, Hashable {
    let json: JSON
    var id: String { json["dir"]?.string ?? "" }
    var name: String { json["name"].text }
    var grade: String { json["grade"].text }
    var managed: Bool { json["managed"].isTruthy }
}

struct ImportPanel: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [ScanRow]?
    @State private var selection = Set<String>()
    @State private var scanning = false
    @State private var busy = false
    @State private var migrateConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if ElectronMigration.available() {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.down.doc").font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("从 Electron 旧版导入").fontWeight(.semibold)
                        Text(migrationNote).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("导入 Electron 旧版的数据…") { migrateConfirm = true }.buttonStyle(.glass)
                }
                .padding(14)
                .cardBackground(cornerRadius: 12)
            }
            HStack {
                Text("工作区里旧 skill 做过的项目（只登记，不改动文件）").font(.headline)
                Spacer()
                Button("换个文件夹…") {
                    if let dir = Panels.chooseDirectory("选择要扫描的文件夹") { scan(dir) }
                }
                Button("导入 \(selection.count) 个") { importSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || busy)
            }
            Table(rows ?? [], selection: $selection) {
                TableColumn("软件名") { row in Text(row.name).lineLimit(1) }
                TableColumn("状态") { row in
                    if row.managed { TagView(text: "已导入") } else {
                        let info = GRADE_LABEL[row.grade] ?? (row.grade, .neutral)
                        TagView(text: info.label, tone: info.tone)
                    }
                }
                .width(110)
                TableColumn("截图") { row in Text("\(row.json["screens"]?.int ?? 0)") }.width(50)
                TableColumn("修改时间") { row in Text(formatTime(ms: row.json["mtime"]?.number ?? 0)).monospacedDigit() }.width(100)
            }
            .overlay { if scanning { ProgressView() } }
            .onChange(of: selection) { _, next in
                // 已导入的不能再选
                let managed = Set((rows ?? []).filter(\.managed).map(\.id))
                if !next.isDisjoint(with: managed) { selection = next.subtracting(managed) }
            }
        }
        .padding(20)
        .task { scan(nil) }
        .confirmationDialog("从 Electron 旧版导入数据？", isPresented: $migrateConfirm, titleVisibility: .visible) {
            Button("导入") { Task { await model.importFromElectron() } }
        } message: {
            Text("会用 Electron 旧版的设置（线路、大模型、工作区、代码来源等）替换这里的设置，并合并项目列表和调用记录。读取密钥时系统会询问是否允许访问钥匙串。Electron 旧版的数据不会改动。")
        }
    }

    var migrationNote: String {
        if let record = FS.readJSONQuiet(Path.join(model.dataDir, "migrated-from-electron.json")), let at = record["at"]?.string {
            return record["declined"].isTruthy ? "第一次打开时选择了不导入（\(formatTime(at))）。设置、线路、密钥、项目列表和调用记录可以随时导入。" : "上次导入：\(formatTime(at))。再次导入会合并新增的项目和记录。"
        }
        return "把 Electron 旧版的设置、线路、密钥、项目列表和调用记录导入进来。"
    }

    func scan(_ dir: String?) {
        scanning = true
        Task {
            defer { scanning = false }
            do {
                let result = try await model.core?.scanWorkspace(dir) ?? []
                rows = result.map(ScanRow.init(json:))
                selection = Set(rows!.filter { !$0.managed && $0.grade != "readonly" }.map(\.id))
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }

    func importSelected() {
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let result = try await model.core?.importProjects(Array(selection)) else { return }
                await model.reloadProjects()
                model.alert = AlertItem(
                    title: "导入了 \(result.imported.count) 个项目",
                    message: result.failed.isEmpty ? "只是登记，没有改动项目文件夹里的任何文件。" : result.failed.joined(separator: "\n"),
                    actionTitle: "去历史项目",
                    action: { model.go(.projects) }
                )
                scan(nil)
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }
}
