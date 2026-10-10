import Foundation

/// 线性插值的百分位（和 Electron 版一致）。
public func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = (p / 100) * Double(sorted.count - 1)
    let low = Int(rank.rounded(.down))
    let high = Int(rank.rounded(.up))
    return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
}

public struct ProviderStats: Sendable, Codable, Hashable {
    public var providerId: String
    public var calls: Int
    public var successRate: Double?
    public var p50: Double?
    public var p85: Double?
    public var p90: Double?
    public var lastError: String?
    public var lastAt: String?
}

/// 只追加的调用记录（一行一次调用）。旧 skill 每次运行都会覆盖 summary，
/// 历史耗时就丢了；这里全部保留，统计和补发线都从这里算。
public final class CallLog: @unchecked Sendable {
    public let file: String
    private let rows: Locked<[JSON]>
    private let serial = SerialQueue()
    private let listeners = Locked<[@Sendable (JSON) -> Void]>([])

    public init(dataDir: String, fileName: String = "image-calls.jsonl") {
        file = Path.join(dataDir, fileName)
        rows = Locked(FS.readJSONLines(file))
    }

    @discardableResult
    public func append(_ record: JSON) async -> JSON {
        var object = JSONObject([("ts", .string(isoNow()))])
        for (key, value) in record.object ?? JSONObject() { object[key] = value }
        let row = JSON.object(object)
        rows.withLock { $0.append(row) }
        for listener in listeners.current { listener(row) }
        let file = self.file
        _ = try? await serial.run { try FS.appendJSONLine(file, row) }
        return row
    }

    public func onAppend(_ listener: @escaping @Sendable (JSON) -> Void) {
        listeners.withLock { $0.append(listener) }
    }

    public func all() -> [JSON] { rows.current }

    public func query(limit: Int = 200, providerId: String? = nil, projectDir: String? = nil, sinceTs: String? = nil) -> [JSON] {
        let all = rows.current
        var result: [JSON] = []
        var index = all.count - 1
        while index >= 0, result.count < limit {
            let row = all[index]
            index -= 1
            if let providerId, row["providerId"]?.string != providerId { continue }
            if let projectDir, row["projectDir"]?.string != projectDir { continue }
            if let sinceTs, (row["ts"]?.string ?? "") < sinceTs { continue }
            result.append(row)
        }
        return result
    }

    /// 某条线路最近 window 次调用的耗时样本（秒），用来算补发线。
    /// 除了成功的调用，也计入「补发后被取消」和「超时」的调用（按已等待的时间算，真实耗时只会更长）。
    /// 否则慢的请求一旦被补发取消就不再进样本，补发线会越算越低、补发越来越多。
    public func recentSuccessSeconds(_ providerId: String, window: Int = 50) -> [Double] {
        let all = rows.current
        var values: [Double] = []
        var index = all.count - 1
        while index >= 0, values.count < window {
            let row = all[index]
            index -= 1
            guard row["providerId"]?.string == providerId, let duration = row["durationMs"]?.number, duration.isFinite, duration > 0 else { continue }
            let kind = row["kind"]?.string
            let censored = (kind == "aborted" && row["outcome"]?.string == "loser") || kind == "timeout"
            if row["ok"]?.truthy == true || censored { values.append(duration / 1000) }
        }
        return values
    }

    public func stats(_ providerId: String, window: Int = 50) -> ProviderStats {
        let all = rows.current
        var recent: [JSON] = []
        var index = all.count - 1
        while index >= 0, recent.count < window {
            let row = all[index]
            index -= 1
            if row["providerId"]?.string == providerId, row["kind"]?.string != "aborted" { recent.append(row) }
        }
        let ok = recent.filter { $0["ok"]?.truthy == true }
        let durations = ok.map { ($0["durationMs"]?.number ?? 0) / 1000 }
        return ProviderStats(
            providerId: providerId,
            calls: recent.count,
            successRate: recent.isEmpty ? nil : Double(ok.count) / Double(recent.count),
            p50: percentile(durations, 50),
            p85: percentile(durations, 85),
            p90: percentile(durations, 90),
            lastError: recent.first { $0["ok"]?.truthy != true }?["errorMessage"]?.string,
            lastAt: recent.first?["ts"]?.string
        )
    }
}
