import Charts
import StudioCore
import SwiftUI

private let RANGES: [(days: Int, label: String)] = [(7, "最近 7 天"), (30, "最近 30 天"), (90, "最近 90 天"), (0, "全部")]
private let METRICS: [(key: String, label: String, unit: String)] = [("images", "截图", "张"), ("completed", "完成项目", "个"), ("llm", "大模型调用", "次"), ("created", "新建项目", "个")]

/// 统计：生了多少图、调了多少次大模型、平均用时，加每日热力图和趋势。
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 30
    @State private var metric = "images"
    @State private var stats: JSON?

    var body: some View {
        PageScroll {
            if let stats {
                tiles(stats)
                SettingsGroup(title: "每日热力图", footer: "颜色越深当天越多；鼠标停在格子上看具体数字。热力图不受上面时间范围影响，显示最近一年。", trailing: AnyView(metricPicker)) {
                    Heatmap(daily: stats["daily"].fields, metric: metric).padding(14)
                }
                SettingsGroup(title: "每日趋势（\(METRICS.first { $0.key == metric }?.label ?? "")）") {
                    TrendChart(daily: stats["daily"].fields, metric: metric, days: days == 0 ? 60 : days).frame(height: 180).padding(14)
                }
                AdaptiveColumns(breakpoint: 720) {
                    SettingsGroup(title: "按生图线路") {
                        if stats["byProvider"].items.isEmpty { EmptyRow() }
                        ForEach(stats["byProvider"].items.indices, id: \.self) { index in
                            let row = stats["byProvider"].items[index]
                            SettingsRow(label: row["name"].text, hint: "请求 \(row["requests"]?.int ?? 0) 次 · 平均 \(formatSeconds(row["avgSec"]?.number))") {
                                Text("\(row["images"]?.int ?? 0) 张").monospacedDigit()
                            }
                        }
                    }
                    SettingsGroup(title: "按大模型") {
                        if stats["byModel"].items.isEmpty { EmptyRow() }
                        ForEach(stats["byModel"].items.indices, id: \.self) { index in
                            let row = stats["byModel"].items[index]
                            SettingsRow(label: row["model"].text, hint: "成功 \(row["ok"]?.int ?? 0) 次 · 平均 \(formatSeconds(row["avgSec"]?.number))") {
                                Text("\(row["calls"]?.int ?? 0) 次").monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .navigationTitle("统计")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $days) {
                    ForEach(RANGES, id: \.days) { Text($0.label).tag($0.days) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .task(id: "\(days)-\(model.callsRevision)-\(model.projects.count)") { await load() }
    }

    var metricPicker: some View {
        Picker("", selection: $metric) {
            ForEach(METRICS, id: \.key) { Text($0.label).tag($0.key) }
        }
        .labelsHidden()
        .fixedSize()
    }

    @State private var loadedDays: Int?
    @State private var loadedAt = Date.distantPast

    func load() async {
        // 生成过程中调用记录一直在变：离上次刷新不到 5 秒就等到满 5 秒（新事件会取消重来，但等待只会越来越短）；换时间范围立即刷新
        if stats != nil, loadedDays == days {
            let wait = 5 - Date().timeIntervalSince(loadedAt)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { return }
            }
        }
        stats = try? await model.core?.usageStats(days: days == 0 ? nil : days)
        loadedDays = days
        loadedAt = Date()
    }

    func percent(_ value: Double?) -> String { value.map { "\(Int(jsRound($0 * 100)))%" } ?? "—" }

    func tiles(_ stats: JSON) -> some View {
        let projects = stats["projects"], images = stats["images"], llm = stats["llm"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
            StatCard(title: "完成项目", value: "\(projects?["completed"]?.int ?? 0) 个", detail: "新建 \(projects?["created"]?.int ?? 0) 个")
            StatCard(title: "生成截图", value: "\(images?["generated"]?.int ?? 0) 张", detail: "成功率 \(percent(images?["successRate"]?.number))")
            StatCard(title: "大模型调用", value: "\(llm?["calls"]?.int ?? 0) 次", detail: "成功率 \(percent(llm?["successRate"]?.number))")
            StatCard(title: "平均每个项目", value: formatDurationUI(projects?["avgSec"]?.number.map { $0 * 1000 }), detail: "从开始到交付包")
            StatCard(title: "平均每张图", value: formatSeconds(images?["avgSec"]?.number), detail: "中位数 \(formatSeconds(images?["p50"]?.number))")
            StatCard(title: "大模型平均", value: formatSeconds(llm?["avgSec"]?.number), detail: "每次调用")
        }
    }
}

private struct EmptyRow: View {
    var body: some View { Text("这段时间没有记录").foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
}

/// 统计卡片：标题、数值、一行说明。
struct StatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground()
    }
}

private func dayDate(_ key: String) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

private func count(_ daily: JSONObject, _ key: String, _ metric: String) -> Int { daily[key]?[metric]?.int ?? 0 }

/// 日历热力图：一列一周（周一在上），按宽度放下尽量多的周，最多一年。
struct Heatmap: View {
    let daily: JSONObject
    let metric: String
    private let gap: CGFloat = 3
    private let weeks = 53
    @State private var width: CGFloat = 800

    var body: some View {
        // 一年 53 周铺满宽度，格子 9–16 点；高度跟着格子大小走
        let cell = max(9, min(16, (width - 28) / CGFloat(weeks) - gap))
        let columns = buildColumns(weeks)
        let maxValue = columns.flatMap { $0 }.compactMap { $0.map { count(daily, $0.key, metric) } }.max() ?? 0
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .top, spacing: gap) {
                VStack(alignment: .trailing, spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(["一", "", "三", "", "五", "", "日"][row]).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 22, height: cell, alignment: .trailing)
                    }
                }
                ForEach(columns.indices, id: \.self) { column in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            if let day = columns[column][row] {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color(count(daily, day.key, metric), maxValue))
                                    .frame(width: cell, height: cell)
                                    .help(tooltip(day))
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("少").font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3).fill(level == 0 ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.2 + Double(level) * 0.2)).frame(width: 11, height: 11)
                }
                Text("多").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    struct Day { let key: String; let date: Date }

    /// 最后一列是本周；未来的日子留空。
    func buildColumns(_ weeks: Int) -> [[Day?]] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return (0..<weeks).map { column in
            let start = calendar.date(byAdding: .weekOfYear, value: column - (weeks - 1), to: weekStart)!
            return (0..<7).map { row in
                let date = calendar.date(byAdding: .day, value: row, to: start)!
                return date > today ? nil : Day(key: UsageStats.dayKey(date.timeIntervalSince1970 * 1000), date: date)
            }
        }
    }

    func color(_ value: Int, _ maxValue: Int) -> Color {
        guard value > 0, maxValue > 0 else { return Color.secondary.opacity(0.12) }
        // 平方根分档：个别特别多的日子不会把其他日子都压成浅色
        let level = min(4, max(1, Int(ceil(sqrt(Double(value) / Double(maxValue)) * 4))))
        return Color.accentColor.opacity(0.2 + Double(level) * 0.2)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 EEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    func tooltip(_ day: Day) -> String {
        return "\(Self.dayFormatter.string(from: day.date))：截图 \(count(daily, day.key, "images")) 张 · 完成项目 \(count(daily, day.key, "completed")) 个 · 新建 \(count(daily, day.key, "created")) 个 · 大模型 \(count(daily, day.key, "llm")) 次"
    }
}

/// 最近 N 天的每日柱状图。
struct TrendChart: View {
    let daily: JSONObject
    let metric: String
    let days: Int

    struct Point: Identifiable { let id: String; let date: Date; let value: Int }

    var points: [Point] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: today)!
            let key = UsageStats.dayKey(date.timeIntervalSince1970 * 1000)
            return Point(id: key, date: date, value: count(daily, key, metric))
        }
    }

    var body: some View {
        let label = METRICS.first { $0.key == metric }?.label ?? ""
        Chart(points) { point in
            BarMark(x: .value("日期", point.date, unit: .day), y: .value(label, point.value))
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, days / 7))) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
            }
        }
    }
}
