import StudioCore
import SwiftUI

/// 导出交付包：每个项目一个文件夹（名字是项目名），多选时放进同一个总文件夹。只复制，不改动原项目。
struct ExportSheet: View {
    let dirs: [String]
    var onDone: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var items: [JSON]?
    @State private var conflict: String?
    @State private var busy = false
    @State private var groupName = ""
    @State private var resolvedRoot = ""

    var multiple: Bool { dirs.count > 1 }
    var ready: [JSON] { (items ?? []).filter { $0["ok"].isTruthy } }
    var conflicts: [JSON] { ready.filter { $0["conflict"].isTruthy } }
    var skippedUp: [JSON] { (items ?? []).filter { !$0["ok"].isTruthy } }
    var exportCount: Int { conflict == "skip" ? ready.count - conflicts.count : ready.count }
    var canExport: Bool {
        !target.isEmpty && !ready.isEmpty && !(multiple && groupName.jsTrimmed.isEmpty) && !(conflicts.count > 0 && conflict == nil) && !(conflict == "skip" && ready.count == conflicts.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出交付包（\(dirs.count) 个项目）").font(.title2.weight(.semibold))
            Text("每个项目一个文件夹（名字是项目名）\(multiple ? "，多选时都放进同一个总文件夹" : "")。只复制，不改动原项目。").foregroundStyle(.secondary)
            HStack {
                TextField("选择导出到哪里", text: .constant(target)).textFieldStyle(.roundedBorder).disabled(true)
                Button("选择…") {
                    if let dir = Panels.chooseDirectory("选择导出位置", at: target) {
                        target = dir
                        inspect(dir)
                    }
                }
            }
            if multiple {
                VStack(alignment: .leading, spacing: 6) {
                    Text("总文件夹名")
                    TextField("", text: $groupName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if !target.isEmpty { inspect(target) } }
                    if !resolvedRoot.isEmpty {
                        Text("将导出到：\(resolvedRoot)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            if !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("导出位置已经有 \(conflicts.count) 个同名文件夹：\(conflicts.prefix(5).map { $0["name"]?.jsString ?? "" }.joined(separator: "、"))\(conflicts.count > 5 ? " 等" : "")")
                        .fontWeight(.semibold)
                    Picker("", selection: Binding(get: { conflict ?? "" }, set: { conflict = $0.isEmpty ? nil : $0 })) {
                        Text("跳过这些项目，已有的文件夹不动").tag("skip")
                        Text("覆盖：已有的文件夹先移到废纸篓，再导出新的").tag("overwrite")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if let items {
                Table(items) {
                    TableColumn("项目") { item in Text(item["name"]?.jsString ?? "") }
                    TableColumn("文件") { item in Text(item["ok"].isTruthy ? "\(item["files"].items.count)" : "—") }.width(50)
                    TableColumn("") { item in
                        if !item["ok"].isTruthy {
                            TagView(text: "跳过：\(item["reason"]?.jsString ?? "")")
                        } else {
                            HStack(spacing: 4) {
                                if item["conflict"].isTruthy { TagView(text: "已有同名文件夹", tone: .orange) } else { TagView(text: "可导出", tone: .green) }
                                ForEach(item["warnings"].items.map(\.jsString), id: \.self) { warning in
                                    TagView(text: warning.count > 14 ? "\(warning.prefix(14))…" : warning, tone: .gold).help(warning)
                                }
                            }
                        }
                    }
                    .width(min: 260)
                }
                .frame(minHeight: 180, maxHeight: 300)
                if !skippedUp.isEmpty {
                    Text("\(skippedUp.count) 个项目不会导出（见上表）。").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    run()
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(ready.isEmpty ? "导出" : "导出 \(exportCount) 个") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport || busy)
            }
        }
        .padding(22)
        .frame(width: 720)
        .task {
            target = model.settings.export.lastDir
            if multiple { groupName = model.core?.defaultExportGroupName() ?? "" }
            if !target.isEmpty { inspect(target) }
        }
    }

    func inspect(_ dir: String) {
        guard let core = model.core, !dir.isEmpty else { return }
        do {
            let plan = try core.planExport(dirs, targetDir: dir, groupName: multiple ? groupName : "")
            items = plan["items"].items
            resolvedRoot = plan["targetDir"]?.string ?? ""
            conflict = nil
        } catch {
            model.toast(.error, messageOf(error))
        }
    }

    func run() {
        guard let core = model.core else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await core.exportBundles(dirs, targetDir: target, conflict: conflict ?? "skip", groupName: multiple ? groupName : "")
                await model.reloadSettings()
                onDone()
                dismiss()
                let skipped = result["skipped"].items.map { "\($0["name"]?.jsString ?? "")：\($0["reason"]?.jsString ?? "")" }
                let root = result["targetDir"]?.string ?? target
                model.alert = AlertItem(
                    title: "已导出 \(result["exported"].items.count) 个项目",
                    message: ([root] + (skipped.isEmpty ? [] : ["跳过 \(skipped.count) 个："] + skipped)).joined(separator: "\n"),
                    actionTitle: "在访达中打开",
                    action: { model.open(root) }
                )
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }
}

extension JSON: @retroactive Identifiable {
    public var id: String { self["dir"]?.string ?? self["id"]?.string ?? self["jobId"]?.string ?? self["ts"]?.string.map { "\($0)#\(hashValue)" } ?? "\(hashValue)" }
}
