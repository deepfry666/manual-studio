import StudioCore
import SwiftUI

private let ACTION_TYPE: [String: (label: String, tone: Tone)] = [
    "replan": ("重新规划", .red),
    "image": ("重新生成截图", .blue),
    "text": ("重写说明", .green),
    "overview": ("改封面介绍", .cyan),
    "design": ("改设计说明", .purple),
]

/// 修改意见可以指定的位置；value 为空表示让软件判断。
struct FeedbackTarget: Hashable {
    let value: String
    let label: String

    static func options(_ data: ProjectData) -> [FeedbackTarget] {
        var options = [FeedbackTarget(value: "", label: "让软件判断")]
        options += data.screens.enumerated().map { FeedbackTarget(value: $0.element.id, label: "图\($0.offset + 1)「\($0.element.title)」") }
        options.append(FeedbackTarget(value: "all", label: "全部截图"))
        options.append(FeedbackTarget(value: "overview", label: "封面介绍"))
        if data.request["wantDesign"].isTruthy { options.append(FeedbackTarget(value: "design", label: "设计说明")) }
        return options
    }

    static func label(_ value: String?, in options: [FeedbackTarget]) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return options.first { $0.value == value }?.label ?? value
    }
}

/// 修改意见：只有一个入口。看到问题就记一条进清单，攒够了点「整理意见」，
/// 软件判断要改哪几张图、哪几段文字，确认后一次改完。
/// 知道要改哪里时直接选位置，就不用软件去猜。
struct FeedbackPanel: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var target = ""
    @State private var analyzing = false
    @State private var plan: JSON?
    @State private var showDone = false

    var canAnalyze: Bool { data.plan != nil }
    var pending: [JSON] { data.pendingFeedback }
    var done: [JSON] { data.feedback.filter { $0["status"]?.string == "done" } }

    var body: some View {
        let options = FeedbackTarget.options(data)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("批量修改意见").font(.title3.weight(.semibold))
                Text("一次要改很多处、或者说不清改哪一屏时用这里：看到问题就记一条，攒够了点下面的按钮，确认后一次改完。只改某一屏的图或文字，直接在编辑页那一屏点「改图」「只改文字」更快。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("改哪里").foregroundStyle(.secondary)
                    Picker("", selection: $target) {
                        ForEach(options, id: \.self) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    Spacer()
                }
                .disabled(!canAnalyze || data.readOnly)
                HStack(alignment: .bottom) {
                    TextField(canAnalyze ? "例如「按钮改成蓝色」「日期都改成今天」" : "跑出截图后再提修改意见", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(!canAnalyze || data.readOnly)
                        .onSubmit(add)
                    Button("加入清单", action: add)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("快捷键 ⌘↩")
                        .disabled(text.jsTrimmed.isEmpty)
                }
                if !pending.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(pending.enumerated()), id: \.element) { index, item in
                            PendingFeedbackRow(dir: data.dir, item: item, index: index, options: options, onChanged: onChanged)
                            if index < pending.count - 1 { Divider() }
                        }
                    }
                    .cardBackground(cornerRadius: 12)
                }
                if !done.isEmpty {
                    DisclosureGroup(isExpanded: $showDone) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(done.reversed(), id: \.self) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item["text"]?.jsString ?? "")
                                    Text("\(formatTime(item["doneAt"]?.string)) 已改：\(item["appliedAs"]?.jsString ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("已处理 \(done.count) 条").foregroundStyle(.secondary)
                    }
                }
                Button {
                    analyze()
                } label: {
                    HStack {
                        if analyzing { ProgressView().controlSize(.small) }
                        Text(analyzing ? "正在整理…" : "整理意见并统一修改\(pending.isEmpty ? "" : "（\(pending.count) 条）")")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(pending.isEmpty || running || !canAnalyze || analyzing)
                .padding(.top, 6)
            }
            .padding(18)
        }
        .sheet(item: $plan) { plan in
            FeedbackPlanSheet(dir: data.dir, plan: plan, pending: pending, options: options, screenCount: data.screens.count) {
                self.plan = nil
                onChanged()
            }
        }
    }

    func add() {
        let value = text.jsTrimmed
        guard !value.isEmpty, canAnalyze else { return }
        let chosen = target
        Task {
            if await model.perform(nil, { _ = try await model.core?.pipeline.addFeedback(data.dir, value, target: chosen.isEmpty ? nil : chosen) }) {
                text = ""
                onChanged()
            }
        }
    }

    func analyze() {
        analyzing = true
        Task {
            defer { analyzing = false }
            do {
                plan = try await model.core?.pipeline.analyzeFeedback(data.dir)
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }
}

struct PendingFeedbackRow: View {
    let dir: String
    let item: JSON
    let index: Int
    let options: [FeedbackTarget]
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var value = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if editing {
                TextField("", text: $value).textFieldStyle(.roundedBorder).onSubmit(save)
                Button("保存", action: save)
            } else {
                Text("\(index + 1).").foregroundStyle(.secondary)
                Text(item["text"]?.jsString ?? "").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option.label) { setTarget(option.value) }
                    }
                } label: {
                    TagView(text: FeedbackTarget.label(item["target"]?.string, in: options) ?? "让软件判断", tone: item["target"]?.string == nil ? .neutral : .blue)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("改哪里")
                Button { value = item["text"]?.jsString ?? ""; editing = true } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("编辑")
                Button(role: .destructive) {
                    Task {
                        await model.perform { try await model.core?.pipeline.removeFeedback(dir, item["id"]?.jsString ?? "") }
                        onChanged()
                    }
                } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除")
            }
        }
        .padding(10)
    }

    func setTarget(_ target: String) {
        Task {
            await model.perform { try await model.core?.pipeline.setFeedbackTarget(dir, item["id"]?.jsString ?? "", target.isEmpty ? nil : target) }
            onChanged()
        }
    }

    func save() {
        Task {
            if await model.perform(nil, { try await model.core?.pipeline.editFeedback(dir, item["id"]?.jsString ?? "", value) }) {
                editing = false
                onChanged()
            }
        }
    }
}

/// 整理结果：每一项可以取消勾选、改措辞、在「改图 / 只改文字」之间切换；
/// 软件没判断出位置的意见在这里选位置后加入。确认后一次执行。
struct FeedbackPlanSheet: View {
    let dir: String
    let plan: JSON
    let pending: [JSON]
    let options: [FeedbackTarget]
    let screenCount: Int
    let onApplied: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var actions: [JSON] = []
    @State private var checked: [Bool] = []
    @State private var questions: [JSON] = []
    @State private var questionTargets: [String] = []
    @State private var busy = false

    var numbers: [String: (n: Int, text: String)] {
        Dictionary(pending.enumerated().map { ($0.element["id"]?.jsString ?? "", ($0.offset + 1, $0.element["text"]?.jsString ?? "")) }, uniquingKeysWith: { first, _ in first })
    }

    var chosen: [JSON] { actions.enumerated().filter { checked.indices.contains($0.offset) && checked[$0.offset] }.map(\.element) }

    var summary: String {
        let replan = chosen.contains { $0["type"]?.string == "replan" }
        if replan { return "重新规划：所有截图和说明都会重做（规划完会先停下让你确认）" }
        let images = chosen.filter { $0["type"]?.string == "image" }.reduce(0) { $0 + ($1["target"]?.string == "all" ? screenCount : 1) }
        let texts = chosen.filter { $0["type"]?.string == "text" }.count
        let extras = chosen.filter { ["overview", "design"].contains($0["type"]?.string ?? "") }.compactMap { ACTION_TYPE[$0["type"]?.string ?? ""]?.label }
        return ([images > 0 ? "重新生成 \(images) 张截图（改过图的屏，说明会按新图重写；检查时会核对修改是否改到）" : "", texts > 0 ? "重写 \(texts) 屏说明" : ""] + extras).filter { !$0.isEmpty }.joined(separator: "，")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("整理结果：确认后统一修改").font(.title2.weight(.semibold))
            if let notice = plan["notice"]?.string, !notice.isEmpty { Banner(.warning, notice) }
            if let text = plan["summary"]?.string, !text.isEmpty { Text(text) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(actions.indices, id: \.self) { index in
                        actionRow(index)
                    }
                    if actions.isEmpty && questions.isEmpty { Banner(.info, "没有整理出可以直接执行的修改") }
                    ForEach(questions.indices, id: \.self) { index in
                        questionRow(index)
                    }
                    if !chosen.isEmpty {
                        Banner(.info, "将会：\(summary)。所有修改一次跑完，最后只生成一次交付包。")
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认，统一修改") { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || busy)
            }
        }
        .padding(22)
        .frame(width: 780, height: 620)
        .onAppear {
            actions = plan["actions"].items
            checked = Array(repeating: true, count: actions.count)
            questions = plan["questions"].items
            questionTargets = Array(repeating: "", count: questions.count)
        }
    }

    @ViewBuilder
    func actionRow(_ index: Int) -> some View {
        let action = actions[index]
        let typeValue = action["type"]?.string ?? ""
        let type = ACTION_TYPE[typeValue] ?? (action["type"].text, .neutral)
        let onScreen = ["image", "text"].contains(typeValue) && action["target"]?.string != "all"
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { checked[index] }, set: { checked[index] = $0 })).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if onScreen {
                        Picker("", selection: Binding(get: { actions[index]["type"]?.string ?? "image" }, set: { actions[index]["type"] = .string($0) })) {
                            Text("改图").tag("image")
                            Text("只改文字").tag("text")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        TagView(text: type.label, tone: type.tone)
                    }
                    Text(action["targetLabel"]?.jsString ?? "").fontWeight(.semibold)
                    let sources = action["items"].items.compactMap { numbers[$0.jsString]?.n }.map { "第\($0)条" }
                    Text("来自：\(sources.isEmpty ? "—" : sources.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary)
                }
                TextField("", text: Binding(get: { actions[index]["instruction"]?.jsString ?? "" }, set: { actions[index]["instruction"] = .string($0) }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(!checked[index])
            }
        }
        .padding(12)
        .cardBackground(cornerRadius: 12)
        .opacity(checked[index] ? 1 : 0.5)
    }

    @ViewBuilder
    func questionRow(_ index: Int) -> some View {
        let question = questions[index]
        let sources = question["items"].items.compactMap { numbers[$0.jsString] }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TagView(text: "待指定位置", tone: .orange)
                Text(question["question"]?.jsString ?? "").fontWeight(.semibold)
            }
            ForEach(sources, id: \.n) { source in
                Text("第\(source.n)条：\(source.text)").foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text("改哪里").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { questionTargets[index] }, set: { questionTargets[index] = $0 })) {
                    Text("请选择").tag("")
                    ForEach(options.filter { !$0.value.isEmpty }, id: \.self) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Button("按原话改这里") { resolve(index) }
                    .disabled(questionTargets[index].isEmpty)
                Spacer()
            }
            Text("不处理的话这条会留在清单里。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .cardBackground(cornerRadius: 12)
    }

    /// 把软件没判断出位置的意见按用户选的位置加入修改。
    func resolve(_ index: Int) {
        let target = questionTargets[index]
        let question = questions[index]
        let texts = question["items"].items.compactMap { numbers[$0.jsString]?.text }
        let type = ["overview", "design"].contains(target) ? target : "image"
        let label = target == "all" ? "全部截图" : FeedbackTarget.label(target, in: options) ?? target
        actions.append(.obj(["key": .string("\(type):\(target):\(UUID().uuidString)"), "type": .string(type), "target": .string(target), "targetLabel": .string(label), "instruction": .string(texts.joined(separator: "；")), "items": question["items"] ?? []]))
        checked.append(true)
        questions.remove(at: index)
        questionTargets.remove(at: index)
    }

    func apply() {
        busy = true
        Task {
            defer { busy = false }
            if await model.perform("已开始统一修改，进度在页面上方", { _ = try await model.core?.pipeline.applyFeedback(dir, actions: chosen) }) {
                dismiss()
                onApplied()
            }
        }
    }
}
