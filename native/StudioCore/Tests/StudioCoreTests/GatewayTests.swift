import Foundation
import Testing
@testable import StudioCore

struct ProviderSpec {
    var id: String
    var preset = "openai-sync"
    var baseUrl: String
    var model = "gpt-image-2.5"
    var configure: (inout ImageProvider) -> Void = { _ in }
}

final class GatewayContext: @unchecked Sendable {
    let dir: String
    let project: String
    let settings: Locked<Settings>
    let secrets = MemorySecrets()
    let ledger: Ledger
    let health: HealthStore
    let callLog: CallLog
    let gateway: ImageGateway
    let events = EventLog()
    let updates = Locked<[(String, SizeFallback)]>([])

    init(_ specs: [ProviderSpec], network: MockNetwork, image: (inout ImageSettings) -> Void = { _ in }) async throws {
        dir = try FS.makeTempDirectory(prefix: "gw-test-")
        project = Path.join(dir, "proj")
        try FS.mkdirp(Path.join(project, "screens"))
        var initial = Settings()
        image(&initial.image)
        for spec in specs {
            var provider = newProviderFromPreset(spec.preset, id: spec.id, name: spec.id)
            provider.baseUrl = spec.baseUrl
            provider.model = spec.model
            spec.configure(&provider)
            initial.providers.append(provider)
            await secrets.set(SecretIds.imageProvider(provider.id), "sk-test-secret-value")
        }
        settings = Locked(initial)
        ledger = Ledger(dataDir: dir)
        await ledger.initialize()
        health = HealthStore(dataDir: dir)
        callLog = CallLog(dataDir: dir)
        let settings = self.settings
        let updates = self.updates
        gateway = ImageGateway(
            getSettings: { settings.current },
            updateProvider: { id, fallback in
                updates.withLock { $0.append((id, fallback)) }
                settings.withLock { value in
                    if let index = value.providers.firstIndex(where: { $0.id == id }) { fallback.apply(to: &value.providers[index]) }
                }
            },
            secrets: secrets, ledger: ledger, health: health, callLog: callLog, http: network,
            onEvent: events.handler, randomDelayMs: { 20 }
        )
    }

    func request(_ screenId: String, batchId: String? = nil) -> GenerateRequest {
        GenerateRequest(projectDir: project, projectName: "测试项目", screenId: screenId, prompt: "prompt for \(screenId)", outputPath: Path.join(project, "screens", "\(screenId).png"), alternatesDir: Path.join(project, "screens", "alternates"), archiveRoot: Path.join(project, "archive"), batchId: batchId)
    }

    func generateAll(_ ids: [String]) async throws -> [GenerateResult] {
        try await withThrowingTaskGroup(of: (Int, GenerateResult).self) { group in
            for (index, id) in ids.enumerated() { group.addTask { (index, try await self.gateway.generate(self.request(id))) } }
            var results = [GenerateResult?](repeating: nil, count: ids.count)
            for try await (index, result) in group { results[index] = result }
            return results.map { $0! }
        }
    }
}

@Suite("生图网关", .serialized)
struct GatewayTests {
    @Test("尺寸换算：864x1824 在 APIMart 比例里选 1:2，能从 CPA 报错里解析允许比例")
    func sizeMath() {
        #expect(nearestRatio(PixelSize(width: 864, height: 1824), ["1:1", "16:9", "9:16", "2:1", "1:2", "21:9", "9:21"]) == "1:2")
        let message = "size must be auto or one of 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 5:4, 4:5, 21:9; pixel sizes are not supported"
        #expect(parseAllowedRatios(message) == ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "5:4", "4:5", "21:9"])
        #expect(classifyHttpError(400, message).kind == "size")
        var provider = ImageProvider(id: "p", name: "p")
        provider.sizeMode = "ratio"
        provider.ratios = parseAllowedRatios(message)
        #expect(resolveRequestSize(provider, "864x1824") == SizeSpec(mode: "ratio", size: "9:16"))
        provider.sizeMode = "pixel"
        provider.pixelSize = "864x1824"
        #expect(resolveRequestSize(provider, "864x1824") == SizeSpec(mode: "pixel", size: "864x1824"))
    }

    @Test("报错分类：额度冷却能解析剩余秒数")
    func classify() {
        let quota = classifyHttpError(429, "credentials for model gpt-image-2 are cooling down (last error: credential_quota)', 'reset_seconds': 2901")
        #expect(quota.kind == "quota")
        #expect(quota.retryAfterSec == 2901)
        #expect(classifyHttpError(400, "48m20s cooling down quota").retryAfterSec == 2900.0)
        #expect(classifyHttpError(404, "Model \"gpt-image-1\" is not supported by any configured account").kind == "config")
        #expect(classifyHttpError(401, "bad key").kind == "auth")
        #expect(classifyHttpError(502, "bad gateway").kind == "server")
    }

    @Test("同步线路真正并发：4 屏同时发出，而不是一张做完再发下一张")
    func concurrent() async throws {
        let network = MockNetwork()
        let relay = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 400) }
        let ctx = try await GatewayContext([ProviderSpec(id: "cpa", baseUrl: relay.baseUrl) { $0.concurrency = 4 }], network: network) { $0.hedge.enabled = false }
        let started = nowMs()
        let results = try await ctx.generateAll(["screen-01", "screen-02", "screen-03", "screen-04"])
        let elapsed = nowMs() - started
        let arrivals = relay.submits.map(\.arrivedAt)
        #expect(arrivals.max()! - arrivals.min()! < 200, "请求到达时间应几乎相同：\(arrivals)")
        #expect(elapsed < 1200, "4 张并发应约 0.4 秒，实际 \(elapsed)ms")
        for result in results { #expect(FS.exists(result.outputPath)) }
        #expect(ctx.callLog.all().filter { $0["ok"].isTruthy }.count == 4)
    }

    @Test("线路并发上限生效：concurrency=2 时最多同时 2 个请求")
    func concurrencyLimit() async throws {
        let network = MockNetwork()
        let inFlight = Locked((current: 0, peak: 0))
        let relay = MockRelay(network: network) { _, _ in
            inFlight.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) }
            Task { try? await Task.sleep(nanoseconds: 300_000_000); inFlight.withLock { $0.current -= 1 } }
            return RelayPlan(delayMs: 300)
        }
        let ctx = try await GatewayContext([ProviderSpec(id: "cpa", baseUrl: relay.baseUrl) { $0.concurrency = 2 }], network: network) { $0.hedge.enabled = false }
        _ = try await ctx.generateAll(["screen-01", "screen-02", "screen-03", "screen-04"])
        #expect(inFlight.current.peak == 2)
    }

    @Test("一屏失败不连累其他屏，失败的屏切到下一条线路")
    func failover() async throws {
        let network = MockNetwork()
        let a = MockRelay(network: network) { _, body in body["prompt"].text.contains("screen-02") ? RelayPlan(status: 500, error: "upstream exploded") : RelayPlan(delayMs: 50) }
        let b = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 50) }
        let ctx = try await GatewayContext([ProviderSpec(id: "a", baseUrl: a.baseUrl), ProviderSpec(id: "b", baseUrl: b.baseUrl)], network: network) { $0.hedge.enabled = false }
        let results = try await ctx.generateAll(["screen-01", "screen-02", "screen-03"])
        #expect(results.map(\.providerId) == ["a", "b", "a"])
        // screen-02 在 A 上 5xx 先同线路重试 1 次，再切到 B
        #expect(a.submits.filter { $0.prompt.contains("screen-02") }.count == 2)
        #expect(b.submits.count == 1)
        #expect(a.submits.filter { !$0.prompt.contains("screen-02") }.count == 2, "其他屏不重新购买")
    }

    @Test("超时补发：慢线路超过补发线后补发到另一条线路，先出图的胜出，慢的同步请求被取消")
    func hedge() async throws {
        let network = MockNetwork()
        let slow = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 3000) }
        let fast = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 100) }
        let ctx = try await GatewayContext([
            ProviderSpec(id: "slow", baseUrl: slow.baseUrl) { $0.hedgeDefaultSec = 0.3; $0.modelGroup = "gpt-image-2.5" },
            ProviderSpec(id: "fast", baseUrl: fast.baseUrl) { $0.modelGroup = "gpt-image-2.5" },
        ], network: network) { $0.hedge = { var h = HedgeSettings(); h.enabled = true; h.minSec = 0.3; h.maxSec = 1; h.maxPerBatch = 3; return h }() }
        let started = nowMs()
        let result = try await ctx.gateway.generate(ctx.request("screen-01", batchId: "b1"))
        #expect(result.providerId == "fast")
        #expect(result.hedged)
        #expect(nowMs() - started < 1500)
        #expect(await waitUntil(timeout: 2) { slow.submits.first?.aborted == true }, "慢的同步请求应被取消")
        #expect(ctx.events.all.contains { $0["type"]?.string == "hedge" })
    }

    @Test("补发不跨模型（默认）：只有不同模型的线路时不补发")
    func hedgeSameModelOnly() async throws {
        let network = MockNetwork()
        let slow = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 900) }
        let other = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 50) }
        let ctx = try await GatewayContext([
            ProviderSpec(id: "slow", baseUrl: slow.baseUrl, model: "gpt-image-2") { $0.hedgeDefaultSec = 0.2 },
            ProviderSpec(id: "other", baseUrl: other.baseUrl, model: "gpt-image-2.5"),
        ], network: network) { $0.hedge.enabled = true; $0.hedge.minSec = 0.2; $0.hedge.maxSec = 1; $0.hedge.allowCrossModel = false }
        let result = try await ctx.gateway.generate(ctx.request("screen-01"))
        #expect(result.providerId == "slow")
        #expect(other.submits.isEmpty)
    }

    @Test("异步线路作为补发输家：不取消，后台查完存为备选图")
    func asyncLoserBecomesAlternate() async throws {
        pollingIntervalOverride.withLock { $0 = 100 }
        defer { pollingIntervalOverride.withLock { $0 = nil } }
        let network = MockNetwork()
        let asyncRelay = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 20, async: true, readyAfterMs: 1200) }
        let syncRelay = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 100) }
        let ctx = try await GatewayContext([
            ProviderSpec(id: "apimart", preset: "apimart-async", baseUrl: asyncRelay.baseUrl) { $0.hedgeDefaultSec = 0.3; $0.modelGroup = "2.5"; $0.mapping = nil },
            ProviderSpec(id: "cpa", baseUrl: syncRelay.baseUrl) { $0.modelGroup = "2.5" },
        ], network: network) { $0.hedge.enabled = true; $0.hedge.minSec = 0.3; $0.hedge.maxSec = 1 }
        let result = try await ctx.gateway.generate(ctx.request("screen-01"))
        #expect(result.providerId == "cpa")
        #expect(asyncRelay.submits.first?.size == "1:2", "APIMart 按比例发送")
        let altDir = Path.join(ctx.project, "screens", "alternates", "screen-01")
        #expect(await waitUntil(timeout: 4) { (FS.list(altDir) ?? []).count == 1 })
        #expect(await waitUntil(timeout: 1) { ctx.events.all.contains { $0["type"]?.string == "alternate" } })
    }

    @Test("额度冷却：429 后这条线路进入冷却，后续任务直接跳过它")
    func quotaCooldown() async throws {
        let network = MockNetwork()
        let quota = MockRelay(network: network) { _, _ in RelayPlan(status: 429, error: "credential_quota cooling down, reset_seconds: 600") }
        let backup = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 30) }
        let ctx = try await GatewayContext([ProviderSpec(id: "q", baseUrl: quota.baseUrl), ProviderSpec(id: "b", baseUrl: backup.baseUrl)], network: network) { $0.hedge.enabled = false }
        let first = try await ctx.gateway.generate(ctx.request("screen-01"))
        #expect(first.providerId == "b")
        #expect(ctx.health.unavailableReason("q")?.contains("冷却") == true)
        _ = try await ctx.gateway.generate(ctx.request("screen-02"))
        #expect(quota.submits.count == 1, "冷却期间不再请求")
    }

    @Test("线路不收像素尺寸时，自动改用报错里允许的最接近比例并立即重试")
    func ratioFallback() async throws {
        let network = MockNetwork()
        let relay = MockRelay(network: network) { _, body in
            body["size"].text.contains("x") ? RelayPlan(status: 400, error: "invalid size: must be auto or one of 1:1, 16:9, 9:16, 1:2, 2:1; pixel sizes are not supported") : RelayPlan(delayMs: 30)
        }
        let ctx = try await GatewayContext([ProviderSpec(id: "cpa", baseUrl: relay.baseUrl)], network: network) { $0.hedge.enabled = false }
        let result = try await ctx.gateway.generate(ctx.request("screen-01"))
        #expect(result.requestSize == "1:2")
        #expect(relay.submits.map(\.size) == ["864x1824", "1:2"])
        #expect(ctx.updates.current.first?.1.sizeMode == "ratio")
        #expect(ctx.health.unavailableReason("cpa") == nil, "尺寸问题不算线路故障")
    }

    @Test("空白图判为无效并切换线路")
    func blankImage() async throws {
        let network = MockNetwork()
        let blank = MockRelay(network: network) { _, _ in RelayPlan(blank: true) }
        let good = MockRelay(network: network)
        let ctx = try await GatewayContext([ProviderSpec(id: "blank", baseUrl: blank.baseUrl), ProviderSpec(id: "good", baseUrl: good.baseUrl)], network: network) { $0.hedge.enabled = false }
        let result = try await ctx.gateway.generate(ctx.request("screen-01"))
        #expect(result.providerId == "good")
    }

    @Test("替换截图前先归档旧图")
    func archiveOld() async throws {
        let network = MockNetwork()
        let relay = MockRelay(network: network)
        let ctx = try await GatewayContext([ProviderSpec(id: "cpa", baseUrl: relay.baseUrl)], network: network) { $0.hedge.enabled = false }
        _ = try await ctx.gateway.generate(ctx.request("screen-01"))
        _ = try await ctx.gateway.generate(ctx.request("screen-01"))
        #expect((FS.list(Path.join(ctx.project, "archive")) ?? []).count == 1)
    }

    @Test("重启续查：账本里有任务号的异步任务继续查询，不重复提交")
    func resume() async throws {
        pollingIntervalOverride.withLock { $0 = 100 }
        defer { pollingIntervalOverride.withLock { $0 = nil } }
        let network = MockNetwork()
        let relay = MockRelay(network: network) { _, _ in RelayPlan(async: true, readyAfterMs: 300) }
        let ctx = try await GatewayContext([ProviderSpec(id: "apimart", preset: "apimart-async", baseUrl: relay.baseUrl)], network: network) { $0.hedge.enabled = false }
        // 模拟上次运行：已提交并拿到任务号，然后软件退出
        relay.tasks.withLock { $0["task_prev"] = MockRelay.TaskInfo(readyAt: nowMs() + 200, failTask: false, seed: 9) }
        let request = ctx.request("screen-03")
        await ctx.ledger.createJob(.obj(["jobId": "j1", "projectDir": .string(request.projectDir), "screenId": "screen-03", "outputPath": .string(request.outputPath), "alternatesDir": .string(request.alternatesDir), "archiveRoot": .string(request.archiveRoot), "prompt": "p"]))
        await ctx.ledger.startAttempt("j1", .obj(["attemptId": "a1", "providerId": "apimart", "role": "primary"]))
        await ctx.ledger.markTaskId("j1", "a1", "task_prev")
        let ledger2 = Ledger(dataDir: ctx.dir)
        await ledger2.initialize()
        let settings = ctx.settings
        let gateway2 = ImageGateway(getSettings: { settings.current }, secrets: ctx.secrets, ledger: ledger2, health: ctx.health, callLog: ctx.callLog, http: network)
        let resumed = await gateway2.resumePending()
        #expect(resumed == ["j1"])
        let viaGenerate = try await gateway2.generate(request)
        #expect(viaGenerate.resumed, "同一屏正在续查时，不会重新提交")
        #expect(FS.exists(request.outputPath))
        #expect(relay.submits.isEmpty)
        #expect(ledger2.get("j1")?["state"]?.string == "done")
    }

    @Test("启动时还在「提交中」的尝试标为提交结果未知")
    func unknownSubmission() async throws {
        let dir = try FS.makeTempDirectory(prefix: "ledger-")
        let ledger = Ledger(dataDir: dir)
        await ledger.initialize()
        await ledger.createJob(.obj(["jobId": "j", "projectDir": "/p", "screenId": "screen-01"]))
        await ledger.startAttempt("j", .obj(["attemptId": "a", "providerId": "x"]))
        let reopened = Ledger(dataDir: dir)
        await reopened.initialize()
        let job = reopened.get("j")
        #expect(job?["attempts"]?[0]?["state"]?.string == "unknown")
        #expect(job?["state"]?.string == "needs-attention")
    }

    @Test("所有线路都失败时报出每条线路的原因，日志里不出现密钥")
    func allFail() async throws {
        let network = MockNetwork()
        let bad = MockRelay(network: network) { _, _ in RelayPlan(status: 401, error: "invalid key sk-test-secret-value") }
        let ctx = try await GatewayContext([ProviderSpec(id: "bad", baseUrl: bad.baseUrl)], network: network) { $0.hedge.enabled = false }
        do {
            _ = try await ctx.gateway.generate(ctx.request("screen-01"))
            Issue.record("应该失败")
        } catch {
            #expect(messageOf(error).contains("bad"))
            #expect(!messageOf(error).contains("sk-test-secret-value"))
        }
        #expect(!(try FS.readText(ctx.callLog.file)).contains("sk-test-secret-value"))
        #expect(ctx.health.unavailableReason("bad")?.contains("配置错误") == true)
    }

    @Test("首选线路满载时分流到同画风组的空闲线路")
    func spillover() async throws {
        let network = MockNetwork()
        let a = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 400) }
        let b = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 400) }
        let ctx = try await GatewayContext([
            ProviderSpec(id: "a", baseUrl: a.baseUrl) { $0.concurrency = 1; $0.modelGroup = "g" },
            ProviderSpec(id: "b", baseUrl: b.baseUrl) { $0.concurrency = 3; $0.modelGroup = "g" },
        ], network: network) { $0.hedge.enabled = false }
        let started = nowMs()
        let results = try await ctx.generateAll(["screen-01", "screen-02", "screen-03", "screen-04"])
        #expect(results.filter { $0.providerId == "a" }.count == 1)
        #expect(results.filter { $0.providerId == "b" }.count == 3)
        #expect(nowMs() - started < 900, "4 张同时出图，而不是在 A 上排队")
    }

    @Test("关闭分流时按顺序排队，不用后面的线路")
    func noSpillover() async throws {
        let network = MockNetwork()
        let a = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 100) }
        let b = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 100) }
        let ctx = try await GatewayContext([
            ProviderSpec(id: "a", baseUrl: a.baseUrl) { $0.concurrency = 1; $0.modelGroup = "g" },
            ProviderSpec(id: "b", baseUrl: b.baseUrl) { $0.modelGroup = "g" },
        ], network: network) { $0.spillover = false; $0.hedge.enabled = false }
        let results = try await ctx.generateAll(["screen-01", "screen-02", "screen-03"])
        #expect(results.allSatisfy { $0.providerId == "a" })
    }

    @Test("线路只收固定像素尺寸时，按报错改用宽高比最接近的那个")
    func pixelFallback() async throws {
        let network = MockNetwork()
        let relay = MockRelay(network: network) { _, body in
            body["size"].text == "864x1824" ? RelayPlan(status: 400, error: "Invalid value: '864x1824'. Supported values are: '1024x1024', '1024x1536', '1536x1024', and 'auto'.") : RelayPlan(delayMs: 20)
        }
        let ctx = try await GatewayContext([ProviderSpec(id: "openai", baseUrl: relay.baseUrl)], network: network) { $0.hedge.enabled = false }
        let result = try await ctx.gateway.generate(ctx.request("screen-01"))
        #expect(result.requestSize == "1024x1536")
        let update = ctx.updates.current.first?.1
        #expect(update?.sizeMode == "pixel")
        #expect(update?.pixelSize == "1024x1536")
    }

    @Test("补发线样本包含被补发取消的慢请求，避免补发线越算越低")
    func hedgeSamples() async throws {
        let log = CallLog(dataDir: try FS.makeTempDirectory(prefix: "calllog-"))
        for _ in 0..<5 { await log.append(["providerId": "p", "ok": true, "kind": "success", "durationMs": 10_000]) }
        await log.append(["providerId": "p", "ok": false, "kind": "aborted", "outcome": "loser", "durationMs": 90_000])
        await log.append(["providerId": "p", "ok": false, "kind": "aborted", "outcome": "canceled", "durationMs": 5_000])
        #expect(log.recentSuccessSeconds("p").sorted() == [10, 10, 10, 10, 10, 90])
    }

    @Test("计费参数：每种线路都把质量设置（默认 low）发出去，APIMart 不再发 resolution")
    func billingParams() async throws {
        pollingIntervalOverride.withLock { $0 = 50 }
        defer { pollingIntervalOverride.withLock { $0 = nil } }
        let network = MockNetwork()
        let syncRelay = MockRelay(network: network)
        let asyncRelay = MockRelay(network: network) { _, _ in RelayPlan(async: true, readyAfterMs: 50) }
        let ctx = try await GatewayContext([
            ProviderSpec(id: "apimart", preset: "apimart-async", baseUrl: asyncRelay.baseUrl, model: "gpt-image-2.5-flare") { $0.mapping = nil },
            ProviderSpec(id: "cpa", baseUrl: syncRelay.baseUrl),
        ], network: network) { $0.hedge.enabled = false }
        _ = try await ctx.gateway.generate(ctx.request("screen-01"))
        ctx.settings.withLock { $0.providers.reverse() }
        _ = try await ctx.gateway.generate(ctx.request("screen-02"))
        let apimart = asyncRelay.submits.first!.body
        #expect(apimart["quality"]?.string == "low")
        #expect(apimart["resolution"] == nil)
        #expect(apimart.fields.keys.sorted() == ["model", "n", "prompt", "quality", "size"])
        #expect(syncRelay.submits.first?.body["quality"]?.string == "low")
    }

    @Test("取消：取消这一屏时所有尝试一起停下")
    func cancel() async throws {
        let network = MockNetwork()
        let relay = MockRelay(network: network) { _, _ in RelayPlan(delayMs: 5000) }
        let ctx = try await GatewayContext([ProviderSpec(id: "cpa", baseUrl: relay.baseUrl)], network: network) { $0.hedge.enabled = false }
        let task = Task { try await ctx.gateway.generate(ctx.request("screen-01")) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("应该被取消")
        } catch {
            #expect((error as? ProviderError)?.kind == "aborted")
        }
        #expect(await waitUntil(timeout: 2) { relay.submits.first?.aborted == true })
    }
}
