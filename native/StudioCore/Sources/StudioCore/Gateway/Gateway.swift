import Foundation

let PROBE_PROMPT = "A single portrait mobile app settings screen, light theme, clean list of toggles and section headers in Simplified Chinese. No logo, no brand name, no device frame."

public struct GenerateRequest: Sendable {
    public var projectDir: String
    public var projectName: String
    public var screenId: String
    public var prompt: String
    public var outputPath: String
    public var alternatesDir: String
    public var archiveRoot: String
    public var batchId: String?

    public init(projectDir: String, projectName: String, screenId: String, prompt: String, outputPath: String, alternatesDir: String, archiveRoot: String, batchId: String? = nil) {
        self.projectDir = projectDir
        self.projectName = projectName
        self.screenId = screenId
        self.prompt = prompt
        self.outputPath = outputPath
        self.alternatesDir = alternatesDir
        self.archiveRoot = archiveRoot
        self.batchId = batchId
    }
}

public struct GenerateResult: Sendable {
    public var jobId: String
    public var outputPath: String
    public var providerId: String
    public var providerName: String
    public var model: String
    public var requestSize: String?
    public var width: Int?
    public var height: Int?
    public var durationMs: Double
    public var hedged: Bool
    public var attempts: Int
    public var warnings: [String]
    public var resumed = false
    public var ok = true
}

/// 整屏失败：message 里列出每条线路的原因。
public struct GenerateFailure: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// 生图网关：每屏一个独立任务，真正异步并发；失败切换、超时补发、额度冷却、任务账本续查。
public actor ImageGateway {
    let getSettings: @Sendable () async throws -> Settings
    let updateProvider: @Sendable (String, SizeFallback) async -> Void
    let secrets: SecretStore
    let ledger: Ledger
    let health: HealthStore
    let callLog: CallLog
    let http: HTTPClient
    let checkImage: @Sendable (Data) -> ImageCheck
    let now: @Sendable () -> Double
    let onEvent: @Sendable (JSON) -> Void
    let sleepImpl: @Sendable (Double) async throws -> Void
    let randomDelayMs: @Sendable () -> Double

    nonisolated let globalSemaphore = AsyncSemaphore(10)
    private nonisolated let providerSemaphores = Locked<[String: AsyncSemaphore]>([:])
    private nonisolated let hedgesByBatch = Locked<[String: Int]>([:])
    private var inflightByScreen: [String: Task<GenerateResult, Error>] = [:]

    public init(
        getSettings: @escaping @Sendable () async throws -> Settings,
        updateProvider: @escaping @Sendable (String, SizeFallback) async -> Void = { _, _ in },
        secrets: SecretStore,
        ledger: Ledger,
        health: HealthStore,
        callLog: CallLog,
        http: HTTPClient,
        checkImage: @escaping @Sendable (Data) -> ImageCheck = { checkScreenImage($0) },
        now: @escaping @Sendable () -> Double = nowMs,
        onEvent: @escaping @Sendable (JSON) -> Void = { _ in },
        sleepImpl: @escaping @Sendable (Double) async throws -> Void = { try await sleepMs($0) },
        randomDelayMs: @escaping @Sendable () -> Double = { Double(2000 + Int.random(in: 0..<3000)) }
    ) {
        self.getSettings = getSettings
        self.updateProvider = updateProvider
        self.secrets = secrets
        self.ledger = ledger
        self.health = health
        self.callLog = callLog
        self.http = http
        self.checkImage = checkImage
        self.now = now
        self.onEvent = onEvent
        self.sleepImpl = sleepImpl
        self.randomDelayMs = randomDelayMs
    }

    nonisolated func providerSemaphore(_ provider: ImageProvider) -> AsyncSemaphore {
        let semaphore = providerSemaphores.withLock { table in
            if let existing = table[provider.id] { return existing }
            let created = AsyncSemaphore(provider.concurrency)
            table[provider.id] = created
            return created
        }
        semaphore.setLimit(provider.concurrency)
        return semaphore
    }

    nonisolated func takeHedgeSlot(_ batchId: String, limit: Int) -> Bool {
        hedgesByBatch.withLock { table in
            let used = table[batchId] ?? 0
            if used >= limit { return false }
            table[batchId] = used + 1
            return true
        }
    }

    nonisolated func secretList() async -> [String] { await secrets.values() }

    public nonisolated func hedgeThresholdMs(_ provider: ImageProvider, _ hedge: HedgeSettings) -> Double {
        let recent = callLog.recentSuccessSeconds(provider.id, window: 50)
        let base = recent.count >= 5 ? (percentile(recent, hedge.percentile == 0 ? 85 : hedge.percentile) ?? 60) : (provider.hedgeDefaultSec == 0 ? 60 : provider.hedgeDefaultSec)
        let clamped = min(hedge.maxSec == 0 ? 120 : hedge.maxSec, max(hedge.minSec == 0 ? 20 : hedge.minSec, base))
        return jsRound(clamped * 1000)
    }

    nonisolated func installFile(_ outputPath: String, _ png: Data, _ archiveRoot: String) throws {
        if FS.exists(outputPath) {
            // 同一分钟内替换的截图归档到同一个文件夹；同名时加序号，不覆盖已归档的旧图
            let archiveDir = Path.join(archiveRoot, "screens-\(timestampSlug(Date(timeIntervalSince1970: now() / 1000)).jsSlice(0, 16))")
            try FS.mkdirp(archiveDir)
            let base = Path.basename(outputPath, ".png")
            var target = Path.join(archiveDir, "\(base).png")
            var index = 2
            while FS.exists(target) {
                target = Path.join(archiveDir, "\(base)-\(index).png")
                index += 1
            }
            try FileManager.default.copyItem(atPath: outputPath, toPath: target)
        }
        try FS.writeAtomic(outputPath, png)
    }

    nonisolated func saveAlternate(alternatesDir: String, screenId: String, providerId: String, png: Data) throws -> String {
        let dir = Path.join(alternatesDir, screenId)
        try FS.mkdirp(dir)
        let file = Path.join(dir, "\(timestampSlug(Date(timeIntervalSince1970: now() / 1000)))-\(providerId).png")
        try FS.writeAtomic(file, png)
        return file
    }

    nonisolated func pickHedgeProvider(_ providers: [ImageProvider], _ current: ImageProvider, _ tried: [String], _ hedge: HedgeSettings) -> ImageProvider? {
        let candidates = providers.filter { $0.id != current.id && !tried.contains($0.id) && health.unavailableReason($0.id) == nil }
        let group = modelGroupOf(current)
        let host = hostOf(current.baseUrl)
        return candidates.first { modelGroupOf($0) == group && hostOf($0.baseUrl) != host }
            ?? candidates.first { modelGroupOf($0) == group }
            ?? (hedge.allowCrossModel ? candidates.first : nil)
    }

    /// 生成一屏。取消当前任务即取消这一屏的所有尝试。
    public func generate(_ request: GenerateRequest) async throws -> GenerateResult {
        if Task.isCancelled { throw ProviderError("已取消", kind: "aborted") }
        let key = "\(request.projectDir)::\(request.screenId)"
        if let inflight = inflightByScreen[key] {
            let result = try await inflight.value
            // 重启后续查的任务失败了：这一屏重新正常生成
            if result.resumed && !result.ok { return try await generate(request) }
            return result
        }
        let job = try await GatewayJob(gateway: self, request: request)
        let task = Task<GenerateResult, Error> { try await job.run() }
        inflightByScreen[key] = task
        defer { inflightByScreen[key] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await job.abortAll() }
        }
    }

    /// 软件重启后，把账本里还在等结果的异步任务接着查完。
    public func resumePending() async -> [String] {
        guard let settings = try? await getSettings() else { return [] }
        var resumed: [String] = []
        for (job, attempt) in ledger.remoteWaiting() {
            guard let provider = settings.providers.first(where: { $0.id == attempt["providerId"]?.string }) else { continue }
            let apiKey = await secrets.get(SecretIds.imageProvider(provider.id))
            if apiKey.isEmpty { continue }
            let jobId = job["jobId"]?.string ?? ""
            let attemptId = attempt["attemptId"]?.string ?? ""
            let taskId = attempt["taskId"]?.string ?? ""
            let startedAt = now()
            let work = Task<Void, Never> { [ledger, callLog, http, checkImage, onEvent] in
                do {
                    let result = try await runAttempt(provider: provider, apiKey: apiKey, prompt: job["prompt"]?.string ?? "", resumeTaskId: taskId, http: http)
                    let check = checkImage(result.bytes)
                    guard check.ok, let png = check.png else { throw ProviderError(check.reason ?? "图片无效", kind: "invalid-image") }
                    let latest = ledger.get(jobId)
                    var outcome = "alternate"
                    var file: String
                    let state = latest?["state"]?.string
                    if state == "running" || state == "interrupted" {
                        try self.installFile(job["outputPath"]?.string ?? "", png, job["archiveRoot"]?.string ?? "")
                        await ledger.finishJob(jobId, .obj(["state": "done", "winnerAttemptId": .string(attemptId), "providerId": .string(provider.id)]))
                        outcome = "winner"
                        file = job["outputPath"]?.string ?? ""
                    } else {
                        file = try self.saveAlternate(alternatesDir: job["alternatesDir"]?.string ?? "", screenId: job["screenId"]?.string ?? "", providerId: provider.id, png: png)
                    }
                    await ledger.finishAttempt(jobId, attemptId, .obj(["state": "completed", "outcome": .string(outcome), "resumed": true]))
                    await callLog.append(.obj([
                        "jobId": .string(jobId), "projectDir": job["projectDir"], "screenId": job["screenId"], "providerId": .string(provider.id),
                        "providerName": .string(provider.name), "model": .string(provider.model), "role": "resume", "ok": true, "kind": "success",
                        "outcome": .string(outcome), "durationMs": .number(self.now() - startedAt), "taskId": .string(taskId),
                    ]))
                    onEvent(.obj(["type": .string(outcome == "winner" ? "job-recovered" : "alternate"), "jobId": .string(jobId), "projectDir": job["projectDir"], "screenId": job["screenId"], "file": .string(file), "providerId": .string(provider.id)]))
                } catch {
                    await ledger.finishAttempt(jobId, attemptId, .obj(["state": "failed", "error": .string(messageOf(error)), "resumed": true]))
                    let state = ledger.get(jobId)?["state"]?.string
                    if state == "running" || state == "interrupted" { await ledger.finishJob(jobId, .obj(["state": "failed", "error": .string(messageOf(error))])) }
                }
            }
            let key = "\(job["projectDir"]?.string ?? "")::\(job["screenId"]?.string ?? "")"
            if inflightByScreen[key] == nil {
                let requestSize = attempt["requestSize"]?.string
                let tracked = Task<GenerateResult, Error> { [ledger] in
                    await work.value
                    let latest = ledger.get(jobId)
                    let ok = latest?["state"]?.string == "done" && latest?["winnerAttemptId"]?.string == attemptId
                    return GenerateResult(jobId: jobId, outputPath: job["outputPath"]?.string ?? "", providerId: provider.id, providerName: provider.name, model: provider.model, requestSize: requestSize, width: nil, height: nil, durationMs: self.now() - startedAt, hedged: false, attempts: 1, warnings: [], resumed: true, ok: ok)
                }
                inflightByScreen[key] = tracked
                Task { _ = try? await tracked.value; self.clearInflight(key, tracked) }
            }
            resumed.append(jobId)
        }
        return resumed
    }

    private func clearInflight(_ key: String, _ task: Task<GenerateResult, Error>) {
        if inflightByScreen[key] == task { inflightByScreen[key] = nil }
    }

    /// 测试线路：先免费查模型列表，需要时再真实生成一张（会扣一张图的费用）。
    public func probe(_ providerId: String, realImage: Bool = false) async throws -> JSON {
        let settings = try await getSettings()
        guard var provider = settings.providers.first(where: { $0.id == providerId }) else { throw StudioError("线路不存在") }
        let apiKey = await secrets.get(SecretIds.imageProvider(provider.id))
        if apiKey.isEmpty { throw StudioError("这条线路还没有填写密钥") }
        let secretValues = await secretList()
        var report: JSON = ["providerId": .string(providerId), "models": nil, "hasModel": nil, "image": nil]
        do {
            let models = try await probeModels(provider: provider, apiKey: apiKey, http: http)
            report["models"] = JSON(Array(models.models.prefix(200)))
            report["hasModel"] = JSON.orNull(models.hasModel)
        } catch {
            let message = redact(messageOf(error), secretValues)
            report["modelsError"] = .string(message)
            if (error as? ProviderError)?.kind == "auth" { throw StudioError("鉴权失败：\(message)") }
        }
        if !realImage { return report }
        var sizeSpec = resolveRequestSize(provider, settings.image.targetSize)
        for round in 0..<2 {
            let startedAt = now()
            do {
                let timeout = provider.hardTimeoutSec == 0 ? 240 : provider.hardTimeoutSec
                let current = provider
                let size = sizeSpec.size
                let http = self.http
                let result = try await withDeadline(seconds: timeout) {
                    try await runAttempt(provider: current, apiKey: apiKey, prompt: PROBE_PROMPT, size: size, quality: "low", http: http)
                }
                let check = checkImage(result.bytes)
                let durationMs = now() - startedAt
                await callLog.append(.obj([
                    "providerId": .string(provider.id), "providerName": .string(provider.name), "model": .string(provider.model), "role": "probe",
                    "ok": .bool(check.ok), "kind": .string(check.ok ? "success" : "invalid-image"), "durationMs": .number(durationMs),
                    "requestSize": .string(sizeSpec.size), "width": JSON.maybe(check.width), "height": JSON.maybe(check.height),
                    "errorMessage": check.ok ? nil : JSON.string(check.reason ?? ""),
                ]))
                if check.ok { await health.reset(provider.id) }
                report["image"] = .obj([
                    "ok": .bool(check.ok), "durationMs": .number(durationMs), "requestSize": .string(sizeSpec.size),
                    "width": JSON.maybe(check.width), "height": JSON.maybe(check.height), "reason": JSON.maybe(check.reason),
                    "warnings": JSON(check.warnings),
                    "dataUrl": check.ok ? JSON.maybe(check.png.map { "data:image/png;base64,\($0.base64EncodedString())" }) : nil,
                ])
                return report
            } catch {
                let providerError = (error as? ProviderError) ?? (error is RequestTimedOut ? ProviderError("超过 \(JSON.formatNumber(provider.hardTimeoutSec)) 秒没有出图", kind: "timeout") : ProviderError(messageOf(error), kind: "unknown"))
                let message = redact(providerError.message, secretValues)
                await callLog.append(.obj([
                    "providerId": .string(provider.id), "providerName": .string(provider.name), "model": .string(provider.model), "role": "probe",
                    "ok": false, "kind": .string(providerError.kind), "durationMs": .number(now() - startedAt), "requestSize": .string(sizeSpec.size), "errorMessage": .string(message),
                ]))
                if providerError.kind == "size", round == 0, let fallback = sizeFallback(providerError, provider, settings.image.targetSize, sizeSpec.size) {
                    sizeSpec = fallback.spec
                    fallback.apply(to: &provider)
                    await updateProvider(provider.id, fallback)
                    report["sizeSwitched"] = .string(sizeSpec.size)
                    continue
                }
                report["image"] = .obj(["ok": false, "requestSize": .string(sizeSpec.size), "reason": .string(message), "kind": .string(providerError.kind)])
                return report
            }
        }
        return report
    }

    public nonisolated func providerStatus(_ provider: ImageProvider) -> JSON {
        let stats = (try? JSON.encode(callLog.stats(provider.id))) ?? .emptyObject
        return stats.merging(.obj(["unavailable": JSON.orNull(health.unavailableReason(provider.id)), "health": health.snapshot(provider.id)]))
    }
}

// MARK: - 一屏的生成任务

final class Attempt: @unchecked Sendable {
    let attemptId = randomHex(6)
    let provider: ImageProvider
    let role: String
    var task: Task<Void, Never>?
    var timers: [Task<Void, Never>] = []
    var taskId: String?
    var holdsGlobal = false
    var holdsProvider = false
    var startedAt: Double?
    var sizeSpec: SizeSpec?
    var abortReason: String?
    var cancelRequested = false

    init(provider: ImageProvider, role: String) {
        self.provider = provider
        self.role = role
    }

    func abort() {
        cancelRequested = true
        task?.cancel()
    }
}

actor GatewayJob {
    let gateway: ImageGateway
    let request: GenerateRequest
    let settings: Settings
    let providers: [ImageProvider]
    let jobId: String
    let maxAttempts: Int
    let secretValues: [String]

    var settled = false
    var active: [String: Attempt] = [:]
    var activeOrder: [String] = []
    var background: [String: Attempt] = [:]
    var tried: [String] = []
    var failures: [(providerId: String, providerName: String, kind: String, message: String)] = []
    var started = 0
    var hedged = false
    var retried = Set<String>()
    var sizeOverrides: [String: SizeSpec] = [:]
    let startedAt: Double
    var continuation: CheckedContinuation<GenerateResult, Error>?
    var pendingOutcome: Result<GenerateResult, Error>?

    var imageSettings: ImageSettings { settings.image }
    var hedge: HedgeSettings { settings.image.hedge }

    init(gateway: ImageGateway, request: GenerateRequest) async throws {
        self.gateway = gateway
        self.request = request
        let settings = try await gateway.getSettings()
        self.settings = settings
        gateway.globalSemaphore.setLimit(settings.image.globalConcurrency == 0 ? 10 : settings.image.globalConcurrency)
        providers = settings.providers.filter(\.enabled)
        if providers.isEmpty { throw StudioError("还没有可用的生图线路，请先到「生图线路」里添加并启用") }
        maxAttempts = settings.image.maxAttemptsPerScreen == 0 ? 4 : settings.image.maxAttemptsPerScreen
        secretValues = await gateway.secretList()
        jobId = "\(Path.basename(request.projectDir)):\(request.screenId):\(randomHex(4))"
        startedAt = gateway.now()
        await gateway.ledger.createJob(.obj([
            "jobId": .string(jobId), "projectDir": .string(request.projectDir), "screenId": .string(request.screenId),
            "outputPath": .string(request.outputPath), "alternatesDir": .string(request.alternatesDir), "archiveRoot": .string(request.archiveRoot),
            "prompt": .string(request.prompt), "batchId": JSON.orNull(request.batchId),
        ]))
    }

    func run() async throws -> GenerateResult {
        try await withCheckedThrowingContinuation { continuation in
            if let pendingOutcome {
                continuation.resume(with: pendingOutcome)
                return
            }
            self.continuation = continuation
            failover()
        }
    }

    private func finish(_ outcome: Result<GenerateResult, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: outcome)
        } else if pendingOutcome == nil {
            pendingOutcome = outcome
        }
    }

    private func emit(_ event: JSON) {
        gateway.onEvent(JSON.obj(["jobId": .string(jobId), "projectDir": .string(request.projectDir), "screenId": .string(request.screenId)]).merging(event))
    }

    private func nextProvider() -> ImageProvider? {
        let candidates = providers.filter { !tried.contains($0.id) && gateway.health.unavailableReason($0.id) == nil }
        guard let first = candidates.first else { return nil }
        // 首选线路满载时，分流到同画风组里还有空位的线路（不改变画风）
        if imageSettings.spillover, !gateway.providerSemaphore(first).hasCapacity() {
            let group = modelGroupOf(first)
            if let spare = candidates.first(where: { $0.id != first.id && modelGroupOf($0) == group && gateway.providerSemaphore($0).hasCapacity() }) { return spare }
        }
        return first
    }

    private func unavailableSummary() -> [String] {
        providers.compactMap { provider in gateway.health.unavailableReason(provider.id).map { "\(provider.name)：\($0)" } }
    }

    func abortAll() async {
        if settled { return }
        settled = true
        for attempt in Array(active.values) + Array(background.values) {
            attempt.abortReason = "canceled"
            attempt.abort()
        }
        await gateway.ledger.finishJob(jobId, .obj(["state": "canceled"]))
        finish(.failure(ProviderError("已取消", kind: "aborted")))
    }

    private func failJob(_ extraMessage: String) {
        if settled { return }
        settled = true
        for attempt in Array(active.values) + Array(background.values) {
            attempt.abortReason = "job-failed"
            attempt.abort()
        }
        let lines = failures.map { "\($0.providerName)：\($0.message)" }
        let unavailable = unavailableSummary()
        let message = ([extraMessage] + lines + (unavailable.isEmpty ? [] : ["不可用的线路："] + unavailable)).filter { !$0.isEmpty }.joined(separator: "\n")
        Task {
            await gateway.ledger.finishJob(jobId, .obj(["state": "failed", "error": .string(message)]))
            emit(.obj(["type": "job-failed", "message": .string(message)]))
            finish(.failure(GenerateFailure(message: message.isEmpty ? "生图失败" : message)))
        }
    }

    private func failover() {
        if settled { return }
        if !active.isEmpty || !background.isEmpty { return }
        if started >= maxAttempts {
            failJob("已尝试 \(started) 次，仍未成功")
            return
        }
        guard let next = nextProvider() else {
            failJob(tried.isEmpty ? "没有可用的生图线路" : "所有可用线路都试过了")
            return
        }
        launch(next, role: tried.isEmpty ? "primary" : "failover")
    }

    private func launch(_ provider: ImageProvider, role: String) {
        if settled { return }
        let attempt = Attempt(provider: provider, role: role)
        active[attempt.attemptId] = attempt
        activeOrder.append(attempt.attemptId)
        tried.append(provider.id)
        started += 1
        attempt.task = Task { await self.execute(attempt) }
    }

    private func execute(_ attempt: Attempt) async {
        let provider = attempt.provider
        do {
            // 先等线路名额再占全局名额：排队等某条线路的任务不占全局名额，补发和分流不会被堵住
            try await gateway.providerSemaphore(provider).acquire()
            attempt.holdsProvider = true
            try await gateway.globalSemaphore.acquire()
            attempt.holdsGlobal = true
        } catch {
            releaseSlots(attempt)
            await handleFailure(attempt, error)
            return
        }
        if settled {
            releaseSlots(attempt)
            removeActive(attempt)
            return
        }
        attempt.startedAt = gateway.now()
        let sizeSpec = sizeOverrides[provider.id] ?? resolveRequestSize(provider, imageSettings.targetSize)
        attempt.sizeSpec = sizeSpec
        await gateway.ledger.startAttempt(jobId, .obj([
            "attemptId": .string(attempt.attemptId), "providerId": .string(provider.id), "model": .string(provider.model),
            "role": .string(attempt.role), "requestSize": .string(sizeSpec.size),
        ]))
        emit(.obj(["type": "attempt-start", "providerId": .string(provider.id), "providerName": .string(provider.name), "role": .string(attempt.role), "requestSize": .string(sizeSpec.size)]))
        let apiKey = await gateway.secrets.get(SecretIds.imageProvider(provider.id))
        if settled {
            releaseSlots(attempt)
            removeActive(attempt)
            await gateway.ledger.finishAttempt(jobId, attempt.attemptId, .obj(["state": "aborted", "outcome": "not-needed"]))
            return
        }
        if apiKey.isEmpty {
            releaseSlots(attempt)
            await handleFailure(attempt, ProviderError("这条线路还没有填写密钥", kind: "auth"))
            return
        }
        if attempt.cancelRequested {
            releaseSlots(attempt)
            await handleFailure(attempt, ProviderError.aborted())
            return
        }
        if attempt.role != "hedge", hedge.enabled, hedge.maxPerBatch != 0 {
            let delay = gateway.hedgeThresholdMs(provider, hedge)
            attempt.timers.append(Task {
                guard (try? await sleepMs(delay)) != nil else { return }
                await self.onHedgeTimer(attempt)
            })
        }
        let hardMs = (provider.hardTimeoutSec == 0 ? 240 : provider.hardTimeoutSec) * 1000
        attempt.timers.append(Task {
            guard (try? await sleepMs(hardMs)) != nil else { return }
            await self.onHardTimeout(attempt)
        })
        let jobId = self.jobId
        let ledger = gateway.ledger
        do {
            let result = try await runAttempt(
                provider: provider, apiKey: apiKey, prompt: request.prompt, size: sizeSpec.size, quality: imageSettings.quality,
                onTaskId: { taskId in
                    await self.setTaskId(attempt, taskId)
                    await ledger.markTaskId(jobId, attempt.attemptId, taskId)
                    await self.emit(.obj(["type": "attempt-task", "providerId": .string(provider.id), "taskId": .string(taskId)]))
                },
                http: gateway.http
            )
            await handleSuccess(attempt, result)
        } catch {
            await handleFailure(attempt, error)
        }
    }

    private func setTaskId(_ attempt: Attempt, _ taskId: String) { attempt.taskId = taskId }

    private func removeActive(_ attempt: Attempt) {
        active[attempt.attemptId] = nil
        activeOrder.removeAll { $0 == attempt.attemptId }
    }

    private func releaseSlots(_ attempt: Attempt) {
        if attempt.holdsGlobal {
            attempt.holdsGlobal = false
            gateway.globalSemaphore.release()
        }
        if attempt.holdsProvider {
            attempt.holdsProvider = false
            gateway.providerSemaphore(attempt.provider).release()
        }
    }

    private func clearTimers(_ attempt: Attempt) {
        attempt.timers.forEach { $0.cancel() }
        attempt.timers = []
    }

    private func logCall(_ attempt: Attempt, _ fields: JSON) async {
        let durationMs = attempt.startedAt.map { gateway.now() - $0 } ?? 0
        let base = JSON.obj([
            "jobId": .string(jobId), "projectDir": .string(request.projectDir), "projectName": .string(request.projectName), "screenId": .string(request.screenId),
            "providerId": .string(attempt.provider.id), "providerName": .string(attempt.provider.name), "model": .string(attempt.provider.model),
            "role": .string(attempt.role), "requestSize": JSON.maybe(attempt.sizeSpec?.size), "taskId": JSON.maybe(attempt.taskId),
            "durationMs": .number(durationMs),
        ])
        await gateway.callLog.append(base.merging(fields))
    }

    private func handleSuccess(_ attempt: Attempt, _ result: AttemptResult) async {
        clearTimers(attempt)
        releaseSlots(attempt)
        let check = gateway.checkImage(result.bytes)
        guard check.ok, let png = check.png else {
            await handleFailure(attempt, ProviderError(check.reason ?? "图片无效", kind: "invalid-image"))
            return
        }
        removeActive(attempt)
        background[attempt.attemptId] = nil
        let durationMs = gateway.now() - (attempt.startedAt ?? gateway.now())
        await gateway.health.recordSuccess(attempt.provider.id)
        if !settled {
            settled = true
            do {
                try gateway.installFile(request.outputPath, png, request.archiveRoot)
            } catch {
                finish(.failure(error))
                return
            }
            await logCall(attempt, .obj(["ok": true, "kind": "success", "outcome": "winner", "width": JSON.maybe(check.width), "height": JSON.maybe(check.height), "hedged": .bool(hedged)]))
            await gateway.ledger.finishAttempt(jobId, attempt.attemptId, .obj(["state": "completed", "outcome": "winner"]))
            await gateway.ledger.finishJob(jobId, .obj(["state": "done", "winnerAttemptId": .string(attempt.attemptId), "providerId": .string(attempt.provider.id)]))
            for id in activeOrder {
                guard let other = active[id] else { continue }
                if isAsyncProvider(other.provider), other.taskId != nil {
                    // 异步任务已经在中转站跑了，取消也不退钱：继续在后台查，出图后存为备选。
                    removeActive(other)
                    background[other.attemptId] = other
                    clearTimers(other)
                } else {
                    other.abortReason = "loser"
                    other.abort()
                }
            }
            emit(.obj(["type": "winner", "providerId": .string(attempt.provider.id), "providerName": .string(attempt.provider.name), "durationMs": .number(durationMs), "hedged": .bool(hedged)]))
            finish(.success(GenerateResult(
                jobId: jobId, outputPath: request.outputPath, providerId: attempt.provider.id, providerName: attempt.provider.name, model: attempt.provider.model,
                requestSize: attempt.sizeSpec?.size, width: check.width, height: check.height, durationMs: gateway.now() - startedAt,
                hedged: hedged, attempts: started, warnings: check.warnings
            )))
        } else {
            do {
                let file = try gateway.saveAlternate(alternatesDir: request.alternatesDir, screenId: request.screenId, providerId: attempt.provider.id, png: png)
                await logCall(attempt, .obj(["ok": true, "kind": "success", "outcome": "alternate", "width": JSON.maybe(check.width), "height": JSON.maybe(check.height)]))
                await gateway.ledger.finishAttempt(jobId, attempt.attemptId, .obj(["state": "completed", "outcome": "alternate", "alternatePath": .string(file)]))
                emit(.obj(["type": "alternate", "providerId": .string(attempt.provider.id), "providerName": .string(attempt.provider.name), "file": .string(file)]))
            } catch {}
        }
    }

    private func handleFailure(_ attempt: Attempt, _ rawError: Error) async {
        clearTimers(attempt)
        releaseSlots(attempt)
        removeActive(attempt)
        let wasBackground = background.removeValue(forKey: attempt.attemptId) != nil
        var error: ProviderError
        if let providerError = rawError as? ProviderError {
            error = providerError
        } else if isCancellation(rawError) {
            error = ProviderError.aborted()
        } else {
            error = ProviderError(messageOf(rawError), kind: "unknown")
        }
        if error.kind == "aborted", attempt.abortReason == "timeout" {
            error = ProviderError("超过 \(JSON.formatNumber(attempt.provider.hardTimeoutSec == 0 ? 240 : attempt.provider.hardTimeoutSec)) 秒没有出图", kind: "timeout")
        }
        let message = redact(error.message, secretValues)
        if error.kind == "aborted" {
            let outcome = attempt.abortReason ?? "canceled"
            if attempt.startedAt != nil { await logCall(attempt, .obj(["ok": false, "kind": "aborted", "outcome": .string(outcome), "errorMessage": "已取消"])) }
            await gateway.ledger.finishAttempt(jobId, attempt.attemptId, .obj(["state": "aborted", "outcome": .string(outcome)]))
            if !settled, attempt.abortReason != "loser" { failover() }
            return
        }
        await logCall(attempt, .obj(["ok": false, "kind": .string(error.kind), "httpStatus": JSON.maybe(error.status), "errorMessage": .string(message)]))
        await gateway.ledger.finishAttempt(jobId, attempt.attemptId, .obj(["state": "failed", "error": .string(message), "kind": .string(error.kind)]))
        if !["content", "size", "pending"].contains(error.kind) {
            await gateway.health.recordFailure(attempt.provider.id, kind: error.kind, message: message, retryAfterSec: error.retryAfterSec)
        }
        emit(.obj(["type": "attempt-failed", "providerId": .string(attempt.provider.id), "providerName": .string(attempt.provider.name), "kind": .string(error.kind), "message": .string(message)]))
        if settled || (wasBackground && !active.isEmpty) { return }

        if error.kind == "size", sizeOverrides[attempt.provider.id] == nil,
           let fallback = sizeFallback(error, attempt.provider, imageSettings.targetSize, attempt.sizeSpec?.size) {
            // 线路不支持当前尺寸：按报错改用它支持的尺寸立即重试，并记到线路配置里，以后直接用对的尺寸
            sizeOverrides[attempt.provider.id] = fallback.spec
            await gateway.updateProvider(attempt.provider.id, fallback)
            emit(.obj(["type": "size-switched", "providerId": .string(attempt.provider.id), "ratio": .string(fallback.spec.size)]))
            tried.removeAll { $0 == attempt.provider.id }
            started -= 1
            launch(attempt.provider, role: attempt.role)
            return
        }

        failures.append((attempt.provider.id, attempt.provider.name, error.kind, message))
        if error.kind == "server" || error.kind == "network", !retried.contains(attempt.provider.id), started < maxAttempts {
            retried.insert(attempt.provider.id)
            try? await gateway.sleepImpl(gateway.randomDelayMs())
            if settled { return }
            tried.removeAll { $0 == attempt.provider.id }
            launch(attempt.provider, role: "retry")
            return
        }
        failover()
    }

    private func onHedgeTimer(_ attempt: Attempt) async {
        if settled || hedged || active[attempt.attemptId] == nil { return }
        guard let candidate = gateway.pickHedgeProvider(providers, attempt.provider, tried, hedge) else { return }
        if let batchId = request.batchId {
            guard gateway.takeHedgeSlot(batchId, limit: hedge.maxPerBatch) else { return }
        }
        hedged = true
        emit(.obj(["type": "hedge", "fromProviderId": .string(attempt.provider.id), "providerId": .string(candidate.id), "providerName": .string(candidate.name)]))
        launch(candidate, role: "hedge")
    }

    private func onHardTimeout(_ attempt: Attempt) async {
        if settled || active[attempt.attemptId] == nil { return }
        if isAsyncProvider(attempt.provider), let taskId = attempt.taskId {
            // 异步任务超时：不放弃任务号，转后台继续查；同时换下一条线路。
            removeActive(attempt)
            background[attempt.attemptId] = attempt
            releaseSlots(attempt)
            emit(.obj(["type": "attempt-background", "providerId": .string(attempt.provider.id), "taskId": .string(taskId)]))
            failures.append((attempt.provider.id, attempt.provider.name, "timeout", "超时，已转后台继续查询"))
            if active.isEmpty, let next = nextProvider(), started < maxAttempts { launch(next, role: "failover") }
            return
        }
        attempt.abortReason = "timeout"
        attempt.abort()
    }
}
