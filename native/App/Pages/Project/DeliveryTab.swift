import StudioCore
import SwiftUI

private let FONT_DOC = ["guide": "说明书 PDF", "code": "代码文档 PDF"]

struct DeliveryTab: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var reexportConfirm = false
    @State private var switching = false

    var body: some View {
        let readOnly = data.readOnly
        let build = data.lastBuild
        let code = data.codeSource
        let oldCodeDoc = data.bundleFiles.contains { $0.contains("_代码-（JAVA）") }
        AdaptiveColumns(breakpoint: 760, trailingWidth: 360) {
            VStack(alignment: .leading, spacing: 16) {
                if !data.externalEdits.isEmpty, !readOnly {
                    Banner(.info, "这些文件在上次生成后改过：\(data.externalEdits.joined(separator: "、"))", message: "可能是在 WPS 里手改的。之后更新交付包时会先问你；选择覆盖时，手改的文件会另存到项目的 archive 文件夹，不会被清理。")
                }
                SettingsGroup(title: "交付文件", footer: nil, trailing: readOnly ? nil : AnyView(
                    Button("生成 / 更新", systemImage: "hammer") { model.core?.run(data.dir) }.buttonStyle(.glassProminent).disabled(running)
                )) {
                    if data.bundleFiles.isEmpty {
                        Text("还没有交付包").foregroundStyle(.secondary).padding(14)
                    } else {
                        ForEach(data.bundleFiles, id: \.self) { file in
                            SettingsRow(label: file) {
                                Button("打开") { model.open(Path.join(data.bundleDir, file)) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                HStack(spacing: 4) {
                    Text("来源和每次修改都记在").foregroundStyle(.secondary)
                    Button("generation-record.json") { model.open(Path.join(data.dir, RECORD_FILE)) }.buttonStyle(.link)
                }
                .font(.caption)
                if !data.bundleFiles.isEmpty {
                    HStack {
                        Button("打开文件夹", systemImage: "folder") { model.open(data.bundleDir) }
                        Button("打包 zip", systemImage: "doc.zipper") {
                            Task {
                                do {
                                    if let target = try model.core?.zipBundle(data.dir) { model.reveal(target) }
                                } catch {
                                    model.toast(.error, messageOf(error))
                                }
                            }
                        }
                        Button("重新导出 PDF", systemImage: "doc.richtext") { reexportConfirm = true }.disabled(running)
                    }
                    .buttonStyle(.glass)
                }
                if let build {
                    SettingsGroup(title: "上次生成") {
                        SettingsRow(label: "时间") { Text(formatTime(build["at"]?.string)) }
                        SettingsRow(label: "PDF") {
                            if build["withPdf"].isTruthy {
                                Text("说明书 \(build["pdfPages"]?.int.map(String.init) ?? "?") 页")
                                if let pages = build["codePdfPages"]?.int { Text("代码 \(pages) 页") }
                            } else {
                                StatusDot(kind: .warn, text: "未生成（没有 LibreOffice）")
                            }
                        }
                        ForEach(build["pdfFonts"].fields.keys, id: \.self) { kind in
                            let font = build["pdfFonts"]?[kind] ?? .emptyObject
                            SettingsRow(label: "\(FONT_DOC[kind] ?? kind)字体", info: font["fonts"].items.map(\.jsString).joined(separator: "、")) {
                                if font["ignored"].isTruthy {
                                    StatusDot(kind: .warn, text: "\(font["intended"].text)（字体提示已忽略）")
                                } else if font["ok"].isTruthy {
                                    StatusDot(kind: .ok, text: "\(font["intended"].text)\(font["mode"]?.string == "substitute" ? "（替代）" : "")")
                                } else {
                                    StatusDot(kind: .error, text: "字体不对")
                                    if !readOnly {
                                        Button("忽略") {
                                            Task {
                                                await model.perform { try await model.core?.pipeline.ignorePdfFontWarning(data.dir) }
                                                await model.reloadProjects()
                                                onChanged()
                                            }
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(running)
                                        .help("看过 PDF 觉得可以接受，就不再提示")
                                    }
                                }
                            }
                        }
                        SettingsRow(label: "代码文档") {
                            if build["withCode"].isTruthy, let codeInfo = build["code"].truthyValue {
                                Text("\(codeInfo["fileCount"]?.int ?? 0) 个文件，\((codeInfo["lineCount"]?.int ?? 0).formatted()) 行")
                            } else {
                                Text("没有")
                            }
                        }
                        if !build["warnings"].items.isEmpty {
                            SettingsRow(label: "提醒", hint: build["warnings"].items.map(\.jsString).joined(separator: "；"))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 16) {
                SettingsGroup(title: "代码模板", footer: "每个模板都是正好 60 页、每页 50 行，页眉换成软件名。已有交付包时换模板只重做代码 Word、PDF 和 TXT 开头，不调用 AI，旧文件先归档。", trailing: AnyView(Button("模板库") { model.go(.settings, tab: "code") }.buttonStyle(.borderless))) {
                    let enabled = model.settings.codeTemplates.enabled
                    SettingsRow(label: "用的模板", info: code["source"].truthyValue == nil ? nil : (code["locked"].isTruthy ? "已记在这个项目上，改设置不影响它。" : "还没记下，第一次生成交付包时按设置分配。")) {
                        if let label = code["templateLabel"]?.string {
                            Text(label)
                        } else if let path = code["source"]?["path"]?.string {
                            PathText(path: path)
                        } else {
                            Text("没有（只出说明书）").foregroundStyle(.secondary)
                        }
                        // 只有交付包的历史项目也能换（只重做代码材料）；已提交的不能
                        if !data.submitted, !enabled.isEmpty {
                            Menu("更换…") {
                                ForEach(enabled) { entry in
                                    Button(entry.label) { useTemplate(entry) }.disabled(entry.id == code["templateId"]?.string)
                                }
                            }
                            .fixedSize()
                            .disabled(running || switching)
                        }
                    }
                    if code["source"].truthyValue == nil, oldCodeDoc, !readOnly, !data.request["allowDropCodeDoc"].isTruthy {
                        SettingsRow(label: "旧代码文档", hint: "重新生成交付包前要选一个：在上面「更换…」里选模板，或者不要代码文档") {
                            Button("不要代码文档") {
                                Task {
                                    await model.perform { try await model.core?.pipeline.updateRequest(data.dir, ["allowDropCodeDoc": true]) }
                                    onChanged()
                                }
                            }
                            .disabled(running)
                        }
                    }
                }
                SettingsGroup(title: "TXT 字段", footer: "只对这个项目生效，留空用设置里的默认值（「设置 → TXT」）。") {
                    ForEach(TXT_LABELS, id: \.key) { field in
                        SettingsRow(label: field.label) {
                            CommitTextField(placeholder: model.settings.txtFields[field.key] ?? "", value: data.request["txtFields"]?[field.key]?.string ?? "") { value in
                                saveTxt(field.key, value)
                            }
                            .frame(minWidth: 160, idealWidth: 220, maxWidth: 220)
                            .disabled(readOnly || running)
                        }
                    }
                }
            }
        }
        .confirmationDialog("重新导出 PDF 并检查排版？", isPresented: $reexportConfirm, titleVisibility: .visible) {
            Button("重新导出") {
                guard let core = model.core else { return }
                model.toast(.info, "已开始重新导出 PDF")
                Task {
                    let result = await core.reexportPdfs([data.dir])
                    let failed = result["failed"].items.map(\.jsString)
                    if !failed.isEmpty { model.alert = AlertItem(title: "重新导出 PDF 失败", message: failed.joined(separator: "\n")) }
                    else if result["done"]?[0]?["warnings"].items.isEmpty == false { model.toast(.warning, "转出来的字体仍然不对，可以在「设置 → PDF 与字体」里换一个替代字体再试") }
                    else { model.toast(.success, "已重新导出 PDF") }
                    onChanged()
                }
            }
        } message: {
            Text("导出时检查截图栏宽，旧指南存在遮挡时用已有截图和正文重排指南 Word。TXT、代码 Word 和截图不变，不调用 AI；旧文件先归档。")
        }
    }

    func useTemplate(_ entry: CodeTemplateEntry) {
        guard let core = model.core else { return }
        switching = true
        Task {
            defer { switching = false }
            do {
                let result = try await core.useCodeTemplate(data.dir, entry.id)
                model.toast(.success, result["applied"].isTruthy ? "已换成\(entry.label)，代码 Word、PDF 已重做（60 页 × 每页 50 行）" : "已换成\(entry.label)，生成交付包时使用")
            } catch {
                model.toast(.error, messageOf(error))
            }
            onChanged()
        }
    }

    func saveTxt(_ key: String, _ value: String) {
        var next = data.request["txtFields"].fields
        next[key] = .string(value)
        var cleaned = JSONObject()
        for (name, item) in next where !(item.string ?? "").jsTrimmed.isEmpty { cleaned[name] = item }
        let current = data.request["txtFields"].truthyValue ?? .emptyObject
        if JSON.object(cleaned).serialized() == current.serialized() { return }
        Task {
            await model.perform { try await model.core?.pipeline.updateRequest(data.dir, ["txtFields": cleaned.isEmpty ? .null : .object(cleaned)]) }
            onChanged()
        }
    }
}
