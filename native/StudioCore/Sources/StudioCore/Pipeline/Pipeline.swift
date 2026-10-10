import Foundation

/// 固定流水线：规划 → 提示词 → 生图 → 验收 → 文案 → 设计说明 → 回执 → 构建。
/// 每一步记录输入哈希，只重跑受影响的步骤（逻辑和 Electron 版 runner.mjs 逐条对应）。
public final class Pipeline: @unchecked Sendable {
    let settingsStore: SettingsStore
    let secrets: SecretStore
    let gateway: ImageGateway
    let projectStore: ProjectStore
    let llmLog: CallLog
    let emit: @Sendable (JSON) -> Void
    let http: HTTPClient
    let visionImage: @Sendable (String) throws -> String
    let appVersion: String
    let statsFile: String?
    let llmRetryDelay: @Sendable (Double) async throws -> Void

    final class RunHandle: @unchecked Sendable {
        var task: Task<RunResult, Never>?
        let cancellable: Bool
        init(cancellable: Bool) { self.cancellable = cancellable }
        func cancel() { if cancellable { task?.cancel() } }
    }

    let running = Locked<[String: RunHandle]>([:])
    let progress = Locked<[String: JSON]>([:])
    let statsCache = Locked<JSON?>(nil)
    let applying = Locked<Set<String>>([])

    public init(settingsStore: SettingsStore, secrets: SecretStore, gateway: ImageGateway, projectStore: ProjectStore, llmLog: CallLog, emit: @escaping @Sendable (JSON) -> Void = { _ in }, http: HTTPClient, visionImage: @escaping @Sendable (String) throws -> String = visionDataUrl, appVersion: String = "", statsFile: String? = nil, llmRetryDelay: @escaping @Sendable (Double) async throws -> Void = { try await sleepMs($0) }) {
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.gateway = gateway
        self.projectStore = projectStore
        self.llmLog = llmLog
        self.emit = emit
        self.http = http
        self.visionImage = visionImage
        self.appVersion = appVersion
        self.statsFile = statsFile
        self.llmRetryDelay = llmRetryDelay
    }

    // MARK: - 实时进度（只在内存里，运行结束就清掉）

    func setProgress(_ dir: String, _ patch: JSON) {
        let next: JSON? = progress.withLock { table in
            guard let current = table[dir] else { return nil }
            var next = current.merging(patch)
            next["updatedAt"] = .number(nowMs())
            table[dir] = next
            return next
        }
        if let next { emit(.obj(["type": "progress", "projectDir": .string(dir), "progress": next])) }
    }

    func setScreenProgress(_ dir: String, _ id: String, _ patch: JSON) {
        let next: JSON? = progress.withLock { table in
            guard var current = table[dir] else { return nil }
            var screens = current["screens"] ?? .emptyObject
            screens[id] = (screens[id] ?? .emptyObject).merging(patch)
            current["screens"] = screens
            current["updatedAt"] = .number(nowMs())
            table[dir] = current
            return current
        }
        if let next { emit(.obj(["type": "progress", "projectDir": .string(dir), "progress": next])) }
    }

    func progressScreens(_ dir: String) -> JSON { progress.withLock { $0[dir]?["screens"] } ?? .emptyObject }
    func doneSteps(_ dir: String) -> [JSON] { progress.withLock { $0[dir]?["doneSteps"]?.array } ?? [] }

    /// 生图网关的事件（哪条线路、有没有补发）同步到进度里。
    public func onImageEvent(_ event: JSON) {
        guard let dir = event["projectDir"]?.string, let id = event["screenId"]?.string, progress.withLock({ $0[dir] != nil }) else { return }
        let type = event["type"]?.string
        if type == "attempt-start" {
            let attempts = (progressScreens(dir)[id]?["attempts"]?.number ?? 0) + 1
            var patch: JSON = ["provider": event["providerName"] ?? .null, "attempts": .number(attempts)]
            if event["role"]?.string == "hedge" { patch["hedged"] = true }
            setScreenProgress(dir, id, patch)
        } else if type == "hedge" {
            setScreenProgress(dir, id, ["hedged": true])
        }
    }

    public func getProgress(_ dir: String) -> JSON? { progress.withLock { $0[dir] } }
    public func isRunning(_ dir: String) -> Bool { running.withLock { $0[dir] != nil } }
    public func runningProjects() -> [String] { running.withLock { Array($0.keys) } }

    // MARK: - 各步骤历史用时（估算剩余时间用）

    func loadStats() -> JSON {
        statsCache.withLock { cache in
            if let cache { return cache }
            let loaded = statsFile.flatMap { FS.readJSONQuiet($0) }.flatMap { $0.isObject ? $0 : nil } ?? .emptyObject
            cache = loaded
            return loaded
        }
    }

    func addStepSamples(_ samples: [String: Double]) {
        _ = loadStats()
        let snapshot: JSON = statsCache.withLock { cache in
            var stats = cache ?? .emptyObject
            for step in PIPELINE_STEPS {
                guard let ms = samples[step], ms > 300 else { continue }
                let list = (stats[step]?.array ?? []) + [.number(jsRound(ms))]
                stats[step] = .array(Array(list.suffix(30)))
            }
            cache = stats
            return stats
        }
        if let statsFile { try? FS.writeJSONAtomic(statsFile, snapshot) }
    }

    public func stepEstimates() -> [String: Double] {
        var result: [String: Double] = [:]
        for (step, samples) in loadStats().fields {
            let values = samples.items.compactMap(\.number)
            if values.count < 2 { continue }
            result[step] = values.sorted()[values.count / 2]
        }
        return result
    }

    // MARK: - 大模型

    public func resolveLlm(_ step: String) async -> (vendor: LlmVendor, model: String, apiKey: String)? {
        guard let settings = try? await settingsStore.get(), let assignment = settings.llm.assignment(step), !assignment.vendorId.isEmpty, !assignment.model.isEmpty,
              let vendor = settings.llm.vendors.first(where: { $0.id == assignment.vendorId }) else { return nil }
        let apiKey = await secrets.get(SecretIds.llmVendor(vendor.id))
        if apiKey.isEmpty { return nil }
        return (vendor, assignment.model, apiKey)
    }

    func callLlm(_ step: String, _ dir: String, _ request: ChatJsonRequest) async throws -> JSON {
        guard let llm = await resolveLlm(step) else {
            throw StudioError("还没有给「\(LLM_STEPS[step]?.label ?? step)」配置大模型（大模型页面里选择厂商和模型，并填写密钥）")
        }
        let started = nowMs()
        do {
            let result = try await chatJson(vendor: llm.vendor, apiKey: llm.apiKey, model: llm.model, request: request, http: http, retryDelay: llmRetryDelay)
            await llmLog.append(.obj(["step": .string(step), "projectDir": .string(dir), "vendorId": .string(llm.vendor.id), "model": .string(llm.model), "ok": true, "durationMs": .number(nowMs() - started)]))
            let at = isoNow()
            let vendor = llm.vendor
            let model = llm.model
            try await updateRecord(dir) { record in
                record["llm"]?[step] = .obj(["vendor": .string(vendor.name), "baseUrl": .string(vendor.baseUrl), "model": .string(model), "at": .string(at)])
                record.append("history", .obj(["at": .string(at), "event": "llm", "step": .string(step), "vendor": .string(vendor.name), "model": .string(model)]))
            }
            return result
        } catch {
            await llmLog.append(.obj(["step": .string(step), "projectDir": .string(dir), "vendorId": .string(llm.vendor.id), "model": .string(llm.model), "ok": false, "durationMs": .number(nowMs() - started), "errorMessage": .string(messageOf(error).jsSlice(0, 300))]))
            throw error
        }
    }

    // MARK: - 状态

    @discardableResult
    func update(_ dir: String, _ mutate: @escaping @Sendable (inout JSON) throws -> Void) async throws -> JSON {
        let state = try await projectStore.update(dir, mutate)
        emit(.obj(["type": "project", "projectDir": .string(dir), "status": state["status"] ?? .null, "steps": state["steps"] ?? .null]))
        return state
    }

    func log(_ dir: String, _ message: String, _ level: String = "info") async throws {
        try await update(dir) { appendLog(&$0, message, level) }
        emit(.obj(["type": "log", "projectDir": .string(dir), "message": .string(message), "level": .string(level)]))
    }

    func readState(_ dir: String) throws -> JSON {
        guard let state = try projectStore.read(dir) else { throw StudioError("项目状态不存在：\(dir)") }
        return state
    }

    func platformOf(_ state: JSON, _ settings: Settings) -> String {
        let platform = state["request"]?["platform"].text ?? ""
        return platform.isEmpty ? settings.pipeline.platform : platform
    }

    func softwareName(_ state: JSON) -> String { state["request"]?["softwareName"]?.jsString ?? "" }

    func extraTokens(_ state: JSON) -> [String] { state["request"]?["extraBrandTokens"].items.map(\.jsString) ?? [] }

    // MARK: - S1 规划

    func stepPlan(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let request = ctx.state["request"] ?? .emptyObject
        let settings = ctx.settings
        let platform = platformOf(ctx.state, settings)
        let screenCount = request["screenCount"].truthyValue?.int
        let name = softwareName(ctx.state)
        try await log(dir, "正在让大模型规划界面…")
        let plan = try await callLlm("plan", dir, ChatJsonRequest(
            system: PLAN_SYSTEM,
            user: planUserPrompt(softwareName: name, screenCount: screenCount, emphasis: request["emphasis"].text, notes: request["notes"].text, platform: platform),
            schema: PLAN_SCHEMA,
            check: { planCheck($0, softwareName: name, screenCount: screenCount) },
            temperature: 0.8,
            maxTokens: 8000
        ))
        let paths = projectPaths(dir)
        let tokens = forbiddenBrandTokens(name, extraTokens(ctx.state))
        let screens = plan["screens"].items
        let profile = plan["profile"] ?? .emptyObject
        try FS.writeJSONAtomic(paths.profile, .obj([
            "softwareName": .string(name), "versionPolicy": request["versionPolicy"], "domain": profile["domain"], "platform": .string(platform),
            "targetUser": profile["targetUser"], "coreFlow": profile["coreFlow"],
            "screenshotPolicy": "UI 内严禁出现软件名称、App 名称、版本号、名称型 logo 或 wordmark",
        ]))
        let features: [JSON] = plan["features"].items.enumerated().map { index, feature in
            .obj(["id": .string("feature-\(String(index + 1).padStart(2))"), "screenId": feature["screenId"], "name": feature["name"], "tier": feature["tier"].or("core"), "mandatory": true, "screenshot": true])
        }
        try FS.writeJSONAtomic(paths.featureMap, .obj(["softwareName": .string(name), "screenshotCount": .number(Double(screens.count)), "coverageReason": plan["coverageReason"], "features": .array(features)]))
        let planScreens: [JSON] = screens.map { screen in
            var next = screen
            next["image"] = .string("screens/\(screen["id"]?.jsString ?? "undefined").png")
            return next
        }
        try FS.writeJSONAtomic(paths.screenPlan, .obj(["softwareName": .string(name), "screenshotCount": .number(Double(screens.count)), "targetSize": .string(settings.image.targetSize), "imageRoute": "image-gateway", "screens": .array(planScreens)]))
        let ui = plan["uiContract"] ?? .emptyObject
        let nav = ui["navigation"].or(.emptyObject)
        var uiContract = JSONObject()
        uiContract["platform"] = .string(platform)
        uiContract["viewport"] = .obj(["orientation": "portrait", "requestedSize": .string(settings.image.targetSize), "safeAreas": "native"])
        uiContract["visualStyle"] = ui["visualStyle"]
        uiContract["visual"] = .obj(["palette": ui["palette"], "typography": ui["typography"], "radius": ui["radius"], "shadow": ui["shadow"], "density": ui["density"]])
        uiContract["palette"] = ui["palette"]
        uiContract["typography"] = ui["typography"]
        uiContract["radius"] = ui["radius"]
        uiContract["shadow"] = ui["shadow"]
        uiContract["density"] = ui["density"]
        uiContract["statusBarPolicy"] = .obj(["mode": "consistent", "battery": "same style across screens"])
        uiContract["navigation"] = .obj(["type": nav["type"], "labels": nav["labels"].or([]), "order": nav["labels"].or([]), "iconSemantics": nav["iconSemantics"].or([])])
        uiContract["forbiddenVisibleBranding"] = JSON(tokens + ["App name", "name-bearing logo", "wordmark"])
        try FS.writeJSONAtomic(paths.uiContract, .object(uiContract))
        // 重新规划后界面都变了：人工改过的提示词和说明不再对应，清掉标记让它们按新规划重写
        try await update(dir) { draft in
            for (id, screen) in draft["screens"].fields {
                draft["screens"]?[id] = screen.merging(["promptEdited": false, "textEdited": false])
            }
            draft["overviewEdited"] = false
        }
        try await log(dir, "规划完成：\(screens.count) 屏（\(jsJoin(screens.map { $0["title"] ?? .null }, "、"))）")
        return StepOutcome(status: ctx.reviewPlan ? "review" : "done", screenCountReason: plan["coverageReason"]?.jsString)
    }

    // MARK: - S2 提示词

    func stepPrompts(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = ctx.state
        let settings = ctx.settings
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let paths = projectPaths(dir)
        try FS.mkdirp(paths.prompts)
        let platform = platformOf(state, settings)
        let ui = normalizedUi(plan)
        let name = softwareName(state)
        var screenStates = JSONObject()
        for screen in plan["screens"].items {
            let id = screen["id"]?.jsString ?? ""
            let rowHash = planRowHash(screen, ui, platform, settings.image.targetSize)
            let previous = state["screens"]?[id] ?? .emptyObject
            let file = paths.promptFile(id)
            // JS 的 `a && b && c`：promptEdited 没设置时保持「没有这个字段」
            var keepValue: JSON?
            if let edited = previous["promptEdited"] {
                keepValue = edited.truthy ? .bool(previous["planRowHash"]?.string == rowHash && FS.exists(file)) : edited
            }
            let keep = keepValue.isTruthy
            var prompt: String
            var promptHash: String
            if keep {
                // 人工改过或历史项目的提示词：原样保留，只把旧软件名换成新名字。
                // 内容没变时沿用原来的哈希，不会因此重新生图。
                let current = try FS.readText(file)
                let oldName = state["promptsName"]?.string ?? ""
                prompt = !oldName.isEmpty && oldName != name ? current.replacingAll(oldName, with: name) : current
                promptHash = prompt == current && previous["promptHash"].isTruthy ? previous["promptHash"]!.jsString : promptIdentity(prompt, name)
            } else {
                prompt = composeScreenPrompt(softwareName: name, platform: platform, targetSize: settings.image.targetSize, ui: ui, screen: screen)
                promptHash = promptIdentity(prompt, name)
            }
            if FS.readTextIfExists(file) != prompt { try FS.writeAtomic(file, prompt) }
            screenStates[id] = .obj(["planRowHash": .string(rowHash), "promptHash": .string(promptHash), "promptEdited": keepValue])
        }
        let patches = screenStates
        try await update(dir) { draft in
            var screens = draft["screens"].fields
            for (id, patch) in patches {
                var merged = (screens[id] ?? .emptyObject).merging(patch)
                if patch["promptEdited"] == nil { merged["promptEdited"] = nil }
                screens[id] = merged
            }
            for id in screens.keys where patches[id] == nil { screens[id] = nil }
            draft["screens"] = .object(screens)
            draft["promptsName"] = draft["request"]?["softwareName"]
        }
        return StepOutcome(status: "done")
    }

    func generateScreen(_ ctx: StepContext, _ id: String, reason: String? = nil) async throws -> GenerateResult {
        let dir = ctx.projectDir
        let state = ctx.state
        let paths = projectPaths(dir)
        let name = softwareName(state)
        var prompt: String
        if FS.exists(paths.promptFile(id)) {
            prompt = try FS.readText(paths.promptFile(id))
        } else {
            // 历史项目缺这一屏的标准提示词：按规划现拼一份再生成
            let settings = ctx.settings
            guard let plan = try readPlan(dir), let screen = plan["screens"].items.first(where: { $0["id"]?.string == id }) else {
                throw StudioError("\(id) 没有提示词，规划里也找不到这一屏")
            }
            let platform = platformOf(state, settings)
            let ui = normalizedUi(plan)
            prompt = composeScreenPrompt(softwareName: name, platform: platform, targetSize: settings.image.targetSize, ui: ui, screen: screen)
            try FS.mkdirp(paths.prompts)
            try FS.writeAtomic(paths.promptFile(id), prompt)
            let patch: JSON = ["promptHash": .string(promptIdentity(prompt, name)), "planRowHash": .string(planRowHash(screen, ui, platform, settings.image.targetSize)), "promptEdited": false]
            try await update(dir) { draft in draft.mergeChild("screens", id, patch) }
        }
        emit(.obj(["type": "screen", "projectDir": .string(dir), "screenId": .string(id), "status": "generating", "reason": JSON.maybe(reason)]))
        setScreenProgress(dir, id, ["status": .string(reason != nil ? "regenerating" : "generating"), "startedAt": .number(nowMs()), "finishedAt": nil, "provider": nil, "hedged": false])
        let result = try await gateway.generate(GenerateRequest(
            projectDir: dir, projectName: name, screenId: id, prompt: prompt, outputPath: paths.screenFile(id),
            alternatesDir: paths.alternates, archiveRoot: paths.archive, batchId: ctx.batchId
        ))
        let imageSha = try sha256File(paths.screenFile(id))
        let promptHash = promptIdentity(prompt, name)
        let generatedAt = isoNow()
        let durationSec = Int(jsRound(result.durationMs / 1000))
        try await update(dir) { draft in
            let current = draft["screens"]?[id] ?? .emptyObject
            draft["screens"]?[id] = current.merging(.obj([
                "imagePromptHash": .string(promptHash), "imageSha": .string(imageSha), "providerId": .string(result.providerId),
                "providerName": .string(result.providerName), "model": .string(result.model), "requestSize": JSON.maybe(result.requestSize),
                "width": JSON.maybe(result.width), "height": JSON.maybe(result.height), "hedged": .bool(result.hedged),
                "imageWarnings": JSON(result.warnings), "generatedAt": .string(generatedAt), "gate": .null,
                // 截图换了，这一屏的说明要按新截图重写（人工改过的会保留并提醒）
                "contentStale": true,
            ]))
            appendLog(&draft, "\(id) 已生成（\(result.providerName.isEmpty ? result.providerId : result.providerName)\(result.hedged ? "，触发了超时补发" : "")，\(durationSec) 秒）")
        }
        let promptSha = sha256Hex(prompt)
        try await updateRecord(dir) { record in
            let entry: JSON = .obj([
                "source": "generated", "providerId": .string(result.providerId), "providerName": .string(result.providerName), "model": .string(result.model),
                "requestSize": JSON.maybe(result.requestSize), "width": JSON.maybe(result.width), "height": JSON.maybe(result.height), "hedged": .bool(result.hedged),
                "attempts": .number(Double(result.attempts)), "resumed": .bool(result.resumed), "generatedAt": .string(generatedAt),
                "imageSha256": .string(imageSha), "promptSha256": .string(promptSha), "reason": JSON.orNull(reason),
            ])
            record["screens"]?[id] = entry
            record.append("history", JSON.obj(["at": .string(generatedAt), "event": "screen-generated", "screenId": .string(id)]).merging(entry))
        }
        emit(.obj(["type": "screen", "projectDir": .string(dir), "screenId": .string(id), "status": "generated"]))
        setScreenProgress(dir, id, ["status": "generated", "finishedAt": .number(nowMs()), "provider": .string(result.providerName.isEmpty ? result.providerId : result.providerName), "hedged": .bool(result.hedged)])
        return result
    }

    // MARK: - S3 生图

    func stepImages(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = try readState(dir)
        let paths = projectPaths(dir)
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        var needed: [String] = []
        let planScreens = plan["screens"].items
        for screen in planScreens {
            let id = screen["id"]?.jsString ?? ""
            let current = state["screens"]?[id] ?? .emptyObject
            let forced = ctx.forceScreens?.contains(id) ?? false
            let imagePromptHash = current["imagePromptHash"]
            if forced || !FS.exists(paths.screenFile(id))
                || (imagePromptHash.isTruthy && imagePromptHash != current["promptHash"])
                || (!imagePromptHash.isTruthy && state["origin"]?.string != "imported") {
                needed.append(id)
            }
        }
        if needed.isEmpty { return StepOutcome(status: "done") }
        var screensProgress = JSONObject()
        for screen in planScreens {
            let id = screen["id"]?.jsString ?? ""
            screensProgress[id] = needed.contains(id) ? ["status": "waiting"] : ["status": "kept"]
        }
        setProgress(dir, .obj(["screens": .object(screensProgress)]))
        try await log(dir, "开始生成 \(needed.count) 张截图（同时发出）")
        var screenCtx = ctx
        screenCtx.state = state
        let generationCtx = screenCtx
        let outcomes: [(String, String?)] = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, id) in needed.enumerated() {
                group.addTask {
                    do {
                        _ = try await self.generateScreen(generationCtx, id)
                        return (index, nil)
                    } catch {
                        self.setScreenProgress(dir, id, ["status": "failed", "finishedAt": .number(nowMs()), "error": .string(messageOf(error))])
                        return (index, messageOf(error))
                    }
                }
            }
            var results = [(String, String?)](repeating: ("", nil), count: needed.count)
            for await (index, failure) in group { results[index] = (needed[index], failure) }
            return results
        }
        let failures = outcomes.compactMap { id, message in message.map { (id, $0) } }
        if !failures.isEmpty {
            let messages = uniqued(failures.map(\.1))
            let detail = messages.count == 1 ? "\(failures.map(\.0).joined(separator: "、"))：\(messages[0])" : failures.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
            throw StudioError("\(failures.count) 张截图没有生成成功\(failures.count < needed.count ? "（其余已保存）" : "")：\n\(detail)")
        }
        return StepOutcome(status: "done")
    }

    // MARK: - S4 品牌验收

    func gateOne(_ ctx: StepContext, _ screen: JSON, _ tokens: [String], _ tokensHash: String, _ llmAvailable: Bool) async throws -> JSON {
        let dir = ctx.projectDir
        let paths = projectPaths(dir)
        let limit = ctx.settings.image.gateRegenerateLimit
        let id = screen["id"]?.jsString ?? ""
        var round = 0
        while true {
            let state = try readState(dir)
            let file = paths.screenFile(id)
            let sha = try sha256File(file)
            if let current = state["screens"]?[id]?["gate"], current.isObject, current["sha"]?.string == sha, current["tokensHash"]?.string == tokensHash,
               ["passed", "manual-passed"].contains(current["status"]?.string ?? "") {
                setScreenProgress(dir, id, ["status": "passed"])
                return current
            }
            if !llmAvailable {
                let gate: JSON = .obj(["status": "needs-manual", "sha": .string(sha), "tokensHash": .string(tokensHash), "method": "manual", "checkedAt": .string(isoNow()), "reasons": ["没有配置看图模型，请人工确认截图里没有软件名"]])
                try await update(dir) { draft in draft.mergeChild("screens", id, ["gate": gate]) }
                return gate
            }
            setScreenProgress(dir, id, ["status": "checking"])
            let image = try visionImage(file)
            let result = try await callLlm("gate", dir, ChatJsonRequest(
                system: GATE_SYSTEM,
                user: gateUserPrompt(softwareName: softwareName(state), tokens: tokens, screen: screen),
                images: [image],
                schema: GATE_SCHEMA,
                temperature: 0.1,
                maxTokens: 4000
            ))
            let verdict = judgeGate(result, tokens)
            let checkedAt = isoNow()
            let gate: JSON = .obj([
                "status": .string(verdict.passed ? "passed" : "failed"), "method": "vision", "sha": .string(sha), "tokensHash": .string(tokensHash),
                "reasons": JSON(verdict.reasons), "hits": JSON(verdict.hits), "screenTitle": result["screenTitle"].or(""),
                "visibleText": .array(Array(result["visibleText"].items.prefix(80))), "inventory": result["inventory"],
                "warnings": result["warnings"].or([]), "checkedAt": .string(checkedAt), "rounds": .number(Double(round + 1)),
            ])
            try await update(dir) { draft in
                draft.mergeChild("screens", id, ["gate": gate])
                appendLog(&draft, verdict.passed ? "\(id) 验收通过" : "\(id) 验收不通过：\(verdict.reasons.joined(separator: "；"))", verdict.passed ? "info" : "warn")
            }
            try await updateRecord(dir) { record in
                record["gate"]?[id] = .obj(["status": gate["status"], "method": "vision", "imageSha256": .string(sha), "reasons": gate["reasons"], "checkedAt": .string(checkedAt)])
                record.append("history", .obj(["at": .string(checkedAt), "event": "gate", "screenId": .string(id), "status": gate["status"], "method": "vision", "reasons": gate["reasons"]]))
            }
            setScreenProgress(dir, id, ["status": .string(verdict.passed ? "passed" : round >= limit ? "failed" : "regenerating"), "gateRounds": .number(Double(round + 1))])
            if verdict.passed { return gate }
            // limit = 每屏最多自动重生几次（设置里的数字），用完还不通过就交给人处理
            if round >= limit { return gate }
            var screenCtx = ctx
            screenCtx.state = state
            _ = try await generateScreen(screenCtx, id, reason: "验收不通过，重新生成")
            round += 1
        }
    }

    func stepGate(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = try readState(dir)
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let tokens = forbiddenBrandTokens(softwareName(state), extraTokens(state))
        let tokensHash = hashObject(JSON(tokens))
        let llmAvailable = await resolveLlm("gate") != nil
        let before = progressScreens(dir)
        let screens = plan["screens"].items
        var waiting = JSONObject()
        for screen in screens {
            let id = screen["id"]?.jsString ?? ""
            waiting[id] = (before[id] ?? .emptyObject).merging(["status": "waiting-check"])
        }
        setProgress(dir, .obj(["screens": .object(waiting)]))
        let gates = await mapLimit(screens, 4) { screen, _ in
            do {
                return try await self.gateOne(ctx, screen, tokens, tokensHash, llmAvailable)
            } catch {
                return JSON.obj(["status": "error", "reasons": JSON([messageOf(error)])])
            }
        }
        let failed = screens.indices.filter { ["failed", "error"].contains(gates[$0]["status"]?.string ?? "") }
        let manual = screens.indices.filter { gates[$0]["status"]?.string == "needs-manual" }
        if !failed.isEmpty {
            let detail = failed.map { "\(screens[$0]["id"]?.jsString ?? "")（\(gates[$0]["reasons"].items.map(\.jsString).joined(separator: "；"))）" }.joined(separator: "、")
            throw StudioError("以下截图验收没有通过：\(detail)。可以在截图页重生或换成备选图。")
        }
        if !manual.isEmpty { return StepOutcome(status: "review", message: "请在截图页逐张确认（\(manual.count) 张），确认界面里没有软件名后继续") }
        return StepOutcome(status: "done")
    }
}
