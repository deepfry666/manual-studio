import StudioCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置 → 代码模板：模板库。可以一次加多份；加入时就裁成正好 60 页 × 每页 50 行，之后每个项目原样使用、只换页眉。
struct CodeTemplateSettings: View {
    @Environment(AppModel.self) private var model
    @State private var library: JSON?
    @State private var adding = false
    @State private var results: [JSON]?
    @State private var usedBy: (label: String, names: [String])?
    @State private var removing: JSON?
    @State private var dropTargeted = false

    var entries: [JSON] { library?["entries"].items ?? [] }
    var enabled: [JSON] { entries.filter { $0["enabled"].isTruthy } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(
                title: "代码模板（\(entries.count) 个）",
                footer: "加入时就按「前 1500 + 后 1500 行」裁成正好 60 页、每页 50 行（按印出来的行算，折行和空行都算一行），出交付包时只把页眉换成软件名、加页码，代码一字不改。被项目用过的模板不能删，不想再用可以停用。也可以把 Word 文件直接拖到这里。",
                trailing: AnyView(
                    Button(adding ? "正在检查…" : "添加模板…", systemImage: "plus") { choose() }
                        .buttonStyle(.borderless)
                        .disabled(adding)
                )
            ) {
                if entries.isEmpty {
                    SettingsRow(label: library == nil ? "正在读取…" : "还没有模板", hint: "点右上角「添加模板…」，选一份或多份代码 Word（.docx 或 .doc）")
                }
                ForEach(entries, id: \.["id"]) { entry in row(entry) }
            }
            .overlay {
                if dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                Task { await add(await droppedFiles(providers)) }
                return true
            }
            SettingsGroup(title: "新项目怎么分配", footer: "新建项目时按这里分配模板；批量新建时在新建页还能改成全部用某一个。已有项目要换，在交付页或项目列表里换。") {
                SettingsRow(label: "分配方式") {
                    Picker("", selection: Binding(get: { library?["assign"]?.string == "fixed" ? "fixed" : "balance" }, set: { setAssign($0, fixed: library?["fixedId"]?.string ?? enabled.first?["id"]?.string ?? "") })) {
                        Text("轮流平均分").tag("balance")
                        Text("全部用同一个").tag("fixed")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if library?["assign"]?.string == "fixed" {
                    SettingsRow(label: "用哪个模板") {
                        Picker("", selection: Binding(get: { library?["fixedId"]?.string ?? "" }, set: { setAssign("fixed", fixed: $0) })) {
                            ForEach(enabled, id: \.["id"]) { Text($0["label"].text).tag($0["id"]?.string ?? "") }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                } else {
                    SettingsRow(label: "规则", hint: "哪个模板用得少就先分给它，几个模板用的项目数保持差不多")
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: Binding(get: { results != nil }, set: { if !$0 { results = nil } })) {
            AddResultsSheet(results: results ?? []) { results = nil }
        }
        .sheet(isPresented: Binding(get: { usedBy != nil }, set: { if !$0 { usedBy = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("用\(usedBy?.label ?? "")的项目（\(usedBy?.names.count ?? 0) 个）").font(.headline)
                List(usedBy?.names ?? [], id: \.self) { Text($0) }.frame(minWidth: 360, minHeight: 300)
                HStack { Spacer(); Button("好") { usedBy = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
        }
        .confirmationDialog("删除\(removing?["label"].text ?? "")？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let id = removing?["id"]?.string { remove(id) } }
        } message: {
            Text("只删模板库里整理好的这份，你原来的 Word 文件不受影响。")
        }
    }

    func row(_ entry: JSON) -> some View {
        let id = entry["id"]?.string ?? ""
        let usage = entry["usage"]?.int ?? 0
        let sourceRows = entry["sourceRows"]?.int ?? 3000
        let detail = entry["cropped"].isTruthy ? "原来印出来 \(sourceRows) 行，已裁成 60 页" : "正好 60 页"
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { entry["enabled"].isTruthy }, set: { setEnabled(id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(entry["enabled"].isTruthy ? "已启用：新项目会分到它" : "已停用：新项目不会分到它，已用它的项目不受影响")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry["label"].text).font(.body.weight(.medium))
                    if !entry["enabled"].isTruthy { TagView(text: "已停用") }
                }
                Text("\(detail) · 每页 50 行 · \(entry["sourceName"].text)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button(usage == 0 ? "没用过" : "用在 \(usage) 个项目") { showUsage(entry) }
                .buttonStyle(.borderless)
                .disabled(usage == 0)
            Button("打开") { model.open(entry["file"].text) }
                .buttonStyle(.borderless)
                .help("用 WPS（或你默认的 Word 软件）打开整理好的这份，看到的就是交付时的样子")
            Menu {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry["file"].text)]) }
                Divider()
                Button("删除…", role: .destructive) { removing = entry }.disabled(usage > 0)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(usage > 0 ? "用过的模板不能删，可以停用" : "更多")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    func reload() async {
        library = try? await model.core?.codeTemplateLibrary()
        await model.reloadSettings()
    }

    func choose() {
        let files = Panels.chooseFiles("选择代码 Word 模板（可以多选）", extensions: ["docx", "doc"], multiple: true)
        Task { await add(files) }
    }

    func add(_ files: [String]) async {
        let words = files.filter { ["docx", "doc"].contains(Path.extname($0).lowercased().replacingOccurrences(of: ".", with: "")) }
        guard !words.isEmpty, let core = model.core else {
            if !files.isEmpty { model.toast(.warning, "只支持 Word 文件（.docx 或 .doc）") }
            return
        }
        adding = true
        defer { adding = false }
        do { results = try await core.addCodeTemplates(words) } catch { model.toast(.error, messageOf(error)) }
        await reload()
    }

    func droppedFiles(_ providers: [NSItemProvider]) async -> [String] {
        var files: [String] = []
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let path = URL(dataRepresentation: url, relativeTo: nil)?.path {
                files.append(path)
            }
        }
        return files
    }

    func setEnabled(_ id: String, _ value: Bool) {
        Task { _ = await model.perform { try await model.core?.setCodeTemplateEnabled(id, value) }; await reload() }
    }

    func setAssign(_ assign: String, fixed: String) {
        Task { _ = await model.perform { try await model.core?.setCodeTemplateAssignment(assign, fixedId: fixed) }; await reload() }
    }

    func remove(_ id: String) {
        Task { _ = await model.perform("已删除") { try await model.core?.removeCodeTemplate(id) }; await reload() }
    }

    func showUsage(_ entry: JSON) {
        Task {
            let dirs = (try? await model.core?.projectsUsingCodeTemplate(entry["id"]?.string ?? "")) ?? []
            usedBy = (entry["label"].text, dirs.map { Path.basename($0) }.sorted())
        }
    }
}

/// 加模板的结果：每份写明能不能用、裁没裁、不能用的原因。
private struct AddResultsSheet: View {
    let results: [JSON]
    let close: () -> Void

    var body: some View {
        let ok = results.filter { $0["ok"].isTruthy }.count
        VStack(alignment: .leading, spacing: 12) {
            Text(ok == results.count ? "加好了 \(ok) 个模板" : "加好了 \(ok) 个，\(results.count - ok) 个没加").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(results.indices, id: \.self) { index in
                        let item = results[index]
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item["ok"].isTruthy ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item["ok"].isTruthy ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item["file"].text).lineLimit(1).truncationMode(.middle)
                                Text(describe(item)).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 460, minHeight: 160, maxHeight: 360)
            HStack { Spacer(); Button("好", action: close).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
    }

    func describe(_ item: JSON) -> String {
        guard item["ok"].isTruthy else { return item["error"].text }
        let rows = item["sourceRows"]?.int ?? 3000
        let crop = item["cropped"].isTruthy ? "原来印出来 \(rows) 行，已按前 1500 + 后 1500 行裁成 60 页" : "正好 60 页"
        return "\(item["label"].text)：\(crop)，每页 50 行"
    }
}
