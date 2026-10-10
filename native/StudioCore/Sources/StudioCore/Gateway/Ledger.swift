import Foundation

let KEEP_FINISHED_DAYS: Double = 3

/// 生图任务账本（思路来自四季画布的 run ledger）：
/// - 异步任务号拿到就落盘，重启后续查，不重复提交；
/// - 启动时还停在「提交中」的尝试标为「提交结果未知（可能已扣费）」，交给用户决定。
public final class Ledger: @unchecked Sendable {
    let file: String
    let now: @Sendable () -> Double
    private let data = Locked<JSONObject>(JSONObject())
    private let serial = SerialQueue()

    public init(dataDir: String, now: @escaping @Sendable () -> Double = nowMs) {
        file = Path.join(dataDir, "image-jobs.json")
        self.now = now
    }

    private func iso() -> String { isoString(Date(timeIntervalSince1970: now() / 1000)) }

    private func persist() async {
        let snapshot = JSON.obj(["jobs": .object(data.current)])
        let file = self.file
        _ = try? await serial.run { try FS.writeJSONAtomic(file, snapshot) }
    }

    public func initialize() async {
        let stored = FS.readJSONQuiet(file)?["jobs"]?.object ?? JSONObject()
        let cutoff = now() - KEEP_FINISHED_DAYS * 86_400_000
        var changed = false
        var jobs = JSONObject()
        for (jobId, job) in stored {
            var job = job
            if job["state"]?.string != "running", (parseISO(job["updatedAt"]?.string) ?? 0) < cutoff {
                changed = true
                continue
            }
            var attempts = job["attempts"]?.array ?? []
            for index in attempts.indices where attempts[index]["state"]?.string == "submitting" {
                attempts[index]["state"] = "unknown"
                attempts[index]["error"] = "软件在提交途中退出，不确定中转站是否已收到请求（可能已扣费）"
                changed = true
            }
            job["attempts"] = .array(attempts)
            if job["state"]?.string == "running", !attempts.contains(where: { $0["state"]?.string == "waiting" }) {
                job["state"] = attempts.contains(where: { $0["state"]?.string == "unknown" }) ? "needs-attention" : "interrupted"
                changed = true
            }
            jobs[jobId] = job
        }
        data.withLock { $0 = jobs }
        if changed { await persist() }
    }

    public func get(_ jobId: String) -> JSON? { data.withLock { $0[jobId] } }

    public func list(_ filter: (JSON) -> Bool = { _ in true }) -> [JSON] { data.current.values.filter(filter) }

    public func createJob(_ job: JSON) async {
        var entry = job
        entry["state"] = "running"
        entry["attempts"] = []
        entry["createdAt"] = .string(iso())
        entry["updatedAt"] = .string(iso())
        let jobId = job["jobId"]?.string ?? ""
        data.withLock { $0[jobId] = entry }
        await persist()
    }

    private func mutateAttempt(_ jobId: String, _ attemptId: String, _ body: (inout JSON) -> Void) -> Bool {
        data.withLock { jobs in
            guard var job = jobs[jobId], var attempts = job["attempts"]?.array,
                  let index = attempts.firstIndex(where: { $0["attemptId"]?.string == attemptId }) else { return false }
            body(&attempts[index])
            job["attempts"] = .array(attempts)
            job["updatedAt"] = .string(iso())
            jobs[jobId] = job
            return true
        }
    }

    public func startAttempt(_ jobId: String, _ attempt: JSON) async {
        var entry = attempt
        entry["state"] = "submitting"
        entry["startedAt"] = .string(iso())
        data.withLock { jobs in
            guard var job = jobs[jobId] else { return }
            job["attempts"] = .array((job["attempts"]?.array ?? []) + [entry])
            job["updatedAt"] = .string(iso())
            jobs[jobId] = job
        }
        await persist()
    }

    public func markTaskId(_ jobId: String, _ attemptId: String, _ taskId: String) async {
        let found = mutateAttempt(jobId, attemptId) { attempt in
            attempt["taskId"] = .string(taskId)
            attempt["state"] = "waiting"
        }
        if found { await persist() }
    }

    public func finishAttempt(_ jobId: String, _ attemptId: String, _ result: JSON) async {
        let endedAt = iso()
        let found = mutateAttempt(jobId, attemptId) { attempt in
            attempt = attempt.merging(result)
            attempt["endedAt"] = .string(endedAt)
        }
        if found { await persist() }
    }

    public func finishJob(_ jobId: String, _ result: JSON) async {
        let found: Bool = data.withLock { jobs in
            guard let job = jobs[jobId] else { return false }
            var next = job.merging(result)
            next["updatedAt"] = .string(iso())
            jobs[jobId] = next
            return true
        }
        if found { await persist() }
    }

    /// 重启后需要续查的远端任务。
    public func remoteWaiting() -> [(job: JSON, attempt: JSON)] {
        var result: [(JSON, JSON)] = []
        for job in data.current.values {
            for attempt in job["attempts"]?.array ?? [] where attempt["state"]?.string == "waiting" && attempt["taskId"]?.string != nil {
                result.append((job, attempt))
            }
        }
        return result
    }

    public func dismiss(_ jobId: String) async {
        let found: Bool = data.withLock { jobs in
            guard var job = jobs[jobId] else { return false }
            job["state"] = "dismissed"
            job["updatedAt"] = .string(iso())
            jobs[jobId] = job
            return true
        }
        if found { await persist() }
    }
}
