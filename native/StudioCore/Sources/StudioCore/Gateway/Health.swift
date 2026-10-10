import Foundation

let DEFAULT_QUOTA_COOLDOWN_SEC: Double = 15 * 60
let CIRCUIT_THRESHOLD = 3
let CIRCUIT_OPEN_SEC: Double = 5 * 60

/// 时:分:秒（toLocaleTimeString("zh-CN", { hour12: false })）
public func clockTime(_ ms: Double) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
}

/// 线路健康状态：额度冷却、连续失败熔断、配置错误停用。
/// 写盘保存，软件重启后冷却时间依然有效。
public final class HealthStore: @unchecked Sendable {
    let file: String
    let now: @Sendable () -> Double
    private let state = Locked<JSONObject>(JSONObject())
    private let serial = SerialQueue()

    public init(dataDir: String, now: @escaping @Sendable () -> Double = nowMs) {
        file = Path.join(dataDir, "provider-health.json")
        self.now = now
        state.withLock { $0 = FS.readJSONQuiet(file)?.object ?? JSONObject() }
    }

    static let blank: JSON = ["consecutiveFailures": 0, "cooldownUntil": 0, "circuitOpenUntil": 0, "configError": nil]

    private func persist() async {
        let snapshot = JSON.object(state.current)
        let file = self.file
        _ = try? await serial.run { try FS.writeJSONAtomic(file, snapshot) }
    }

    public func snapshot(_ id: String) -> JSON { state.withLock { $0[id] } ?? HealthStore.blank }

    /// nil 表示可用，否则返回不可用原因。
    public func unavailableReason(_ id: String) -> String? {
        guard let current = state.withLock({ $0[id] }) else { return nil }
        let t = now()
        if let configError = current["configError"], configError.isObject { return "配置错误：\(configError["message"]?.jsString ?? "")" }
        if let until = current["cooldownUntil"]?.number, until > t { return "额度冷却中，\(clockTime(until)) 恢复" }
        if let until = current["circuitOpenUntil"]?.number, until > t { return "连续失败已熔断，\(clockTime(until)) 恢复" }
        return nil
    }

    public func recordSuccess(_ id: String) async {
        state.withLock { all in
            var entry = all[id] ?? HealthStore.blank
            entry["consecutiveFailures"] = 0
            entry["circuitOpenUntil"] = 0
            all[id] = entry
        }
        await persist()
    }

    public func recordFailure(_ id: String, kind: String, message: String, retryAfterSec: Double?) async {
        let t = now()
        state.withLock { all in
            var entry = all[id] ?? HealthStore.blank
            if kind == "auth" || kind == "config" {
                entry["configError"] = .obj(["message": .string(message.jsSlice(0, 200)), "at": .string(isoString(Date(timeIntervalSince1970: t / 1000)))])
            } else if kind == "quota" {
                let seconds = retryAfterSec.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? DEFAULT_QUOTA_COOLDOWN_SEC
                entry["cooldownUntil"] = .number(t + seconds * 1000)
                entry["cooldownReason"] = .string(message.jsSlice(0, 200))
            } else if ["server", "network", "timeout", "task-failed", "invalid-image"].contains(kind) {
                var failures = (entry["consecutiveFailures"]?.number ?? 0) + 1
                if Int(failures) >= CIRCUIT_THRESHOLD {
                    entry["circuitOpenUntil"] = .number(t + CIRCUIT_OPEN_SEC * 1000)
                    failures = 0
                }
                entry["consecutiveFailures"] = .number(failures)
            }
            all[id] = entry
        }
        await persist()
    }

    /// 测试通过或用户手动恢复后清除所有不可用状态。
    public func reset(_ id: String) async {
        state.withLock { $0[id] = HealthStore.blank }
        await persist()
    }
}
