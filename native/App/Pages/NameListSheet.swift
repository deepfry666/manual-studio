import StudioCore
import SwiftUI

/// 按名单选择：粘一份软件名清单，一次找出这些项目，每个选一种处理，再统一执行。
/// 每行一个软件名，后面可以用逗号带上动作（代码 / 文字 / 重做 / 不处理）。
struct NameListSheet: View {
    enum Action: String, CaseIterable, Identifiable {
        case code, rewrite, redo, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .code: "只更新代码材料"
            case .rewrite: "只重写文字"
            case .redo: "全部重做"
            case .none: "不处理"
            }
        }
        var hint: String {
            switch self {
            case .code: "重排代码 Word、PDF 和 TXT 开头，不调用 AI，不花钱；没有 Word 模板的自动平均分一个"
            case .rewrite: "截图不动，说明和封面介绍按现在的规则重写，只花写文字的钱"
            case .redo: "重新规划、出图、写文字、出交付包，花费和新建一个项目差不多"
            case .none: "这次不动它"
            }
        }
        /// 名单里写在名字后面的动作
        init?(word: String) {
            let text = word.jsTrimmed.lowercased()
            if text.isEmpty { return nil }
            if ["代码", "更新代码", "只更新代码", "code"].contains(where: text.contains) { self = .code }
            else if ["文字", "重写", "rewrite", "text"].contains(where: text.contains) { self = .rewrite }
            else if ["重做", "全部", "redo"].contains(where: text.contains) { self = .redo }
            else if ["不处理", "跳过", "none"].contains(where: text.contains) { self = .none }
            else { return nil }
        }
    }

    struct Line: Identifiable {
        let id = UUID()
        let input: String
        /// 找到的项目（多个时让用户选）
        let candidates: [ProjectRow]
        var chosen: String?
        var action: Action
        var row: ProjectRow? { candidates.first { $0.dir == chosen } }
    }

    @Environment(AppModel.self) private var model
    let run: (_ code: [String], _ rewrite: [String], _ redo: [String], _ all: [String]) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @State private var lines: [Line]?
    @State private var defaultAction: Action = .code
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("按名单选择项目").font(.headline)
            if let lines {
                result(lines)
            } else {
                input
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .onAppear {
            guard let preset = model.devNameListText else { return }
            text = preset
            lines = match()
            model.devNameListText = nil
        }
    }

    // MARK: 第一步：粘名单

    var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("每行一个软件名。名字后面可以用逗号带上要做的事：代码、文字、重做、不处理；不写的话用下面统一选的。")
                .font(.callout).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("示例记账助手V1.0\n示例天气查询V1.0.0,代码\n示例待办清单V1.0.0,重做").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                }
                TextEditor(text: $text).font(.body).scrollContentBackground(.hidden)
            }
            .padding(8)
            .cardBackground(cornerRadius: 10)
            HStack {
                Text("没写动作的：").foregroundStyle(.secondary)
                Picker("", selection: $defaultAction) {
                    ForEach(Action.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("查找") { lines = match() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(text.jsTrimmed.isEmpty)
            }
        }
    }

    /// 按名字找项目：先按完整名字（忽略空格和大小写），找不到再按包含这几个字找。
    func match() -> [Line] {
        func key(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace } }
        var seen = Set<String>()
        return Rx.split(#"\r?\n"#, text).compactMap { raw -> Line? in
            let parts = Rx.split("[,，\\t]", raw.jsTrimmed)
            let name = (parts.first ?? "").jsTrimmed
            guard !name.isEmpty, seen.insert(key(name)).inserted else { return nil }
            let wanted = key(name)
            let exact = model.projects.filter { key($0.name) == wanted }
            let candidates = exact.isEmpty ? model.projects.filter { key($0.name).contains(wanted) || wanted.contains(key($0.name)) } : exact
            let first = candidates.count == 1 ? candidates[0].dir : nil
            var action = parts.count > 1 ? Action(word: parts[1]) ?? defaultAction : defaultAction
            if candidates.count == 1, candidates[0].submitted { action = .none }
            return Line(input: name, candidates: candidates, chosen: first, action: action)
        }
    }

    // MARK: 第二步：逐行确认

    func result(_ current: [Line]) -> some View {
        let found = current.filter { $0.row != nil }
        let missing = current.filter { $0.candidates.isEmpty }.count
        let ambiguous = current.filter { $0.candidates.count > 1 && $0.chosen == nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("名单 \(current.count) 个：找到 \(found.count) 个\(missing > 0 ? "，没找到 \(missing) 个" : "")\(ambiguous > 0 ? "，\(ambiguous) 个要你选是哪一个" : "")")
                Spacer()
                Text("全部设为").foregroundStyle(.secondary)
                Menu(defaultAction.label) {
                    ForEach(Action.allCases) { action in
                        Button(action.label) {
                            defaultAction = action
                            lines = current.map { line in
                                var next = line
                                if !(line.row?.submitted ?? false) { next.action = action }
                                return next
                            }
                        }
                    }
                }
                .fixedSize()
            }
            List {
                ForEach(current.indices, id: \.self) { index in
                    lineRow(current[index], index)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 300)
            Text(summary(current)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新粘名单") { lines = nil }
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("开始") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(current.allSatisfy { $0.row == nil || $0.action == .none })
            }
        }
        .confirmationDialog("按名单处理这些项目？", isPresented: $confirming, titleVisibility: .visible) {
            Button("开始") { execute(current) }
        } message: {
            Text(summary(current))
        }
    }

    @ViewBuilder
    func lineRow(_ line: Line, _ index: Int) -> some View {
        HStack(spacing: 10) {
            Text(line.input).lineLimit(1).frame(width: 200, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Group {
                if line.candidates.isEmpty {
                    Text("没找到").foregroundStyle(.red)
                } else if line.candidates.count > 1 {
                    Picker("", selection: Binding(get: { line.chosen ?? "" }, set: { value in lines?[index].chosen = value.isEmpty ? nil : value })) {
                        Text("找到 \(line.candidates.count) 个，选一个").tag("")
                        ForEach(line.candidates) { Text($0.name).tag($0.dir) }
                    }
                    .labelsHidden()
                } else if let row = line.row {
                    HStack(spacing: 6) {
                        Text(row.name).lineLimit(1)
                        let status = row.submitted ? (label: "已提交", tone: Tone.purple) : (PROJECT_STATUS[row.status] ?? (row.status, .neutral))
                        TagView(text: status.label, tone: status.tone)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if line.row != nil {
                Picker("", selection: Binding(get: { line.action }, set: { lines?[index].action = $0 })) {
                    ForEach(Action.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(line.row?.submitted ?? false)
                .help(line.row?.submitted == true ? "已提交，只读；要处理先取消已提交" : line.action.hint)
            }
        }
    }

    func groups(_ current: [Line]) -> [Action: [ProjectRow]] {
        var result: [Action: [ProjectRow]] = [:]
        for line in current { if let row = line.row, !row.submitted { result[line.action, default: []].append(row) } }
        return result
    }

    func summary(_ current: [Line]) -> String {
        let grouped = groups(current)
        var parts: [String] = []
        if let rows = grouped[.code], !rows.isEmpty { parts.append("只更新代码材料 \(rows.count) 个：不调用 AI，不花钱") }
        if let rows = grouped[.rewrite], !rows.isEmpty { parts.append("只重写文字 \(rows.count) 个：只调用写文字的大模型，不出图") }
        if let rows = grouped[.redo], !rows.isEmpty {
            let images = rows.reduce(0) { $0 + max($1.json["screens"]?.int ?? 7, 1) }
            parts.append("全部重做 \(rows.count) 个：大约生成 \(images) 张截图，花费和新建 \(rows.count) 个项目差不多")
        }
        let submitted = current.filter { $0.row?.submitted ?? false }.count
        if submitted > 0 { parts.append("已提交的 \(submitted) 个不处理") }
        if parts.isEmpty { return "还没有要处理的项目。" }
        return parts.joined(separator: "；") + "。要调用 AI 的进批量队列，可以暂停、继续。"
    }

    func execute(_ current: [Line]) {
        let grouped = groups(current)
        let all = current.compactMap(\.row?.dir)
        run((grouped[.code] ?? []).map(\.dir), (grouped[.rewrite] ?? []).map(\.dir), (grouped[.redo] ?? []).map(\.dir), all)
    }
}
