import StudioCore
import SwiftUI

struct ProviderEditor: View {
    let provider: ImageProvider
    let hasKey: Bool
    let onSaved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ImageProvider
    @State private var apiKey = ""
    @State private var mappingText = ""
    @State private var busy = false

    init(provider: ImageProvider, hasKey: Bool, onSaved: @escaping () -> Void) {
        self.provider = provider
        self.hasKey = hasKey
        self.onSaved = onSaved
        _draft = State(initialValue: provider)
        let mapping = provider.mapping ?? PROVIDER_PRESETS[provider.preset]?.mapping ?? .emptyObject
        _mappingText = State(initialValue: mapping.serialized(pretty: true))
    }

    var isNew: Bool { provider.id.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "添加生图线路" : "编辑线路：\(provider.name)").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("类型") {
                        Picker("", selection: Binding(get: { draft.preset }, set: { applyPreset($0) })) {
                            ForEach(PROVIDER_PRESET_ORDER, id: \.self) { Text(PROVIDER_PRESETS[$0]!.label).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("名称") { TextField("例如：CPA 2.5", text: $draft.name).textFieldStyle(.roundedBorder) }
                        field("密钥", hint: !isNew && hasKey ? "已保存，留空表示不修改" : "加密保存在本机") {
                            SecureField(!isNew && hasKey ? "••••••••" : "sk-...", text: $apiKey).textFieldStyle(.roundedBorder)
                        }
                    }
                    field("接口地址（通常以 /v1 结尾）") { TextField("https://example.com/v1", text: $draft.baseUrl).textFieldStyle(.roundedBorder) }
                    HStack(alignment: .top, spacing: 12) {
                        field("模型名") { TextField("gpt-image-2.5", text: $draft.model).textFieldStyle(.roundedBorder) }
                        field("画风组", hint: "同组的线路之间可以互相补发；留空等于模型名") { TextField("gpt-image-2.5", text: $draft.modelGroup).textFieldStyle(.roundedBorder) }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("尺寸方式") {
                            Picker("", selection: $draft.sizeMode) {
                                Text("像素").tag("pixel")
                                Text("比例").tag("ratio")
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                        }
                        .frame(width: 160)
                        if draft.sizeMode == "ratio" {
                            field("支持的比例（自动选最接近目标尺寸的）") { TokenEditor(tokens: $draft.ratios) }
                        } else {
                            field("像素尺寸") { TextField("864x1824", text: $draft.pixelSize).textFieldStyle(.roundedBorder) }
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("这条线路的并发数") { NumberField(value: draft.concurrency, range: 1...30) { draft.concurrency = $0 } }
                        field("单张最长等待", hint: "超时后换线路；异步任务转后台继续查") { DecimalField(value: draft.hardTimeoutSec, range: 20...1800, suffix: "秒") { draft.hardTimeoutSec = $0 } }
                        field("默认补发线", hint: "历史不足 5 次时使用") { DecimalField(value: draft.hedgeDefaultSec, range: 5...600, suffix: "秒") { draft.hedgeDefaultSec = $0 } }
                    }
                    if draft.preset == "custom" {
                        Banner(.info, "自定义映射：请求体里的 $model、$prompt、$size、$quality 会被替换；有 polling 字段就按异步任务处理。")
                        field("声明式映射（JSON）") {
                            TextEditor(text: $mappingText).font(.system(.callout, design: .monospaced)).frame(minHeight: 220).padding(4).cardBackground(cornerRadius: 8)
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(22)
        .frame(width: 720, height: draft.preset == "custom" ? 760 : 620)
    }

    func field<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.callout.weight(.medium))
            content()
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func applyPreset(_ key: String) {
        guard let preset = PROVIDER_PRESETS[key] else { return }
        draft.preset = key
        draft.sizeMode = preset.sizeMode
        draft.pixelSize = preset.pixelSize
        draft.ratios = preset.ratios
        draft.concurrency = preset.concurrency
        draft.hardTimeoutSec = preset.hardTimeoutSec
        draft.hedgeDefaultSec = preset.hedgeDefaultSec
        mappingText = preset.mapping.serialized(pretty: true)
    }

    func save() {
        if draft.name.jsTrimmed.isEmpty { return model.toast(.warning, "请填写名称") }
        var next = draft
        if next.preset == "custom" {
            guard let mapping = try? JSON.parse(mappingText), mapping.isObject else { return model.toast(.error, "自定义映射不是有效的 JSON") }
            next.mapping = mapping
        } else {
            next.mapping = nil
        }
        busy = true
        Task {
            defer { busy = false }
            if await model.perform(nil, { _ = try await model.core?.saveProvider(next, apiKey: apiKey.isEmpty ? nil : apiKey) }) {
                dismiss()
                onSaved()
            }
        }
    }
}
