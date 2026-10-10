import StudioCore
import SwiftUI

struct ContentTab: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var overview = ""
    @State private var titles: [String: String] = [:]
    @State private var texts: [String: String] = [:]
    @State private var loadedKey = ""
    @State private var saving = false
    @State private var rewrite: (ids: [String], label: String)?

    var floor: Int { model.settings.pipeline.featureTextFloor }
    var contentScreens: [JSON] { data.content?["screens"].items ?? [] }

    /// 只有文案真的变了才重置输入框，避免后台刷新冲掉还没保存的修改
    var contentKey: String {
        guard let content = data.content else { return "" }
        return JSON.obj(["o": content["cover"]?["overview"] ?? .null, "s": .array(contentScreens.map { .array([$0["id"] ?? .null, $0["title"] ?? .null, $0["text"] ?? .null]) })]).serialized()
    }

    var dirty: Bool {
        guard let content = data.content else { return false }
        if overview != content["cover"]?["overview"].text { return true }
        return contentScreens.contains { screen in
            let id = screen["id"]?.jsString ?? ""
            return titles[id] != screen["title"]?.jsString || texts[id] != screen["text"]?.jsString
        }
    }

    var body: some View {
        let readOnly = data.readOnly
        Group {
            if let content = data.content {
                VStack(alignment: .leading, spacing: 16) {
                    if !readOnly {
                        HStack {
                            Button("保存修改") { save(rebuild: false) }.disabled(!dirty || running || saving)
                            Button("保存并更新交付包") { save(rebuild: true) }.buttonStyle(.borderedProminent).disabled(!dirty || running || saving)
                            if dirty { Text("有未保存的修改").foregroundStyle(.orange) }
                        }
                    }
                    SettingsGroup(title: "封面介绍（也会写进 TXT 的【软件的主要功能】）", trailing: readOnly ? nil : AnyView(Button("重写") { rewrite = (["overview"], "封面介绍") }.disabled(running))) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $overview).font(.body).frame(minHeight: 80).scrollContentBackground(.hidden).disabled(readOnly)
                            Text("\(overview.jsTrimmed.jsLength) 字").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12)
                    }
                    ForEach(Array(contentScreens.enumerated()), id: \.offset) { index, screen in
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
                                    .disabled(readOnly)
                                if edited { TagView(text: "人工改过", tone: .purple) }
                                Spacer()
                                Text("\(length) / \(floor)").monospacedDigit().foregroundStyle(length >= floor ? Color.green : Color.red)
                                if !readOnly { Button("重写") { rewrite = ([id], " \(id) 的说明") }.disabled(running) }
                            }
                            TextEditor(text: Binding(get: { texts[id] ?? "" }, set: { texts[id] = $0 }))
                                .font(.body)
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .disabled(readOnly)
                        }
                        .padding(14)
                        .cardBackground(cornerRadius: 12)
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
        .confirmationDialog(rewrite.map { "让大模型重写\($0.label)？" } ?? "", isPresented: Binding(get: { rewrite != nil }, set: { if !$0 { rewrite = nil } }), titleVisibility: .visible) {
            Button("重写") {
                guard let target = rewrite else { return }
                Task { await model.perform { _ = try await model.core?.pipeline.rewriteContent(data.dir, target.ids) } }
            }
        } message: {
            Text("会覆盖当前内容（包括人工改过的部分）。")
        }
    }

    func syncFromContent() {
        guard data.content != nil, contentKey != loadedKey else { return }
        loadedKey = contentKey
        overview = data.content?["cover"]?["overview"].text ?? ""
        titles = Dictionary(contentScreens.map { ($0["id"]?.jsString ?? "", $0["title"]?.jsString ?? "") }, uniquingKeysWith: { first, _ in first })
        texts = Dictionary(contentScreens.map { ($0["id"]?.jsString ?? "", $0["text"]?.jsString ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func save(rebuild: Bool) {
        let short = contentScreens.compactMap { screen -> String? in
            let id = screen["id"]?.jsString ?? ""
            return (texts[id] ?? "").jsTrimmed.jsLength < floor ? id : nil
        }
        if !short.isEmpty {
            model.toast(.error, "\(short.joined(separator: "、")) 的说明不足 \(floor) 个字符")
            return
        }
        if Rx.test(#"图\s*[0-9]"#, overview) || texts.values.contains(where: { Rx.test(#"图\s*[0-9]"#, $0) }) {
            model.toast(.error, "正文里不能出现「图N」字样，图注会自动生成")
            return
        }
        let originalOverview = data.content?["cover"]?["overview"].text ?? ""
        let patches: [JSON] = contentScreens.compactMap { screen in
            let id = screen["id"]?.jsString ?? ""
            guard titles[id] != screen["title"]?.jsString || texts[id] != screen["text"]?.jsString else { return nil }
            return .obj(["id": .string(id), "title": .string(titles[id] ?? ""), "text": .string(texts[id] ?? "")])
        }
        saving = true
        Task {
            defer { saving = false }
            let ok = await model.perform {
                try await model.core?.pipeline.saveContent(data.dir, overview: overview != originalOverview ? overview : nil, screens: patches)
            }
            guard ok else { return }
            if rebuild {
                model.core?.run(data.dir)
                model.toast(.success, "已保存，正在更新交付包")
            } else {
                model.toast(.success, "已保存。点「保存并更新交付包」或「继续运行」重建交付包。")
            }
            onChanged()
        }
    }
}
