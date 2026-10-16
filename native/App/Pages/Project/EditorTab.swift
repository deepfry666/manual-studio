import StudioCore
import SwiftUI

/// 编辑：和最终指南一样，一屏一行，左边截图、右边说明。在哪里看到问题就在哪里改：
/// - 文字直接改，自动保存，每处都能从「历史」换回以前的文字；
/// - 每一行下面写「要怎么改」，点「改图」或「只改文字」，不用先攒清单再整理；
/// - 截图可以重新生成、换回以前的截图、换备选图；封面介绍和设计说明同样直接改。
struct EditorTab: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model

    struct Section: Equatable {
        var title: String
        var text: String
    }

    // 文字：输入框里的内容和最近一次读到 / 保存的内容；不同就是还没保存的修改
    @State private var overview = ""
    @State private var titles: [String: String] = [:]
    @State private var texts: [String: String] = [:]
    @State private var sections: [Section] = []
    @State private var baseOverview = ""
    @State private var baseTitles: [String: String] = [:]
    @State private var baseTexts: [String: String] = [:]
    @State private var baseSections: [Section] = []
    @State private var loadedKey = ""
    @State private var saveState: SaveState = .idle
    @State private var rewrite: (ids: [String], label: String)?
    // 每一行的「要怎么改」
    @State private var changeRequests: [String: String] = [:]
    // 截图的弹窗
    @State private var preview: ScreenItem?
    @State private var promptEdit: ScreenItem?
    @State private var alternates: ScreenItem?
    @State private var history: ScreenItem?
    @State private var regenerate: ScreenItem?

    enum SaveState: Equatable {
        case idle, saving, saved(Date), failed(String)
    }

    var floor: Int { model.settings.pipeline.featureTextFloor }
    var contentScreens: [JSON] { data.content?["screens"].items ?? [] }
    var editable: Bool { !data.readOnly && !running }

    var contentKey: String {
        guard let content = data.content else { return "" }
        return JSON.obj([
            "o": content["cover"]?["overview"] ?? .null,
            "s": .array(contentScreens.map { .array([$0["id"] ?? .null, $0["title"] ?? .null, $0["text"] ?? .null]) }),
            "d": content["design"]?["sections"] ?? .null,
        ]).serialized()
    }

    var editsKey: String {
        JSON.obj([
            "o": .string(overview),
            "t": JSON(titles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }),
            "x": JSON(texts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }),
            "d": JSON(sections.map { "\($0.title)=\($0.text)" }),
        ]).serialized()
    }

    var body: some View {
        Group {
            if data.screens.isEmpty && data.content == nil {
                EmptyHint(title: data.readOnly ? "这个历史项目没有截图源文件" : "规划完成后会在这里显示截图和说明", systemImage: "rectangle.split.2x1")
                    .frame(minHeight: 300)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    statusLine
                    if data.content != nil { coverEditor }
                    ForEach(Array(data.screens.enumerated()), id: \.element.id) { index, screen in
                        screenRow(index, screen)
                    }
                    if !sections.isEmpty { designEditor }
                }
            }
        }
        .onAppear(perform: syncFromContent)
        .onChange(of: contentKey) { _, _ in syncFromContent() }
        // 停止输入 0.8 秒后自动保存；继续输入会重新计时
        .task(id: editsKey) {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { await autosave() }
        }
        .onDisappear(perform: flush)
        .background {
            // ⌘S：马上保存（平时不用按）
            Button("") { Task { await autosave() } }.keyboardShortcut("s").hidden()
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
                    let ok = await model.perform("已替换，旧图已存进「以前的截图」") { try await model.core?.pipeline.useAlternate(data.dir, screen.id, file) }
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
            Text("会花一张图的费用，按原来的要求再生成一次。想改什么的话，在这一行下面写「要怎么改」再点「改图」。现在这张会存进「以前的截图」。")
        }
        .confirmationDialog(rewrite.map { "让大模型重写\($0.label)？" } ?? "", isPresented: Binding(get: { rewrite != nil }, set: { if !$0 { rewrite = nil } }), titleVisibility: .visible) {
            Button("重写") {
                guard let target = rewrite else { return }
                Task {
                    await autosave()
                    await model.perform { _ = try await model.core?.pipeline.rewriteContent(data.dir, target.ids) }
                }
            }
        } message: {
            Text("会覆盖现在的文字（包括你改过的部分）。现在的文字会存进「历史」，不满意可以换回来。想按要求改，在这一行下面写「要怎么改」再点「只改文字」。")
        }
    }

    // MARK: 顶部状态

    var statusLine: some View {
        HStack(spacing: 8) {
            if data.submitted {
                Text("已提交，只能查看；要修改请先取消已提交").foregroundStyle(.secondary)
            } else if data.readOnly {
                Text("只读项目，不能修改").foregroundStyle(.secondary)
            } else if running {
                Label("正在运行，跑完后才能修改", systemImage: "hourglass").foregroundStyle(.secondary)
            } else {
                switch saveState {
                case .saving: ProgressView().controlSize(.small); Text("正在保存…").foregroundStyle(.secondary)
                case .saved(let date): Label("已自动保存 \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                case .failed(let message): Label("没有保存：\(message)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .idle: Label("文字改了自动保存", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                Spacer()
                Text("改完点右上角「检查并更新」（⌘R）更新交付包").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 封面介绍

    var coverEditor: some View {
        SettingsGroup(title: "封面介绍（也会写进 TXT 的【软件的主要功能】）", trailing: data.readOnly ? nil : AnyView(HStack(spacing: 10) {
            historyMenu("overview") { overview = $0 }
            Button("让大模型重写") { rewrite = (["overview"], "封面介绍") }.disabled(running)
        })) {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $overview).font(.body).frame(minHeight: 80).scrollContentBackground(.hidden).disabled(!editable)
                HStack(spacing: 8) {
                    Text("\(overview.jsTrimmed.jsLength) 字").font(.caption).foregroundStyle(.secondary)
                    if Rx.test(#"图\s*[0-9]"#, overview) { warning("正文里不要写「图N」，图注会自动生成") }
                }
            }
            .padding(12)
        }
    }

    // MARK: 一屏一行

    func screenRow(_ index: Int, _ screen: ScreenItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                screenColumn(screen).frame(width: 240)
                textColumn(index, screen).frame(maxWidth: 640, alignment: .leading)
            }
            if !data.readOnly { changeBar(index, screen) }
        }
        .padding(14)
        .cardBackground(cornerRadius: 14)
    }

    func screenColumn(_ screen: ScreenItem) -> some View {
        let gate = screen.gate
        let tag = gateTag(gate)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let file = screen.file {
                    ScreenImage(path: file, version: screen.mtime)
                        .onTapGesture { preview = screen }
                        // 和访达一样：选中（Tab 键移过来）后按空格看大图
                        .focusable()
                        .focusEffectDisabled(false)
                        .onKeyPress(.space) { preview = screen; return .handled }
                        .help("点击或按空格查看大图")
                } else {
                    Rectangle().fill(.quaternary)
                    Text(running ? "生成中…" : "未生成").foregroundStyle(.secondary)
                }
            }
            .frame(height: 440)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            FlowLayout(spacing: 4) {
                TagView(text: tag.0, tone: tag.1)
                if screen.state["promptEdited"].isTruthy && data.origin != "imported" { TagView(text: "提示词已改", tone: .purple) }
            }
            if ["failed", "error"].contains(gate?["status"]?.string ?? "") {
                Text(gate?["reasons"].items.map(\.jsString).joined(separator: "；") ?? "").font(.caption).foregroundStyle(.red)
            }
            if !screen.warnings.isEmpty {
                Text("\(screen.warnings.count) 条提醒").font(.caption).foregroundStyle(.orange).help(screen.warnings.map { "• \($0)" }.joined(separator: "\n"))
            }
            if gate?["status"]?.string == "needs-manual", !data.readOnly {
                HStack {
                    Button("没有软件名，通过") { manual(screen, true) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("不合格", role: .destructive) { manual(screen, false) }.controlSize(.small)
                }
                .disabled(running)
            }
            if !data.readOnly {
                HStack(spacing: 4) {
                    Button { regenerate = screen } label: { Label("重新生成", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                        .help("按原来的要求重新生成这一屏（花一张图的费用）")
                    Button { history = screen } label: {
                        HStack(spacing: 3) {
                            Label("以前的截图", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
                            if !screen.history.isEmpty { Text("\(screen.history.count)") }
                        }
                    }
                    .help(screen.history.isEmpty ? "还没有以前的截图" : "以前的截图 \(screen.history.count) 张，可以换回")
                    .disabled(screen.history.isEmpty)
                    Button { alternates = screen } label: {
                        HStack(spacing: 3) {
                            Label("备选图", systemImage: "arrow.left.arrow.right").labelStyle(.iconOnly)
                            if !screen.alternates.isEmpty { Text("\(screen.alternates.count)") }
                        }
                    }
                    .help(screen.alternates.isEmpty ? "没有备选图" : "备选图 \(screen.alternates.count) 张")
                    .disabled(screen.alternates.isEmpty)
                    Spacer()
                    Menu {
                        Button("查看大图") { preview = screen }.disabled(screen.file == nil)
                        Button("以前的截图…") { history = screen }.disabled(screen.history.isEmpty)
                        Button("查看 / 编辑提示词") { promptEdit = screen }
                        Divider()
                        Button("人工确认：没有软件名") { manual(screen, true) }
                        Button("人工判定：不合格") { manual(screen, false) }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .buttonStyle(.borderless)
                .disabled(running)
            }
        }
    }

    @ViewBuilder
    func textColumn(_ index: Int, _ screen: ScreenItem) -> some View {
        let id = screen.id
        if contentScreens.contains(where: { $0["id"]?.string == id }) {
            let text = texts[id] ?? ""
            let length = text.jsTrimmed.jsLength
            let edited = data.state["screens"]?[id]?["textEdited"].isTruthy ?? false
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("图\(index + 1)").fontWeight(.semibold)
                    TextField("界面标题（也是图注）", text: Binding(get: { titles[id] ?? "" }, set: { titles[id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .disabled(!editable)
                    if edited { TagView(text: "人工改过", tone: .purple) }
                    Spacer()
                    Text(length >= floor ? "\(length) 字 ✓" : "\(length) / \(floor) 字").monospacedDigit().foregroundStyle(length >= floor ? Color.secondary : Color.orange)
                    if !data.readOnly {
                        historyMenu(id) { texts[id] = $0 }
                        Button("让大模型重写") { rewrite = ([id], "图\(index + 1)的说明") }.disabled(running)
                    }
                }
                TextEditor(text: Binding(get: { texts[id] ?? "" }, set: { texts[id] = $0 }))
                    .font(.body)
                    .lineSpacing(3)
                    .frame(minHeight: 300)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(!editable)
                if length < floor { warning("还差 \(floor - length) 字；不够 \(floor) 字时交付包生成不了") }
                if Rx.test(#"图\s*[0-9]"#, text) { warning("正文里不要写「图N」，图注会自动生成") }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("图\(index + 1)").fontWeight(.semibold)
                    Text(screen.title).foregroundStyle(.secondary)
                }
                Text("截图检查通过后会自动写这一屏的说明。").foregroundStyle(.secondary)
            }
        }
    }

    /// 每一行下面：写要怎么改，直接改图或只改文字
    func changeBar(_ index: Int, _ screen: ScreenItem) -> some View {
        let id = screen.id
        let request = (changeRequests[id] ?? "").jsTrimmed
        let hasText = contentScreens.contains { $0["id"]?.string == id }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("要怎么改").foregroundStyle(.secondary)
                TextField("例如：底部按钮改成绿色、日期都改成内容日期、说明多写异常处理", text: Binding(get: { changeRequests[id] ?? "" }, set: { changeRequests[id] = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .disabled(!editable)
                Button("改图") { applyChange(index, screen, image: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(request.isEmpty || !editable || screen.file == nil)
                    .help("按这句话改这张截图（花一张图的费用），说明会按新图更新；改完会核对有没有改到")
                Button("只改文字") { applyChange(index, screen, image: false) }
                    .disabled(request.isEmpty || !editable || !hasText)
                    .help("只按这句话改这一屏的说明，不生图")
            }
            Text("改图会花一张图的费用，改完会核对有没有改到；只改文字不生图。现在的图和文字都会留在历史里。").font(.caption).foregroundStyle(.secondary)
        }
    }

    func applyChange(_ index: Int, _ screen: ScreenItem, image: Bool) {
        let instruction = (changeRequests[screen.id] ?? "").jsTrimmed
        guard !instruction.isEmpty else { return }
        Task {
            await autosave()
            let action: JSON = .obj([
                "type": .string(image ? "image" : "text"), "target": .string(screen.id), "targetLabel": .string("图\(index + 1)「\(screen.title)」"),
                "instruction": .string(instruction), "items": [],
            ])
            let ok = await model.perform(image ? "已开始改图，进度在页面上方" : "已开始改这一屏的说明") {
                _ = try await model.core?.pipeline.applyFeedback(data.dir, actions: [action])
            }
            if ok {
                changeRequests[screen.id] = ""
                onChanged()
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
                model.toast(.success, passed ? "已确认没有软件名\(remaining.isEmpty ? "" : "，还剩 \(remaining.count) 张")" : "已标记为不合格，可以重新生成或换回以前的截图")
            }
            onChanged()
        }
    }

    // MARK: 设计说明

    var designEditor: some View {
        SettingsGroup(title: "设计说明") {
            ForEach(sections.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("小节标题", text: Binding(get: { sections.indices.contains(index) ? sections[index].title : "" }, set: { if sections.indices.contains(index) { sections[index].title = $0 } }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .disabled(!editable)
                        Spacer()
                        if !data.readOnly { historyMenu("design-\(index + 1)") { value in if sections.indices.contains(index) { sections[index].text = value } } }
                    }
                    TextEditor(text: Binding(get: { sections.indices.contains(index) ? sections[index].text : "" }, set: { if sections.indices.contains(index) { sections[index].text = $0 } }))
                        .font(.body)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .disabled(!editable)
                }
                .padding(12)
            }
        }
    }

    // MARK: 历史和保存

    func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
    }

    /// 这一处以前的文字（自己改之前的、大模型重写之前的），点一下换回来（换回也会自动保存）
    func historyMenu(_ target: String, apply: @escaping (String) -> Void) -> some View {
        let versions = data.contentHistory.filter { $0["target"]?.string == target }
        return Menu {
            ForEach(Array(versions.prefix(30).enumerated()), id: \.offset) { _, version in
                Button("\(formatTime(version["at"]?.string)) · \(version["source"]?.jsString ?? "")：\(version["text"]?.jsString.jsTrimmed.jsSlice(0, 24) ?? "")…") {
                    apply(version["text"]?.jsString ?? "")
                }
            }
        } label: {
            Label(versions.isEmpty ? "历史" : "历史 \(versions.count)", systemImage: "clock.arrow.circlepath")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(versions.isEmpty || !editable)
        .help(versions.isEmpty ? "还没有以前的版本" : "换回以前的文字")
    }

    func syncFromContent() {
        guard let content = data.content, contentKey != loadedKey else { return }
        loadedKey = contentKey
        let serverOverview = content["cover"]?["overview"].text ?? ""
        let serverTitles = Dictionary(contentScreens.map { ($0["id"]?.jsString ?? "", $0["title"]?.jsString ?? "") }, uniquingKeysWith: { first, _ in first })
        let serverTexts = Dictionary(contentScreens.map { ($0["id"]?.jsString ?? "", $0["text"]?.jsString ?? "") }, uniquingKeysWith: { first, _ in first })
        let serverSections = (content["design"]?["sections"].items ?? []).map { Section(title: $0["title"].text, text: $0["text"].text) }
        // 输入框没改过的跟着磁盘更新；改过还没保存的保留，等自动保存
        if overview == baseOverview { overview = serverOverview }
        for (id, value) in serverTitles where titles[id] == baseTitles[id] { titles[id] = value }
        for (id, value) in serverTexts where texts[id] == baseTexts[id] { texts[id] = value }
        if sections == baseSections { sections = serverSections }
        baseOverview = serverOverview
        baseTitles = serverTitles
        baseTexts = serverTexts
        baseSections = serverSections
    }

    struct Pending {
        var overview: String?
        var patches: [JSON]
        var design: [JSON]?
    }

    func pending() -> Pending? {
        guard data.content != nil, !data.readOnly else { return nil }
        let changedOverview = overview != baseOverview ? overview : nil
        let patches: [JSON] = contentScreens.compactMap { screen in
            let id = screen["id"]?.jsString ?? ""
            guard titles[id] != baseTitles[id] || texts[id] != baseTexts[id] else { return nil }
            return .obj(["id": .string(id), "title": .string(titles[id] ?? ""), "text": .string(texts[id] ?? "")])
        }
        let design: [JSON]? = sections != baseSections ? sections.map { .obj(["title": .string($0.title), "text": .string($0.text)]) } : nil
        return changedOverview == nil && patches.isEmpty && design == nil ? nil : Pending(overview: changedOverview, patches: patches, design: design)
    }

    func autosave() async {
        guard !running, let core = model.core, let change = pending() else { return }
        let savedSections = sections
        saveState = .saving
        do {
            try await core.pipeline.saveContent(data.dir, overview: change.overview, screens: change.patches, design: change.design)
            if let saved = change.overview { baseOverview = saved }
            for patch in change.patches {
                let id = patch["id"]?.jsString ?? ""
                baseTitles[id] = patch["title"]?.jsString
                baseTexts[id] = patch["text"]?.jsString
            }
            if change.design != nil { baseSections = savedSections }
            saveState = .saved(Date())
            onChanged()
        } catch {
            saveState = .failed(messageOf(error))
        }
    }

    /// 离开时把没保存的修改存掉（不等计时）
    func flush() {
        guard !running, let core = model.core, let change = pending() else { return }
        let dir = data.dir
        Task {
            do { try await core.pipeline.saveContent(dir, overview: change.overview, screens: change.patches, design: change.design) }
            catch { model.toast(.error, "文字没有保存：\(messageOf(error))") }
        }
    }
}
