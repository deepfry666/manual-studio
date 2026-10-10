import StudioCore
import SwiftUI

struct PlanTab: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var editing: JSON?
    @State private var replanConfirm = false

    var body: some View {
        let readOnly = data.readOnly
        if let plan = data.plan {
            let waiting = data.stepStatus("plan") == "review"
            VStack(alignment: .leading, spacing: 16) {
                SettingsGroup(title: "规划概要", trailing: AnyView(HStack {
                    if waiting {
                        Button("确认规划，开始生图") {
                            Task { await model.perform { _ = try await model.core?.pipeline.confirmPlan(data.dir) } }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(running)
                    }
                    if !readOnly {
                        Button("重新规划") { replanConfirm = true }.buttonStyle(.glass).disabled(running)
                    }
                })) {
                    SettingsRow(label: "领域") { Text(plan["profile"]?["domain"].text.ifEmpty("—") ?? "—").textSelection(.enabled) }
                    SettingsRow(label: "目标用户") { Text(plan["profile"]?["targetUser"].text.ifEmpty("—") ?? "—").textSelection(.enabled) }
                    SettingsRow(label: "核心流程") { Text(plan["profile"]?["coreFlow"].text.ifEmpty("—") ?? "—").textSelection(.enabled) }
                    SettingsRow(label: "屏数理由") { Text(plan["featureMap"]?["coverageReason"].text.ifEmpty("—") ?? "—").multilineTextAlignment(.trailing).textSelection(.enabled) }
                }
                if data.origin == "imported" {
                    Text("历史项目：编辑某一屏会按新格式重写它的提示词并重新生图。").font(.callout).foregroundStyle(.secondary)
                }
                SettingsGroup(title: "界面（\(plan["screens"].items.count) 屏）") {
                    ForEach(plan["screens"].items, id: \.self) { screen in
                        HStack(alignment: .top, spacing: 14) {
                            Text(screen["id"]?.jsString ?? "").font(.callout.monospaced()).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                            Text(screen["title"]?.jsString ?? "").fontWeight(.semibold).frame(width: 140, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                FlowLayout { ForEach(screen["mustShow"].items.map(\.jsString), id: \.self) { TagView(text: $0) } }
                                Text(screen["sampleData"].items.map(\.jsString).joined(separator: "；")).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("编辑") { editing = screen }
                                .disabled(running || readOnly)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
            .sheet(item: $editing) { screen in
                PlanScreenSheet(screen: screen) { patch in
                    Task {
                        let ok = await model.perform("已保存。这一屏的提示词会更新，下次运行时重新生成这张截图。") {
                            try await model.core?.pipeline.savePlanScreen(data.dir, screen["id"]?.jsString ?? "", patch)
                        }
                        if ok { editing = nil }
                        onChanged()
                    }
                }
            }
            .confirmationDialog("重新规划？", isPresented: $replanConfirm, titleVisibility: .visible) {
                Button("重新规划") { model.core?.run(data.dir, RunOptions(from: "plan", force: ["plan"], reviewPlan: true)) }
            } message: {
                Text("会让大模型重新设计全部界面，之后所有截图都要重新生成，文案也会重写（人工改过的除外）。")
            }
        } else {
            VStack(spacing: 14) {
                EmptyHint(title: "还没有界面规划", systemImage: "rectangle.3.group")
                if !readOnly {
                    Button("开始规划") { model.core?.run(data.dir, RunOptions(until: "plan", reviewPlan: true)) }
                        .buttonStyle(.glassProminent)
                        .disabled(running)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }
}

struct PlanScreenSheet: View {
    let screen: JSON
    let onSave: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var mustShow: [String] = []
    @State private var sampleData: [String] = []
    @State private var activeTab = ""
    @State private var visualBrief = ""
    @State private var contract: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑 \(screen["id"]?.jsString ?? "")").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("界面标题（也是图注）") { TextField("", text: $title).textFieldStyle(.roundedBorder).onChange(of: title) { _, next in if next.count > 20 { title = String(next.prefix(20)) } } }
                    field("应包含的内容") { TokenEditor(tokens: $mustShow) }
                    field("示例数据（截图里的具体数值）") { TokenEditor(tokens: $sampleData) }
                    field("底部导航选中项（留空表示隐藏底部导航）") { TextField("", text: $activeTab).textFieldStyle(.roundedBorder) }
                    field("画面描述（英文，给生图模型看）") {
                        TextEditor(text: $visualBrief).font(.body).frame(minHeight: 110).padding(4).cardBackground(cornerRadius: 8)
                    }
                    HStack(spacing: 10) {
                        contractField("entry", "入口")
                        contractField("action", "操作")
                    }
                    HStack(spacing: 10) {
                        contractField("feedback", "反馈")
                        contractField("exception", "异常")
                        contractField("exit", "去向")
                    }
                }
                .padding(.trailing, 6)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    var textContract = screen["textContract"].or(.emptyObject)
                    for (key, value) in contract { textContract[key] = .string(value) }
                    onSave(.obj([
                        "title": .string(title), "mustShow": JSON(mustShow), "sampleData": JSON(sampleData),
                        "activeTab": activeTab.isEmpty ? .null : .string(activeTab), "visualBrief": .string(visualBrief), "textContract": textContract,
                    ]))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.jsTrimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 720, height: 640)
        .onAppear {
            title = screen["title"]?.jsString ?? ""
            mustShow = screen["mustShow"].items.map(\.jsString)
            sampleData = screen["sampleData"].items.map(\.jsString)
            activeTab = screen["activeTab"]?.string ?? ""
            visualBrief = screen["visualBrief"]?.jsString ?? ""
            for key in ["entry", "action", "feedback", "exception", "exit"] { contract[key] = screen["textContract"]?[key]?.jsString ?? "" }
        }
    }

    func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            content()
        }
    }

    func contractField(_ key: String, _ label: String) -> some View {
        field(label) {
            TextField("", text: Binding(get: { contract[key] ?? "" }, set: { contract[key] = $0 })).textFieldStyle(.roundedBorder)
        }
    }
}
