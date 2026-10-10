import StudioCore
import SwiftUI

extension Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .purple: .purple
        case .cyan: .cyan
        case .gold: .yellow
        }
    }
}

/// 小标签（状态、来源、提醒）。
struct TagView: View {
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
            .background(tone.color.opacity(tone == .neutral ? 0.12 : 0.14), in: Capsule())
    }
}

/// 状态点 + 文字（系统设置里的样式）。
struct StatusDot: View {
    enum Kind { case ok, warn, error, idle }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    var color: Color {
        switch kind {
        case .ok: .green
        case .warn: .orange
        case .error: .red
        case .idle: .secondary
        }
    }
}

/// ⓘ：长说明收进弹出框，不在界面上铺大段文字。
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(14)
        }
    }
}

/// 带说明的表单标签。
struct RowLabel: View {
    let title: String
    var hint: String? = nil
    var info: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).fixedSize(horizontal: true, vertical: false)
                if let info { InfoButton(text: info) }
            }
            if let hint, !hint.isEmpty {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 路径：家目录写成 ~，太长时中间省略，悬停看完整路径。
struct PathText: View {
    let path: String?
    var empty = "未设置"

    var body: some View {
        if let path, !path.isEmpty {
            Text(shortPath(path))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
        } else {
            Text(empty).foregroundStyle(.secondary)
        }
    }
}

/// 页面顶部的提示条。
struct Banner<Actions: View>: View {
    enum Kind { case info, success, warning, error }
    let kind: Kind
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: () -> Actions

    init(_ kind: Kind, _ title: String, message: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions
    }

    var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                if let message, !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.18)))
    }
}

extension Banner where Actions == EmptyView {
    init(_ kind: Kind, _ title: String, message: String? = nil) {
        self.init(kind, title, message: message) { EmptyView() }
    }
}

/// 分组框（内容层保持实色，和系统设置一样）。
struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title).font(.headline) }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        }
    }
}

/// 数值统计卡片。
struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// 自动换行的横排（标签列表用）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 多个词的输入框（回车添加，点 × 删除）。
struct TokenEditor: View {
    @Binding var tokens: [String]
    var placeholder = "输入后回车"
    var suggestions: [String] = []
    var onCommit: (() -> Void)? = nil
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tokens.isEmpty {
                FlowLayout {
                    ForEach(tokens, id: \.self) { token in
                        HStack(spacing: 3) {
                            Text(token).font(.callout)
                            Button {
                                tokens.removeAll { $0 == token }
                                onCommit?()
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                if !suggestions.filter({ !tokens.contains($0) }).isEmpty {
                    Menu {
                        ForEach(suggestions.filter { !tokens.contains($0) }, id: \.self) { item in
                            Button(item) {
                                tokens.append(item)
                                onCommit?()
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
            }
        }
    }

    private func add() {
        let value = draft.jsTrimmed
        draft = ""
        guard !value.isEmpty, !tokens.contains(value) else { return }
        tokens.append(value)
        onCommit?()
    }
}

/// 文本输入框：失去焦点或回车时保存（系统设置没有「保存」按钮）。
struct CommitTextField: View {
    let placeholder: String
    let value: String
    var axis: Axis = .horizontal
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft, axis: axis)
            .textFieldStyle(.roundedBorder)
            .lineLimit(axis == .vertical ? 1...5 : 1...1)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, next in if !focused { draft = next } }
            .onSubmit { if draft != value { onCommit(draft) } }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, draft != value { onCommit(draft) }
            }
    }
}

/// 整数输入（带后缀单位）。
struct NumberField: View {
    let value: Int
    var range: ClosedRange<Int> = 0...1000
    var suffix: String? = nil
    var width: CGFloat = 64
    let onCommit: (Int) -> Void
    @State private var draft = 0

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $draft, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .onSubmit(commit)
            Stepper("", value: $draft, in: range)
                .labelsHidden()
                .onChange(of: draft) { _, _ in commit() }
            if let suffix { Text(suffix).foregroundStyle(.secondary) }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, next in draft = next }
    }

    private func commit() {
        let clamped = min(range.upperBound, max(range.lowerBound, draft))
        if clamped != draft { draft = clamped }
        if clamped != value { onCommit(clamped) }
    }
}

/// 小数输入（秒数等）。
struct DecimalField: View {
    let value: Double
    var range: ClosedRange<Double> = 0...1000
    var suffix: String? = nil
    let onCommit: (Double) -> Void
    @State private var draft = 0.0

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $draft, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .onSubmit(commit)
            if let suffix { Text(suffix).foregroundStyle(.secondary) }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, next in draft = next }
    }

    private func commit() {
        let clamped = min(range.upperBound, max(range.lowerBound, draft))
        draft = clamped
        if clamped != value { onCommit(clamped) }
    }
}

/// 顶部弹出的轻提示（类似 antd 的 message）。
struct ToastOverlay: View {
    let toasts: [Toast]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: icon(toast.kind)).foregroundStyle(color(toast.kind))
                    Text(toast.text).lineLimit(3).multilineTextAlignment(.leading)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: 560)
        .allowsHitTesting(false)
    }

    func icon(_ kind: Toast.Kind) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    func color(_ kind: Toast.Kind) -> Color {
        switch kind {
        case .success: .green
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

/// 空状态。
struct EmptyHint: View {
    let title: String
    var systemImage = "tray"
    var message: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
    }
}

/// 页面内容的统一外框：可滚动、两侧留白、最大宽度居中。
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = 1180
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

/// 截图缩略图（按文件修改时间刷新缓存）。
struct ScreenImage: View {
    let path: String?
    var version: Double? = nil

    var body: some View {
        if let path, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .id("\(path)#\(version ?? 0)")
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}

extension View {
    /// 和 antd Card 类似的圆角背景
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        background(.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// 系统设置样式的分组：标题、圆角底、行之间有分隔线。
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title).font(.headline) }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews.indices, id: \.self) { index in
                        subviews[index]
                        if index < subviews.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(cornerRadius: 12)
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }
}

/// 一行一项：左边标签，右边控件。
struct SettingsRow<Control: View>: View {
    let label: String
    var hint: String? = nil
    var info: String? = nil
    var vertical = false
    @ViewBuilder var control: Control

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 8) {
                    RowLabel(title: label, hint: hint, info: info)
                    control
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    RowLabel(title: label, hint: hint, info: info)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) { control }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsRow where Control == EmptyView {
    init(label: String, hint: String? = nil, info: String? = nil) {
        self.init(label: label, hint: hint, info: info) { EmptyView() }
    }
}

/// 两栏布局：宽度够时左右排（trailingWidth 为 nil 时两栏等分），不够时上下排。
/// 打开修改意见侧栏后内容区会变窄，固定的 HStack 会把侧栏挤出窗口。
struct AdaptiveColumns: Layout {
    var breakpoint: CGFloat = 820
    var spacing: CGFloat = 20
    var trailingWidth: CGFloat? = nil

    private func columnWidths(_ total: CGFloat, _ count: Int) -> [CGFloat] {
        guard count > 1 else { return [total] }
        if let trailingWidth, count == 2 { return [max(0, total - spacing - trailingWidth), trailingWidth] }
        let width = max(0, (total - spacing * CGFloat(count - 1)) / CGFloat(count))
        return Array(repeating: width, count: count)
    }

    private func horizontal(_ width: CGFloat) -> Bool { width >= breakpoint }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? breakpoint
        if horizontal(width) {
            let widths = columnWidths(width, subviews.count)
            let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if horizontal(bounds.width) {
            var x = bounds.minX
            for (subview, width) in zip(subviews, columnWidths(bounds.width, subviews.count)) {
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: nil))
                x += width + spacing
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: nil))
                y += height + spacing
            }
        }
    }
}
