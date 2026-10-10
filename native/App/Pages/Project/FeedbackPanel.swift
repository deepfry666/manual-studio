import StudioCore
import SwiftUI

private let ACTION_TYPE: [String: (label: String, tone: Tone)] = [
    "replan": ("重新规划", .red),
    "image": ("重生截图", .blue),
    "text": ("重写说明", .green),
    "overview": ("改封面介绍", .cyan),
    "design": ("改设计说明", .purple),
]

/// 修改意见：只有一个入口。看到问题就记一条进清单，攒够了点「整理意见」，
/// 软件判断要改哪几张图、哪几段文字，确认后一次改完。
struct FeedbackPanel: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var analyzing = false
    @State private var plan: JSON?
    @State private var showDone = false

    var canAnalyze: Bool { data.plan != nil }
    var pending: [JSON] { data.pendingFeedback }
    var done: [JSON] { data.feedback.filter { $0["status"]?.string == "done" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("修改意见").font(.title3.weight(.semibold))
                Text("看到问题就记一条，先不执行；攒够了点下面的按钮，软件判断要改哪几张图、哪几段文字，确认后一次改完。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .bottom) {
                    TextField(canAnalyze ? "例如「图3 按钮改成蓝色」，⌘↩ 加入清单" : "跑出截图后再提修改意见", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(!canAnalyze || data.readOnly)
                        .onSubmit(add)
                    Button("加入清单", action: add)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.jsTrimmed.isEmpty)
                }
                if !pending.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(pending.enumerated()), id: \.element) { index, item in
                            PendingFeedbackRow(dir: data.dir, item: item, index: index, onChanged: onChanged)
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
                        Text("整理意见并统一修改\(pending.isEmpty ? "" : "（\(pending.count) 条）")")
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
            FeedbackPlanSheet(dir: data.dir, plan: plan, pending: pending) {
                self.plan = nil
                onChanged()
            }
        }
    }

    func add() {
        let value = text.jsTrimmed
        guard !value.isEmpty, canAnalyze else { return }
        Task {
            if await model.perform(nil, { _ = try await model.core?.pipeline.addFeedback(data.dir, value) }) {
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

    func save() {
        Task {
            if await model.perform(nil, { try await model.core?.pipeline.editFeedback(dir, item["id"]?.jsString ?? "", value) }) {
                editing = false
                onChanged()
            }
        }
    }
}

/// 整理结果：每一项可以取消勾选、改措辞；确认后一次执行。
struct FeedbackPlanSheet: View {
    let dir: String
    let plan: JSON
    let pending: [JSON]
    let onApplied: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var actions: [JSON] = []
    @State private var checked: [Bool] = []
    @State private var busy = false

    var numbers: [String: (n: Int, text: String)] {
        Dictionary(pending.enumerated().map { ($0.element["id"]?.jsString ?? "", ($0.offset + 1, $0.element["text"]?.jsString ?? "")) }, uniquingKeysWith: { first, _ in first })
    }

    var chosen: [JSON] { actions.enumerated().filter { checked.indices.contains($0.offset) && checked[$0.offset] }.map(\.element) }

    var summary: String {
        let replan = chosen.contains { $0["type"]?.string == "replan" }
        if replan { return "重新规划：所有截图和说明都会重做（规划完会先停下让你确认）" }
        let images = chosen.filter { $0["type"]?.string == "image" }.count
        let texts = chosen.filter { $0["type"]?.string == "text" }.count
        let extras = chosen.filter { ["overview", "design"].contains($0["type"]?.string ?? "") }.compactMap { ACTION_TYPE[$0["type"]?.string ?? ""]?.label }
        return ([images > 0 ? "重生 \(images) 张截图（改过图的屏，说明会按新图重写）" : "", texts > 0 ? "重写 \(texts) 屏说明" : ""] + extras).filter { !$0.isEmpty }.joined(separator: "，")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("整理结果：确认后统一修改").font(.title2.weight(.semibold))
            if let text = plan["summary"]?.string, !text.isEmpty { Text(text) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(actions.indices, id: \.self) { index in
                        let action = actions[index]
                        let type = ACTION_TYPE[action["type"]?.string ?? ""] ?? (action["type"].text, .neutral)
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("", isOn: Binding(get: { checked[index] }, set: { checked[index] = $0 })).toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    TagView(text: type.label, tone: type.tone)
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
                    if actions.isEmpty { Banner(.info, "没有整理出可以直接执行的修改") }
                    let questions = plan["questions"].items
                    if !questions.isEmpty {
                        Banner(.warning, "这些意见需要你说得更具体（会留在清单里，改好后再整理）", message: questions.map { question in
                            let sources = question["items"].items.compactMap { numbers[$0.jsString] }.map { "第\($0.n)条：\($0.text)" }.joined(separator: "；")
                            return "• \(question["question"]?.jsString ?? "")（\(sources)）"
                        }.joined(separator: "\n"))
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
        }
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
