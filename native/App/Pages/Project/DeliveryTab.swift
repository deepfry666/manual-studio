import StudioCore
import SwiftUI

private let FONT_DOC = ["guide": "说明书 PDF", "code": "代码文档 PDF"]

struct DeliveryTab: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var reexportConfirm = false

    var body: some View {
        let readOnly = data.readOnly
        let build = data.lastBuild
        let code = data.codeSource
        let oldCodeDoc = data.bundleFiles.contains { $0.contains("_代码-（JAVA）") }
        AdaptiveColumns(breakpoint: 900, trailingWidth: 420) {
            VStack(alignment: .leading, spacing: 16) {
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
                SettingsGroup(title: "代码来源", trailing: AnyView(Button("设置") { model.go(.settings, tab: "code") }.buttonStyle(.borderless))) {
                    SettingsRow(label: "源码", info: code["locked"].isTruthy ? "第一次生成交付包时已记下，以后改设置不影响这个项目。" : "来自设置；第一次生成交付包时记下来。") {
                        PathText(path: code["source"]?["path"]?.string, empty: "没有")
                    }
                    if code["source"].truthyValue == nil, oldCodeDoc, !readOnly, !data.request["allowDropCodeDoc"].isTruthy {
                        SettingsRow(label: "旧代码文档", hint: "重新生成交付包前要选一个") {
                            Button("用设置里的") {
                                Task {
                                    await model.perform { try await model.core?.pipeline.useGlobalCodeSource(data.dir) }
                                    onChanged()
                                }
                            }
                            .disabled(code["global"].truthyValue == nil || running)
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
                SettingsGroup(title: "TXT 字段", footer: "只对这个项目生效，留空用设置里的默认值。") {
                    ForEach(TXT_LABELS, id: \.key) { field in
                        SettingsRow(label: field.label) {
                            CommitTextField(placeholder: model.settings.txtFields[field.key] ?? "", value: data.request["txtFields"]?[field.key]?.string ?? "") { value in
                                saveTxt(field.key, value)
                            }
                            .frame(width: 220)
                            .disabled(readOnly || running)
                        }
                    }
                }
            }
        }
        .confirmationDialog("只重新导出 PDF？", isPresented: $reexportConfirm, titleVisibility: .visible) {
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
            Text("Word、TXT 和截图都不动，旧 PDF 移到项目的 archive 文件夹。")
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
