import StudioCore
import SwiftUI

extension LlmVendor {
    static func draft(_ preset: String = "deepseek") -> LlmVendor {
        let info = LLM_PRESETS[preset]!
        return LlmVendor(id: "", name: info.label, preset: preset, baseUrl: info.baseUrl, jsonMode: info.jsonMode)
    }
}

struct LlmView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: LlmVendor?
    @State private var deleting: LlmVendor?

    var body: some View {
        let vendors = model.settings.llm.vendors
        PageScroll {
            SettingsGroup(title: "厂商") {
                if vendors.isEmpty {
                    Text("还没有大模型厂商，点「添加厂商」").foregroundStyle(.secondary).padding(14)
                } else {
                    ForEach(vendors) { vendor in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(vendor.name).fontWeight(.semibold)
                                    TagView(text: LLM_PRESETS[vendor.preset]?.label ?? vendor.preset)
                                    if !(model.vendorKeys[vendor.id] ?? false) { TagView(text: "没有密钥", tone: .red) }
                                }
                                Text(vendor.baseUrl).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Text(vendor.models.isEmpty ? "—" : "已获取 \(vendor.models.count) 个模型").foregroundStyle(.secondary)
                            Button("获取模型", systemImage: "arrow.triangle.2.circlepath") { fetchModels(vendor) }
                            Button { editing = vendor } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("编辑")
                            Button(role: .destructive) { deleting = vendor } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
            SettingsGroup(title: "各步骤使用的模型") {
                ForEach(LLM_STEP_ORDER, id: \.self) { step in
                    AssignmentRow(step: step, info: LLM_STEPS[step]!)
                        .id("\(step)#\(model.settingsRevision)")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .draft() } label: { Label("添加厂商", systemImage: "plus") }
                    .buttonStyle(.glassProminent)
                    .help("添加厂商")
            }
        }
        .sheet(item: $editing) { vendor in
            VendorEditor(vendor: vendor, hasKey: model.vendorKeys[vendor.id] ?? false) {
                editing = nil
                Task { await model.reloadSettings() }
            }
        }
        .confirmationDialog(deleting.map { "删除「\($0.name)」？" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let vendor = deleting else { return }
                Task {
                    await model.perform { try await model.core?.deleteVendor(vendor.id) }
                    await model.reloadSettings()
                }
            }
        } message: {
            Text("用到它的步骤会被清空。")
        }
    }

    func fetchModels(_ vendor: LlmVendor) {
        Task {
            do {
                let models = try await model.core?.fetchVendorModels(vendor.id) ?? []
                model.toast(.success, "获取到 \(models.count) 个模型")
                await model.reloadSettings()
            } catch {
                model.toast(.error, "获取失败：\(messageOf(error))（可以直接手动填写模型名）")
            }
        }
    }
}

struct AssignmentRow: View {
    let step: String
    let info: LlmStepInfo
    @Environment(AppModel.self) private var model
    @State private var vendorId = ""
    @State private var modelName = ""
    @State private var testing = false

    var vendor: LlmVendor? { model.settings.llm.vendors.first { $0.id == vendorId } }
    var suggestions: [String] {
        guard let vendor else { return [] }
        return uniqued(vendor.models + (LLM_PRESETS[vendor.preset]?.suggestedModels ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.label).fontWeight(.semibold)
                    if info.needsVision { Text("需要看图模型").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(width: 170, alignment: .leading)
                Picker("", selection: $vendorId) {
                    Text("不使用").tag("")
                    ForEach(model.settings.llm.vendors) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 200)
                HStack(spacing: 4) {
                    TextField("模型名", text: $modelName).textFieldStyle(.roundedBorder)
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.self) { item in Button(item) { modelName = item } }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                .frame(width: 260)
                Spacer()
                Button("保存") { save() }.buttonStyle(.borderedProminent)
                Button {
                    test()
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("测试") }
                }
                .disabled(vendorId.isEmpty || modelName.isEmpty || testing)
            }
            if info.needsVision, vendor?.preset == "deepseek" {
                Banner(.warning, "DeepSeek 目前没有看图模型，这一步建议改用 OpenAI 或智谱的看图模型")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            let current = model.settings.llm.assignment(step)
            vendorId = current?.vendorId ?? ""
            modelName = current?.model ?? ""
        }
    }

    func save() {
        if !vendorId.isEmpty, modelName.jsTrimmed.isEmpty {
            model.toast(.warning, "请填写模型名（可以先点厂商的「获取模型」再从下拉里选）")
            return
        }
        let value = vendorId.isEmpty || modelName.jsTrimmed.isEmpty ? nil : LlmAssignment(vendorId: vendorId, model: modelName.jsTrimmed)
        Task {
            await model.perform(value == nil ? "「\(info.label)」已清空，不使用大模型" : "「\(info.label)」已保存") {
                try await model.core?.setAssignment(step, value)
            }
            await model.reloadSettings()
        }
    }

    func test() {
        testing = true
        Task {
            defer { testing = false }
            do {
                guard let result = try await model.core?.testVendor(vendorId, model: modelName, vision: info.needsVision) else { return }
                model.toast(.success, "可用（\(Int(result.ms)) 毫秒）：\(result.reply)")
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }
}

struct VendorEditor: View {
    let vendor: LlmVendor
    let hasKey: Bool
    let onSaved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LlmVendor
    @State private var apiKey = ""
    @State private var busy = false

    init(vendor: LlmVendor, hasKey: Bool, onSaved: @escaping () -> Void) {
        self.vendor = vendor
        self.hasKey = hasKey
        self.onSaved = onSaved
        _draft = State(initialValue: vendor)
    }

    var isNew: Bool { vendor.id.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "添加大模型厂商" : "编辑：\(vendor.name)").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("厂商").font(.callout.weight(.medium))
                Picker("", selection: Binding(get: { draft.preset }, set: { key in
                    let preset = LLM_PRESETS[key]!
                    draft.preset = key
                    draft.name = preset.label
                    draft.baseUrl = preset.baseUrl
                    draft.jsonMode = preset.jsonMode
                })) {
                    ForEach(LLM_PRESET_ORDER, id: \.self) { Text(LLM_PRESETS[$0]!.label).tag($0) }
                }
                // 分段按钮每段一样宽，按最长的「OpenAI 兼容（自定义 / CPA）」撑开会超出弹窗，改用下拉
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            labeled("名称") { TextField("", text: $draft.name).textFieldStyle(.roundedBorder) }
            labeled("接口地址") { TextField("https://.../v1", text: $draft.baseUrl).textFieldStyle(.roundedBorder) }
            labeled("密钥", hint: !isNew && hasKey ? "已保存，留空表示不修改" : "加密保存在本机") { SecureField("", text: $apiKey).textFieldStyle(.roundedBorder) }
            Toggle("要求返回 JSON 格式（不支持的模型会自动降级）", isOn: $draft.jsonMode).toggleStyle(.switch)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if draft.name.jsTrimmed.isEmpty { return model.toast(.warning, "请填写名称") }
                    busy = true
                    Task {
                        defer { busy = false }
                        if await model.perform(nil, { _ = try await model.core?.saveVendor(draft, apiKey: apiKey.isEmpty ? nil : apiKey) }) {
                            dismiss()
                            onSaved()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    func labeled<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.callout.weight(.medium))
            content()
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
