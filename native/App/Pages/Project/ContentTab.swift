import StudioCore
import SwiftUI

/// 文案：改了自动保存（像备忘录一样，不用点保存）；字数不够、写了「图N」只在那一屏提醒，不拦着保存。
/// 每一处都能从「历史」里找回以前的文字（自己改之前的、大模型重写之前的）。
struct ContentTab: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var overview = ""
    @State private var titles: [String: String] = [:]
    @State private var texts: [String: String] = [:]
    /// 最近一次从磁盘读到 / 保存成功的内容；和输入框不同就是还没保存的修改
    @State private var baseOverview = ""
    @State private var baseTitles: [String: String] = [:]
    @State private var baseTexts: [String: String] = [:]
    @State private var loadedKey = ""
    @State private var saveState: SaveState = .idle
    @State private var rewrite: (ids: [String], label: String)?

    enum SaveState: Equatable {
        case idle, saving, saved(Date), failed(String)
    }

    var floor: Int { model.settings.pipeline.featureTextFloor }
    var contentScreens: [JSON] { data.content?["screens"].items ?? [] }
    var editable: Bool { !data.readOnly && !running }

    /// 磁盘上的文案变了才同步，避免后台刷新冲掉还没保存的修改
    var contentKey: String {
        guard let content = data.content else { return "" }
        return JSON.obj(["o": content["cover"]?["overview"] ?? .null, "s": .array(contentScreens.map { .array([$0["id"] ?? .null, $0["title"] ?? .null, $0["text"] ?? .null]) })]).serialized()
    }

    /// 输入框里的内容，变了就（稍等一下）自动保存
    var editsKey: String {
        JSON.obj(["o": .string(overview), "t": JSON(titles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }), "x": JSON(texts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })]).serialized()
    }

    var body: some View {
        Group {
            if let content = data.content {
                VStack(alignment: .leading, spacing: 16) {
                    statusLine
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
                    ForEach(Array(contentScreens.enumerated()), id: \.offset) { index, screen in
                        screenEditor(index, screen)
                    }
                    if let sections = content["design"]?["sections"]?.array, !sections.isEmpty {
                        SettingsGroup(title: "设计说明") {
                            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(section["title"]?.jsString ?? "").fontWeight(.semibold)
                                    Text(section["text"]?.jsString ?? "").textSelection(.enabled)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } else {
                EmptyHint(title: "截图验收后会在这里生成说明文字", systemImage: "doc.text").frame(minHeight: 300)
            }
        }
        .onAppear(perform: syncFromContent)
        .onChange(of: contentKey) { _, _ in syncFromContent() }
        // 停止输入 0.8 秒后自动保存；继续输入会重新计时
        .task(id: editsKey) {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { await autosave() }
        }
        // 切到别的标签页或离开项目时，把还没保存的修改存掉
        .onDisappear(perform: flush)
        .confirmationDialog(rewrite.map { "让大模型重写\($0.label)？" } ?? "", isPresented: Binding(get: { rewrite != nil }, set: { if !$0 { rewrite = nil } }), titleVisibility: .visible) {
            Button("重写") {
                guard let target = rewrite else { return }
                Task {
                    // 先把没保存的修改存掉（存进历史），再让大模型重写
                    await autosave()
                    await model.perform { _ = try await model.core?.pipeline.rewriteContent(data.dir, target.ids) }
                }
            }
        } message: {
            Text("会覆盖现在的文字（包括你改过的部分）。现在的文字会存进「历史」，不满意可以换回来。")
        }
    }

    var statusLine: some View {
        HStack(spacing: 8) {
            if data.readOnly {
                Text("只读项目，不能修改").foregroundStyle(.secondary)
            } else if running {
                Label("正在运行，跑完后才能修改文字", systemImage: "hourglass").foregroundStyle(.secondary)
            } else {
                switch saveState {
                case .saving: ProgressView().controlSize(.small); Text("正在保存…").foregroundStyle(.secondary)
                case .saved(let date): Label("已自动保存 \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                case .failed(let message): Label("没有保存：\(message)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .idle: Label("修改会自动保存", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                Spacer()
                Text("改完点右上角「检查并更新」更新交付包").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    func screenEditor(_ index: Int, _ screen: JSON) -> some View {
        let id = screen["id"]?.jsString ?? ""
        let text = texts[id] ?? ""
        let length = text.jsTrimmed.jsLength
        let edited = data.state["screens"]?[id]?["textEdited"].isTruthy ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("图\(index + 1)").fontWeight(.semibold)
                TextField("", text: Binding(get: { titles[id] ?? "" }, set: { titles[id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
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
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .disabled(!editable)
            if length < floor { warning("还差 \(floor - length) 字；不够 \(floor) 字时交付包生成不了") }
            if Rx.test(#"图\s*[0-9]"#, text) { warning("正文里不要写「图N」，图注会自动生成") }
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }

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
        // 输入框没改过的跟着磁盘更新；改过还没保存的保留，等自动保存
        if overview == baseOverview { overview = serverOverview }
        for (id, value) in serverTitles where titles[id] == baseTitles[id] { titles[id] = value }
        for (id, value) in serverTexts where texts[id] == baseTexts[id] { texts[id] = value }
        baseOverview = serverOverview
        baseTitles = serverTitles
        baseTexts = serverTexts
    }

    /// 还没保存的修改
    func pending() -> (overview: String?, patches: [JSON])? {
        guard data.content != nil, !data.readOnly else { return nil }
        let changedOverview = overview != baseOverview ? overview : nil
        let patches: [JSON] = contentScreens.compactMap { screen in
            let id = screen["id"]?.jsString ?? ""
            guard titles[id] != baseTitles[id] || texts[id] != baseTexts[id] else { return nil }
            return .obj(["id": .string(id), "title": .string(titles[id] ?? ""), "text": .string(texts[id] ?? "")])
        }
        return changedOverview == nil && patches.isEmpty ? nil : (changedOverview, patches)
    }

    func autosave() async {
        guard !running, let core = model.core, let change = pending() else { return }
        saveState = .saving
        do {
            try await core.pipeline.saveContent(data.dir, overview: change.overview, screens: change.patches)
            if let saved = change.overview { baseOverview = saved }
            for patch in change.patches {
                let id = patch["id"]?.jsString ?? ""
                baseTitles[id] = patch["title"]?.jsString
                baseTexts[id] = patch["text"]?.jsString
            }
            saveState = .saved(Date())
            onChanged()
        } catch {
            saveState = .failed(messageOf(error))
        }
    }

    /// 离开时同步存掉（不等计时）
    func flush() {
        guard !running, let core = model.core, let change = pending() else { return }
        let dir = data.dir
        Task {
            do { try await core.pipeline.saveContent(dir, overview: change.overview, screens: change.patches) }
            catch { model.toast(.error, "文字没有保存：\(messageOf(error))") }
        }
    }
}
