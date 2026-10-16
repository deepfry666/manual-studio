import Foundation

final class StepTracker: @unchecked Sendable {
    let started = nowMs()
    private let lock = NSLock()
    private var steps: [String: Double] = [:]
    private var order: [String] = []

    func add(_ step: String, _ ms: Double) {
        lock.withLock {
            if steps[step] == nil { order.append(step) }
            steps[step, default: 0] += ms
        }
    }

    var isEmpty: Bool { lock.withLock { steps.isEmpty } }
    var samples: [String: Double] { lock.withLock { steps } }
    var json: JSON {
        lock.withLock {
            var object = JSONObject()
            for step in order { object[step] = .number(steps[step]!) }
            return .object(object)
        }
    }
}

extension Pipeline {
    func stepImpl(_ step: String, _ ctx: StepContext) async throws -> StepOutcome {
        switch step {
        case "plan": return try await stepPlan(ctx)
        case "prompts": return try await stepPrompts(ctx)
        case "images": return try await stepImages(ctx)
        case "gate": return try await stepGate(ctx)
        case "content": return try await stepContent(ctx)
        case "design": return try await stepDesign(ctx)
        case "receipt": return try await stepReceipt(ctx)
        case "build": return try await stepBuild(ctx)
        default: throw StudioError("未知步骤：\(step)")
        }
    }

    /// 开始运行（已经在运行时返回同一个任务）。
    @discardableResult
    public func start(_ dir: String, _ options: RunOptions = RunOptions()) -> Task<RunResult, Never> {
        running.withLock { table in
            if let existing = table[dir], let task = existing.task { return task }
            let handle = RunHandle(cancellable: true)
            let task = Task<RunResult, Never> {
                let result = await self.runInner(dir, options)
                self.running.withLock { if $0[dir] === handle { $0[dir] = nil } }
                return result
            }
            handle.task = task
            table[dir] = handle
            return task
        }
    }

    /// 跑流水线，等它结束。
    @discardableResult
    public func run(_ dir: String, _ options: RunOptions = RunOptions()) async -> RunResult {
        await start(dir, options).value
    }

    public func cancel(_ dir: String) {
        running.withLock { $0[dir] }?.cancel()
    }

    /// 包一层：管理实时进度，结束后记录这次运行用时。
    func runInner(_ dir: String, _ options: RunOptions) async -> RunResult {
        if isSubmitted(try? projectStore.read(dir)) { return RunResult(status: "failed", error: "已提交的项目只读，没有运行；要修改请先取消已提交") }
        let startedAt = isoNow()
        let tracker = StepTracker()
        let initial: JSON = .obj([
            "startedAt": .string(startedAt), "started": .number(tracker.started), "step": .null, "stepStarted": .null, "plannedSteps": [], "doneSteps": [],
            "screens": .emptyObject, "detail": .null, "reason": JSON.orNull(options.reason),
        ])
        progress.withLock { $0[dir] = initial }
        emit(.obj(["type": "progress", "projectDir": .string(dir), "progress": initial]))
        var result: RunResult
        do {
            result = try await runSteps(dir, options, tracker)
        } catch {
            result = RunResult(status: "failed", error: messageOf(error))
            emit(.obj(["type": "log", "projectDir": .string(dir), "level": "error", "message": .string(messageOf(error))]))
        }
        progress.withLock { $0[dir] = nil }
        emit(.obj(["type": "progress", "projectDir": .string(dir), "progress": .null]))
        if !tracker.isEmpty {
            let entry: JSON = .obj(["startedAt": .string(startedAt), "ms": .number(nowMs() - tracker.started), "steps": tracker.json, "status": .string(result.status), "reason": JSON.orNull(options.reason)])
            try? await recordRun(dir, entry, samples: tracker.samples)
        }
        return result
    }

    func recordRun(_ dir: String, _ entry: JSON, samples: [String: Double]) async throws {
        let finishedAt = isoNow()
        var run = entry
        run["finishedAt"] = .string(finishedAt)
        let runEntry = run
        let ms = run["ms"]?.number ?? 0
        let state = try await update(dir) { draft in
            var timing = draft["timing"].or(.obj(["totalMs": 0, "runs": []]))
            let total = (timing["totalMs"]?.number ?? 0) + ms
            timing["totalMs"] = .number(total)
            timing["runs"] = .array(Array((timing["runs"].items + [runEntry]).suffix(30)))
            var firstDone = false
            if runEntry["status"]?.string == "done", !timing["completedAt"].isTruthy {
                timing["completedAt"] = .string(finishedAt)
                timing["completedMs"] = .number(total)
                firstDone = true
            }
            draft["timing"] = timing
            appendLog(&draft, "本次运行用时 \(formatDuration(ms))\(firstDone ? "，项目完成，累计用时 \(formatDuration(total))" : "")")
        }
        let timing = state["timing"] ?? .emptyObject
        let firstDone = run["status"]?.string == "done" && timing["completedAt"]?.string == finishedAt
        addStepSamples(samples)
        // 生成记录只在本软件确实生成或修改过东西（记录文件已存在）时更新，不在只导入、没改动的历史项目里新建文件
        if readRecord(dir) != nil {
            try await updateRecord(dir) { record in
                record["timing"] = .obj(["totalMs": timing["totalMs"], "completedMs": timing["completedMs"] ?? .null, "completedAt": timing["completedAt"] ?? .null, "runs": timing["runs"]])
                record.append("history", .obj(["at": .string(finishedAt), "event": "run", "status": runEntry["status"], "ms": runEntry["ms"], "steps": runEntry["steps"], "reason": runEntry["reason"]]))
            }
        }
        emit(.obj(["type": "run-finished", "projectDir": .string(dir), "name": state["request"]?["softwareName"] ?? .null, "status": run["status"] ?? .null, "ms": .number(ms), "totalMs": timing["totalMs"] ?? 0, "firstDone": .bool(firstDone)]))
    }

    func runSteps(_ dir: String, _ options: RunOptions, _ tracker: StepTracker) async throws -> RunResult {
        guard let initial = try projectStore.read(dir) else { return RunResult(status: "failed", error: "项目状态不存在") }
        if initial["readOnly"].isTruthy { return RunResult(status: "failed", error: "只读的历史项目（没有文案和截图源文件），不能运行") }
        let settings = try await settingsStore.get()
        let batchId = options.batchId ?? "\(Path.basename(dir)):\(timestampSlug())"
        let fromIndex = options.from.flatMap { PIPELINE_STEPS.firstIndex(of: $0) } ?? 0
        if initial["contentDateNeedsRefresh"].isTruthy, PIPELINE_STEPS.prefix(fromIndex).contains(where: { !["done", "skipped"].contains(initial["steps"]?[$0]?["status"]?.string ?? "") }) {
            throw StudioError("内容日期已更改，请在概览点击「继续运行」，先更新全部截图和说明，再使用单屏重生或重写文字")
        }
        let untilIndex = options.until.flatMap { PIPELINE_STEPS.firstIndex(of: $0) } ?? PIPELINE_STEPS.count - 1
        let force = Set(options.force)
        if fromIndex <= untilIndex { setProgress(dir, .obj(["plannedSteps": JSON(Array(PIPELINE_STEPS[fromIndex...untilIndex]))])) }
        try await update(dir) { state in
            state["status"] = "running"
            state["lastError"] = .null
        }
        var index = fromIndex
        while index <= untilIndex {
            defer { index += 1 }
            let step = PIPELINE_STEPS[index]
            if Task.isCancelled {
                try await update(dir) { state in
                    state["status"] = "canceled"
                    appendLog(&state, "已停止")
                }
                return RunResult(status: "canceled")
            }
            var state = try readState(dir)
            let stepState = state["steps"]?[step] ?? .emptyObject
            if stepState["status"]?.string == "review", !force.contains(step) {
                try await update(dir) { $0["status"] = "waiting" }
                return RunResult(status: "waiting", step: step)
            }
            if let inputHash = stepInputHash(step, dir, state, settings), stepState["status"]?.string == "done", stepState["inputHash"]?.string == inputHash, !force.contains(step) {
                setProgress(dir, .obj(["doneSteps": .array(doneSteps(dir) + [.string(step)])]))
                continue
            }
            let stepStarted = nowMs()
            setProgress(dir, .obj(["step": .string(step), "stepStarted": .number(stepStarted), "detail": .null]))
            let startedAt = isoNow()
            try await update(dir) { draft in
                draft.mergeChild("steps", step, .obj(["status": "running", "startedAt": .string(startedAt), "error": .null]))
            }
            emit(.obj(["type": "step", "projectDir": .string(dir), "step": .string(step), "status": "running"]))
            do {
                state = try readState(dir)
                let ctx = StepContext(
                    projectDir: dir, state: state, settings: settings, batchId: batchId,
                    reviewPlan: options.reviewPlan ?? settings.pipeline.reviewPlanSingle,
                    forceScreens: options.forceScreens, forceContent: options.forceContent,
                    contentInstructions: options.contentInstructions, designInstruction: options.designInstruction,
                    forceDesign: force.contains("design")
                )
                let outcome = try await stepImpl(step, ctx)
                tracker.add(step, nowMs() - stepStarted)
                setProgress(dir, .obj(["doneSteps": .array(doneSteps(dir) + [.string(step)]), "detail": .null]))
                let finalHash = stepInputHash(step, dir, try readState(dir), settings)
                let finishedAt = isoNow()
                try await update(dir) { draft in
                    draft["steps"]?[step] = .obj(["status": .string(outcome.status), "inputHash": JSON.orNull(finalHash), "finishedAt": .string(finishedAt), "message": JSON.orNull(outcome.message)])
                    if let reason = outcome.screenCountReason, !reason.isEmpty { draft["screenCountReason"] = .string(reason) }
                }
                emit(.obj(["type": "step", "projectDir": .string(dir), "step": .string(step), "status": .string(outcome.status)]))
                if outcome.status == "review" {
                    try await update(dir) { draft in
                        draft["status"] = "waiting"
                        appendLog(&draft, outcome.message ?? "「\(STEP_LABELS[step] ?? step)」等待确认")
                    }
                    return RunResult(status: "waiting", step: step)
                }
            } catch {
                tracker.add(step, nowMs() - stepStarted)
                let canceled = Task.isCancelled
                let message = canceled && isCancellation(error) ? "已取消" : messageOf(error)
                let finishedAt = isoNow()
                let label = STEP_LABELS[step] ?? step
                try await update(dir) { draft in
                    draft.mergeChild("steps", step, .obj(["status": .string(canceled ? "pending" : "failed"), "error": .string(message), "finishedAt": .string(finishedAt)]))
                    draft["status"] = .string(canceled ? "canceled" : "needs-attention")
                    draft["lastError"] = canceled ? .null : .string("\(label)：\(message)")
                    appendLog(&draft, canceled ? "已停止" : "\(label)失败：\(message)", canceled ? "info" : "error")
                }
                emit(.obj(["type": "step", "projectDir": .string(dir), "step": .string(step), "status": "failed", "error": .string(message)]))
                return RunResult(status: canceled ? "canceled" : "failed", step: step, error: message)
            }
        }
        let final = try readState(dir)
        let allDone = PIPELINE_STEPS.allSatisfy { ["done", "skipped"].contains(final["steps"]?[$0]?["status"]?.string ?? "") }
        try await update(dir) {
            $0["status"] = .string(allDone ? "done" : "idle")
            if allDone { $0["contentDateNeedsRefresh"] = nil }
        }
        return RunResult(status: allDone ? "done" : "idle")
    }

    // MARK: - 编辑操作

    func markDirty(_ dir: String, _ steps: [String]) async throws {
        try await update(dir) { state in
            for step in steps where state["steps"]?[step] != nil {
                state.mergeChild("steps", step, .obj(["status": "pending", "inputHash": .null]))
            }
            if state["status"]?.string == "done" { state["status"] = "idle" }
        }
    }

    func assertScreenId(_ id: String) throws {
        if !Rx.test("^screen-[0-9]{2}$", id) { throw StudioError("截图编号不合法：\(id)") }
    }

    func assertIdle(_ dir: String) throws {
        if isRunning(dir) { throw StudioError("项目正在运行，先停止再修改") }
    }

    /// 交付包里的文件在软件外被改过时：overwrite 为 true 用软件里的内容重新生成（手改的文件另存一份，不会被清理），
    /// 为 false 保留手改的交付包，这次不更新（以后再更新时还会再问）。
    @discardableResult
    public func resolveExternalEdits(_ dir: String, overwrite: Bool) async throws -> Task<RunResult, Never>? {
        try assertEditable(dir)
        try assertIdle(dir)
        if overwrite {
            try await update(dir) { state in
                state["overwriteExternalEdits"] = true
                state.mergeChild("steps", "build", ["status": "pending"])
            }
            return start(dir, RunOptions(from: "build", force: ["build"]))
        }
        try await update(dir) { state in
            state.mergeChild("steps", "build", ["status": "done", "inputHash": .null, "message": .null])
            let allDone = PIPELINE_STEPS.allSatisfy { ["done", "skipped"].contains(state["steps"]?[$0]?["status"]?.string ?? "") }
            state["status"] = .string(allDone ? "done" : "idle")
            appendLog(&state, "保留了在软件外改过的交付包，这次没有更新")
        }
        return nil
    }

    public func confirmPlan(_ dir: String) async throws -> Task<RunResult, Never> {
        try assertEditable(dir)
        try await update(dir) { state in
            state.mergeChild("steps", "plan", ["status": "done"])
            appendLog(&state, "规划已确认")
        }
        return start(dir, RunOptions(from: "prompts"))
    }

    public func savePlanScreen(_ dir: String, _ id: String, _ patch: JSON) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        let paths = projectPaths(dir)
        guard var plan = try FS.readJSON(paths.screenPlan) else { throw StudioError("规划文件里找不到这一屏，可以直接编辑这一屏的提示词") }
        // 兼容历史格式：数组 / { screens } / { flow }，行里用 id 或 screenId
        let key: String? = plan.isArray ? nil : (plan["screens"].isTruthy ? "screens" : "flow")
        var rows = (key == nil ? plan : plan[key!] ?? .null).array ?? []
        let index = (Int(id.replacingOccurrences(of: "screen-", with: "")) ?? 0) - 1
        let found = rows.firstIndex { $0.isObject && ($0["id"]?.string == id || $0["screenId"]?.string == id) }
            ?? (index >= 0 && index < rows.count && rows[index].isObject ? index : nil)
        guard let position = found else { throw StudioError("规划文件里找不到这一屏，可以直接编辑这一屏的提示词") }
        for field in ["title", "pageType", "activeTab", "mustShow", "sampleData", "visualBrief", "textContract"] {
            if let value = patch[field] { rows[position][field] = value }
        }
        if let key { plan[key] = .array(rows) } else { plan = .array(rows) }
        try FS.writeJSONAtomic(paths.screenPlan, plan)
        try await markDirty(dir, ["prompts"])
    }

    public func savePrompt(_ dir: String, _ id: String, _ prompt: String) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        try FS.writeAtomic(projectPaths(dir).promptFile(id), ensureBrandBan(prompt))
        try await update(dir) { state in state.mergeChild("screens", id, ["promptEdited": true]) }
        try await markDirty(dir, ["prompts"])
    }

    public func regenerateScreen(_ dir: String, _ id: String) throws -> Task<RunResult, Never> {
        try assertEditable(dir)
        try assertScreenId(id)
        return start(dir, RunOptions(from: "images", forceScreens: [id]))
    }

    /// 换回以前用过的截图（来自归档）。当前的图同样先归档，所以还能再换回来。
    public func restoreScreen(_ dir: String, _ id: String, _ file: String) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        guard screenHistory(dir, id).contains(where: { $0["file"]?.string == file }) else { throw StudioError("找不到这张旧截图") }
        let sha = try await replaceScreenImage(dir, id, with: file, log: "\(id) 换回了以前的截图")
        let name = Path.basename(file)
        try await updateRecord(dir) { record in
            let at = isoNow()
            record["screens"]?[id] = .obj(["source": "restored", "restoredFrom": .string(name), "imageSha256": .string(sha), "generatedAt": .string(at)])
            record.append("history", .obj(["at": .string(at), "event": "screen-restored", "screenId": .string(id), "file": .string(name)]))
        }
        try await markDirty(dir, ["gate", "content", "receipt", "build"])
    }

    /// 用另一张图替换这一屏：当前的图先归档，换上后要重新验收，说明按新图重写（人工改过的除外）
    func replaceScreenImage(_ dir: String, _ id: String, with file: String, log message: String) async throws -> String {
        try assertEditable(dir)
        let paths = projectPaths(dir)
        let target = paths.screenFile(id)
        if FS.exists(target) {
            let archiveDir = Path.join(paths.archive, "screens-\(timestampSlug())")
            try FS.mkdirp(archiveDir)
            var archived = Path.join(archiveDir, "\(id).png")
            var index = 2
            while FS.exists(archived) {
                archived = Path.join(archiveDir, "\(id)-\(index).png")
                index += 1
            }
            try FS.copy(target, archived)
        }
        try FS.writeAtomic(target, FS.read(file))
        let sha = try sha256File(target)
        let at = isoNow()
        try await update(dir) { state in
            var current = state["screens"]?[id] ?? .emptyObject
            current = current.merging(.obj(["imageSha": .string(sha), "gate": .null, "generatedAt": .string(at), "fromAlternate": true, "contentStale": true]))
            current["imagePromptHash"] = current["promptHash"]
            current["requestedChange"] = nil
            state["screens"]?[id] = current
            appendLog(&state, message)
        }
        return sha
    }

    public func useAlternate(_ dir: String, _ id: String, _ file: String) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        guard listAlternates(dir, id).contains(where: { $0["file"]?.string == file }) else { throw StudioError("备选图不存在") }
        let sha = try await replaceScreenImage(dir, id, with: file, log: "\(id) 已换成备选图")
        FS.remove(file)
        let parts = Path.basename(file, ".png").components(separatedBy: "-")
        let providerId = parts.count > 6 ? parts[6...].joined(separator: "-") : ""
        let alternateName = Path.basename(file)
        try await updateRecord(dir) { record in
            let at = isoNow()
            record["screens"]?[id] = .obj(["source": "alternate", "providerId": providerId.isEmpty ? .null : .string(providerId), "alternateFile": .string(alternateName), "imageSha256": .string(sha), "generatedAt": .string(at)])
            record.append("history", .obj(["at": .string(at), "event": "alternate-used", "screenId": .string(id), "providerId": providerId.isEmpty ? .null : .string(providerId), "alternateFile": .string(alternateName)]))
        }
        try await markDirty(dir, ["gate", "content", "receipt", "build"])
    }

    public func manualGate(_ dir: String, _ id: String, _ passed: Bool) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        let state = try readState(dir)
        let sha = try sha256File(projectPaths(dir).screenFile(id))
        try await updateRecord(dir) { record in
            let at = isoNow()
            record["gate"]?[id] = .obj(["status": .string(passed ? "manual-passed" : "failed"), "method": "manual", "imageSha256": .string(sha), "checkedAt": .string(at)])
            record.append("history", .obj(["at": .string(at), "event": "gate", "screenId": .string(id), "status": .string(passed ? "manual-passed" : "failed"), "method": "manual"]))
        }
        let tokensHash = gateKey(state)
        try await update(dir) { draft in
            let previous = draft["screens"]?[id]?["gate"].or(.emptyObject) ?? .emptyObject
            let checkedAt = isoNow()
            let gate: JSON = passed
                ? previous.merging(.obj(["status": "manual-passed", "method": .string(previous["method"]?.string == "vision" ? "vision+manual" : "manual"), "sha": .string(sha), "tokensHash": .string(tokensHash), "checkedAt": .string(checkedAt), "reasons": []]))
                : previous.merging(.obj(["status": "failed", "method": "manual", "sha": .string(sha), "tokensHash": .string(tokensHash), "checkedAt": .string(checkedAt), "reasons": ["人工判定有软件名或不合格"]]))
            draft.mergeChild("screens", id, .obj(["gate": gate]))
            if passed { draft["screens"]?[id]?["requestedChange"] = nil }
            appendLog(&draft, "\(id) 人工\(passed ? "确认通过" : "判定不合格")")
            let gateStatus = draft["steps"]?["gate"]?["status"]?.string
            if gateStatus == "review" || gateStatus == "failed" { draft.mergeChild("steps", "gate", ["status": "pending"]) }
        }
    }

    /// screens：[{ id, title?, text? }]
    /// design：整章设计说明（[{title, text}]），nil 表示不改
    public func saveContent(_ dir: String, overview: String?, screens patches: [JSON], design: [JSON]? = nil) async throws {
        try assertEditable(dir)
        try assertIdle(dir)
        let paths = projectPaths(dir)
        guard var content = try FS.readJSON(paths.content) else { throw StudioError("还没有文案") }
        // 改之前的文字先记进历史；连续自动保存时同一处 3 分钟内只记一份
        var versions: [ContentVersion] = []
        let oldOverview = content["cover"]?["overview"].text ?? ""
        if let overview, overview != oldOverview { versions.append(ContentVersion(target: "overview", text: oldOverview, source: "修改前")) }
        for patch in patches {
            guard let id = patch["id"]?.string, let old = content["screens"].items.first(where: { $0["id"]?.string == id }) else { continue }
            if let text = patch["text"]?.string, text != old["text"].text { versions.append(ContentVersion(target: id, title: old["title"].text, text: old["text"].text, source: "修改前")) }
        }
        let oldSections = content["design"]?["sections"].items ?? []
        if let design {
            for (index, section) in design.enumerated() where index < oldSections.count && section["text"].text != oldSections[index]["text"].text {
                versions.append(ContentVersion(target: "design-\(index + 1)", title: oldSections[index]["title"].text, text: oldSections[index]["text"].text, source: "修改前"))
            }
        }
        recordContentHistory(dir, versions, coalesce: true)
        if let design {
            content["design"] = .obj(["sections": .array(design.map { .obj(["title": .string($0["title"].text.jsTrimmed), "text": .string($0["text"].text)]) })])
        }
        if let overview { content["cover"] = content["cover"].or(.emptyObject).merging(.obj(["overview": .string(overview)])) }
        var screens = content["screens"].items
        var editedIds: [String] = []
        for patch in patches {
            guard let id = patch["id"]?.string, let index = screens.firstIndex(where: { $0["id"]?.string == id }) else { continue }
            if let title = patch["title"]?.string {
                screens[index]["title"] = .string(title.jsTrimmed)
                screens[index]["caption"] = .string("图\(index + 1) \(title.jsTrimmed)")
            }
            if let text = patch["text"]?.string { screens[index]["text"] = .string(text) }
            editedIds.append(id)
        }
        content["screens"] = .array(screens)
        content["screenshotReview"] = nil
        try FS.writeJSONAtomic(paths.content, content)
        let edited = editedIds
        try await update(dir) { state in
            for id in edited { state.mergeChild("screens", id, ["textEdited": true, "contentStale": false]) }
            if !edited.isEmpty { state["warnings"] = .array(state["warnings"].items.filter { !($0.string ?? "").hasPrefix("截图已更换") }) }
            if overview != nil { state["overviewEdited"] = true }
            if design != nil { state["designEdited"] = true }
        }
        try await markDirty(dir, ["receipt", "build"])
    }

    public func rewriteContent(_ dir: String, _ ids: [String]) async throws -> Task<RunResult, Never> {
        try assertEditable(dir)
        for id in ids where id != "overview" { try assertScreenId(id) }
        try await update(dir) { state in
            for id in ids where state["screens"]?[id] != nil { state["screens"]?[id]?["textEdited"] = false }
            if ids.contains("overview") { state["overviewEdited"] = false }
        }
        return start(dir, RunOptions(from: "content", forceContent: ids))
    }

    @discardableResult
    public func updateRequest(_ dir: String, _ patch: JSON) async throws -> JSON {
        try assertEditable(dir)
        try assertIdle(dir)
        let state = try readState(dir)
        let before = state["request"] ?? .emptyObject
        var patch = patch
        if let date = patch["contentDate"]?.string {
            let value = date.jsTrimmed
            if !value.isEmpty && !validContentDate(value) { throw StudioError("内容日期请填写有效的 YYYY-MM-DD 日期") }
            patch["contentDate"] = .string(value.isEmpty ? localDateKey() : value)
        }
        if let date = patch["earliestDate"]?.string {
            let value = date.jsTrimmed
            if !value.isEmpty && !validContentDate(value) { throw StudioError("最早日期请填写有效的 YYYY-MM-DD 日期，或留空") }
            patch["earliestDate"] = .string(value)
        }
        let nextContentDate = patch["contentDate"]?.string ?? before["contentDate"]?.string ?? ""
        let nextEarliest = patch["earliestDate"]?.string ?? before["earliestDate"]?.string ?? ""
        if validContentDate(nextContentDate), validContentDate(nextEarliest), nextEarliest > nextContentDate {
            throw StudioError("最早日期（\(nextEarliest)）不能晚于内容日期（\(nextContentDate)）")
        }
        var next = before.merging(patch)
        // 版本号不用人选：按软件名自动判断（历史项目里单独填适用版本的保持不变）
        if let name = patch["softwareName"], before["versionPolicy"]?.string != "separate-metadata" {
            next["versionPolicy"] = .string(detectVersion(name.jsString) != nil ? "in-name" : "none")
        }
        var dirty = Set<String>()
        func changed(_ key: String) -> Bool {
            guard let value = patch[key] else { return false }
            return value.serialized() != (before[key] ?? .null).serialized()
        }
        func orNull(_ value: JSON?) -> JSON { value.truthyValue ?? .null }
        if let name = patch["softwareName"], name != before["softwareName"] {
            let paths = projectPaths(dir)
            let oldBundle = paths.bundle(before["softwareName"]?.jsString ?? "")
            if FS.isDirectory(oldBundle) {
                try FS.mkdirp(paths.archive)
                try FS.move(oldBundle, Path.join(paths.archive, "\(before["softwareName"]?.jsString ?? "")-交付-\(timestampSlug())"))
            }
            ["prompts", "gate", "receipt", "build"].forEach { dirty.insert($0) }
        }
        if ["screenCount", "emphasis", "notes", "platform", "contentDate", "earliestDate"].contains(where: { changed($0) && orNull(patch[$0]) != orNull(before[$0]) }) {
            ["plan", "prompts", "images", "gate", "content", "receipt", "build"].forEach { dirty.insert($0) }
        }
        if changed("contentDate") || changed("earliestDate") { dirty.insert("design") }
        if changed("wantDesign"), patch["wantDesign"].isTruthy != before["wantDesign"].isTruthy { ["design", "receipt", "build"].forEach { dirty.insert($0) } }
        if ["codeSource", "codeSourceLocked", "txtFields", "compileDate", "versionPolicy", "applicableVersion", "allowDropCodeDoc"].contains(where: changed) { dirty.insert("build") }
        if changed("extraBrandTokens") { ["gate", "receipt", "build"].forEach { dirty.insert($0) } }
        let request = next
        let refreshContentDate = dirty.contains("plan") && (patch["contentDate"] != nil || patch["earliestDate"] != nil)
        try await update(dir) { draft in
            draft["request"] = request
            if refreshContentDate { draft["contentDateNeedsRefresh"] = true }
            appendLog(&draft, "项目设置已更新")
        }
        try await markDirty(dir, PIPELINE_STEPS.filter { dirty.contains($0) })
        return try readState(dir)
    }

    /// 历史项目没有代码来源时：改用总设置里的代码来源（下次生成交付包时生效）。
    public func useGlobalCodeSource(_ dir: String) async throws {
        try assertEditable(dir)
        try assertIdle(dir)
        let settings = try await settingsStore.get()
        if settings.codeSource.path.isEmpty { throw StudioError("总设置里还没有代码来源，先到「设置 → 代码来源」里选择") }
        let extensions = settings.codeSource.extensions.isEmpty ? [".java"] : settings.codeSource.extensions
        try await updateRequest(dir, .obj(["codeSource": .obj(["path": .string(settings.codeSource.path), "extensions": JSON(extensions)]), "codeSourceLocked": true]))
    }

    /// 忽略「PDF 字体不对」：人工看过 PDF 觉得可以接受，就不再标红（不改动任何文件）。
    public func ignorePdfFontWarning(_ dir: String) async throws {
        try assertIdle(dir)
        _ = try await update(dir) { draft in
            guard var lastBuild = draft["lastBuild"].truthyValue else { return }
            var fonts = lastBuild["pdfFonts"].or(.emptyObject)
            var ignored: [String] = []
            for (kind, entry) in fonts.fields where entry.isObject && entry["ok"] == .bool(false) {
                fonts[kind] = entry.merging(["ok": true, "ignored": true])
                ignored.append(kind)
            }
            guard !ignored.isEmpty else { return }
            lastBuild["pdfFonts"] = fonts
            lastBuild["warnings"] = .array(lastBuild["warnings"].items.filter { !$0.jsString.contains("PDF 字体不对") })
            draft["lastBuild"] = lastBuild
            appendLog(&draft, "已忽略 PDF 字体提示（\(ignored.map { DOC_FONTS[$0]?.label ?? $0 }.joined(separator: "、"))）", "info")
        }
    }

    /// 重新导出PDF；旧指南图片超宽时先用已有内容重排Word，TXT和截图不动。
    public func reexportPdfs(_ dir: String) async throws -> JSON {
        try assertEditable(dir)
        try assertIdle(dir)
        let handle = RunHandle(cancellable: false)
        let job = Task<JSON, Error> {
            guard let state = try self.projectStore.read(dir) else { throw StudioError("项目不存在") }
            let settings = try await self.settingsStore.get()
            let fontPlan = resolveFontPlan(settings.pdf)
            let result = try await reexportBundlePdfs(projectDir: dir, softwareName: self.softwareName(state), stagingRoot: self.projectStore.stagingRoot, fontPlan: fontPlan) { message in
                try? await self.log(dir, message)
            }
            let warnings = result["warnings"].items.map(\.jsString)
            let at = isoNow()
            try await self.update(dir) { draft in
                if var lastBuild = draft["lastBuild"].truthyValue {
                    // 重排指南 Word 是软件自己改的，更新指纹，免得下次误以为是在软件外改的
                    if result["guideLayoutRepaired"].isTruthy {
                        let name = draft["request"]?["softwareName"]?.jsString ?? ""
                        lastBuild["bundleHashes"] = refreshBundleHashes(lastBuild, dir, name, files: ["\(name)指南.docx"])
                    }
                    lastBuild["pdfFonts"] = lastBuild["pdfFonts"].or(.emptyObject).merging(result["pdfFonts"])
                    lastBuild["pdfPages"] = result["pdfPages"]
                    lastBuild["codePdfPages"] = result["codePdfPages"]
                    lastBuild["withPdf"] = true
                    lastBuild["warnings"] = .array(lastBuild["warnings"].items.filter { !$0.jsString.contains("PDF 字体不对") } + result["warnings"].items)
                    draft["lastBuild"] = lastBuild
                }
                draft["pdfReexportedAt"] = .string(at)
                appendLog(&draft, "已重新导出 PDF：\(jsJoin(result["files"].items, "、"))\(warnings.isEmpty ? "" : "（\(warnings.joined(separator: "；"))）")", warnings.isEmpty ? "info" : "warn")
            }
            try await updateRecord(dir) { record in
                record.append("history", .obj(["at": .string(isoNow()), "event": "pdf-reexported", "files": result["files"], "pdfFonts": result["pdfFonts"], "pdfPages": result["pdfPages"], "codePdfPages": result["codePdfPages"]]))
            }
            return result
        }
        handle.task = Task { _ = try? await job.value; return RunResult(status: "done") }
        running.withLock { $0[dir] = handle }
        emit(.obj(["type": "project", "projectDir": .string(dir), "status": "running"]))
        defer {
            running.withLock { if $0[dir] === handle { $0[dir] = nil } }
            emit(.obj(["type": "project", "projectDir": .string(dir)]))
        }
        return try await job.value
    }

    // MARK: - 修改意见：先攒清单，再整理，确认后统一修改

    /// target：指定改哪里（screen-XX / all / overview / design），nil 表示让软件判断。
    @discardableResult
    public func addFeedback(_ dir: String, _ text: String, target: String? = nil) async throws -> JSON {
        try assertEditable(dir)
        let value = text.jsTrimmed
        if value.isEmpty { throw StudioError("修改意见是空的") }
        let item: JSON = .obj(["id": .string(randomHex(4)), "text": .string(value), "at": .string(isoNow()), "status": "pending", "target": JSON.maybe(target.flatMap { $0.isEmpty ? nil : $0 })])
        try await update(dir) { draft in
            draft["feedback"] = .array(draft["feedback"].items + [item])
            draft["feedbackPlan"] = .null
        }
        return item
    }

    public func editFeedback(_ dir: String, _ id: String, _ text: String) async throws {
        try assertEditable(dir)
        let value = text.jsTrimmed
        if value.isEmpty { throw StudioError("修改意见是空的") }
        try await update(dir) { draft in
            draft["feedback"] = .array(draft["feedback"].items.map { item in
                item["id"]?.string == id && item["status"]?.string == "pending" ? item.merging(.obj(["text": .string(value)])) : item
            })
            draft["feedbackPlan"] = .null
        }
    }

    public func setFeedbackTarget(_ dir: String, _ id: String, _ target: String?) async throws {
        try assertEditable(dir)
        try await update(dir) { draft in
            draft["feedback"] = .array(draft["feedback"].items.map { item in
                guard item["id"]?.string == id, item["status"]?.string == "pending" else { return item }
                var next = item
                next["target"] = target.flatMap { $0.isEmpty ? nil : JSON.string($0) }
                return next
            })
            draft["feedbackPlan"] = .null
        }
    }

    public func removeFeedback(_ dir: String, _ id: String) async throws {
        try assertEditable(dir)
        try await update(dir) { draft in
            draft["feedback"] = .array(draft["feedback"].items.filter { $0["id"]?.string != id })
            draft["feedbackPlan"] = .null
        }
    }

    /// 把清单里所有未处理的意见一起交给大模型，整理成「改哪几张图、重写哪几段文字」。
    public func analyzeFeedback(_ dir: String) async throws -> JSON {
        try assertEditable(dir)
        guard let state = try projectStore.read(dir) else { throw StudioError("项目不存在") }
        if state["readOnly"].isTruthy { throw StudioError("只读的历史项目不能修改") }
        let items = state["feedback"].items.filter { $0["status"]?.string == "pending" }
        if items.isEmpty { throw StudioError("清单里没有待处理的修改意见") }
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划，先运行一次再提修改意见") }
        let content = try FS.readJSON(projectPaths(dir).content)
        var contentById: [String: JSON] = [:]
        for (index, screen) in (content?["screens"].items ?? []).enumerated() { contentById[screen["id"].or(.string(screenId(index))).jsString] = screen }
        let screens: [FeedbackScreenInfo] = plan["screens"].items.enumerated().map { index, screen in
            let id = screen["id"]?.jsString ?? ""
            let gate = state["screens"]?[id]?["gate"]
            let inventory = gate?["inventory"].text ?? ""
            return FeedbackScreenInfo(
                figure: "图\(index + 1)",
                id: id,
                title: (contentById[id]?["title"].truthyValue ?? screen["title"] ?? .null).jsString,
                picture: inventory.isEmpty ? screen["visualBrief"].text : inventory,
                visibleText: gate?["visibleText"].items.map(\.jsString) ?? [],
                text: contentById[id]?["text"].text ?? ""
            )
        }
        let screenIds = screens.map(\.id)
        let hasDesign = state["request"]?["wantDesign"].isTruthy == true || !(content?["design"]?["sections"]?.array?.isEmpty ?? true)
        let inputs = items.map { FeedbackInput(text: $0["text"]?.jsString ?? "", target: feedbackTargetValid($0["target"]?.string, screenIds: screenIds, hasDesign: hasDesign)) }
        // 整理失败（模型出错、格式不对）也不报错退出：按用户指定的位置列出，其余的在确认窗口里选位置
        var raw: JSON = .obj(["summary": "", "actions": [], "questions": []])
        var notice: String?
        do {
            raw = try await callLlm("plan", dir, ChatJsonRequest(
                system: FEEDBACK_SYSTEM_NATIVE,
                user: feedbackUserPromptNative(softwareName: softwareName(state), screens: screens, overview: content?["cover"]?["overview"].text ?? "", hasDesign: hasDesign, items: inputs),
                schema: FEEDBACK_SCHEMA_NATIVE,
                temperature: 0.2,
                maxTokens: 4000
            ))
        } catch {
            notice = "自动整理没有成功（\(messageOf(error).jsSlice(0, 120))）。指定了位置的意见已直接列出，其余的请在下面选择要改哪里。"
        }
        let repaired = repairFeedbackResult(raw, items: inputs, screenIds: screenIds, hasDesign: hasDesign)
        let result: JSON = .obj(["summary": raw["summary"].or(""), "actions": .array(repaired.actions), "questions": .array(repaired.questions)])
        func toIds(_ indexes: JSON?) -> [String] {
            uniqued((indexes?.array ?? []).compactMap { value -> String? in
                guard let number = value.number, number >= 1, Int(number) <= items.count else { return nil }
                return items[Int(number) - 1]["id"]?.string
            })
        }
        func labelOf(_ target: String) -> String { target == "all" ? "全部" : feedbackTargetLabel(target, screens: screens) }
        // 整理结果再规范一遍：「全部截图」展开成每一屏；同一屏同一类型合并；有重新规划时其余截图/说明动作并进去
        var merged: [(key: String, value: JSON)] = []
        for action in result["actions"].items {
            let type = action["type"]?.jsString ?? ""
            let target = action["target"]?.jsString ?? ""
            let targets = type == "image" && target == "all" ? screenIds : [type == "overview" ? "overview" : type == "design" ? "design" : type == "replan" ? "all" : target]
            let instruction = (action["instruction"]?.jsString ?? "").jsTrimmed
            for target in targets {
                let key = "\(type):\(target)"
                if let position = merged.firstIndex(where: { $0.key == key }) {
                    var previous = merged[position].value
                    previous["instruction"] = .string("\(previous["instruction"]?.jsString ?? "")；\(instruction)")
                    previous["items"] = JSON(uniqued(previous["items"].items.map(\.jsString) + toIds(action["items"])))
                    merged[position].value = previous
                } else {
                    merged.append((key, .obj(["key": .string(key), "type": .string(type), "target": .string(target), "targetLabel": .string(labelOf(target)), "instruction": .string(instruction), "items": JSON(toIds(action["items"]))])))
                }
            }
        }
        var actions = merged.map(\.value)
        if let replanIndex = actions.firstIndex(where: { $0["type"]?.string == "replan" }) {
            var replan = actions[replanIndex]
            let others = actions.enumerated().filter { $0.offset != replanIndex && ["image", "text"].contains($0.element["type"]?.string ?? "") }
            replan["items"] = JSON(uniqued(replan["items"].items.map(\.jsString) + others.flatMap { $0.element["items"].items.map(\.jsString) }))
            if !others.isEmpty {
                replan["instruction"] = .string("\(replan["instruction"]?.jsString ?? "")；\(others.map { "\($0.element["targetLabel"]?.jsString ?? "")：\($0.element["instruction"]?.jsString ?? "")" }.joined(separator: "；"))")
            }
            let removed = Set(others.map(\.offset))
            actions[replanIndex] = replan
            actions = actions.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }
        let order = ["replan": 0, "image": 1, "text": 2, "overview": 3, "design": 4]
        actions = actions.enumerated().sorted { a, b in
            let ta = order[a.element["type"]?.string ?? ""] ?? 9
            let tb = order[b.element["type"]?.string ?? ""] ?? 9
            if ta != tb { return ta < tb }
            let xa = a.element["target"]?.jsString ?? ""
            let xb = b.element["target"]?.jsString ?? ""
            if xa != xb { return localeCompareEn(xa, xb) }
            return a.offset < b.offset
        }.map(\.element)
        let questions: [JSON] = result["questions"].items.map { .obj(["question": $0["question"] ?? "", "items": JSON(toIds($0["items"]))]) }.filter { !($0["question"]?.jsString ?? "").jsTrimmed.isEmpty }
        let feedbackPlan: JSON = .obj([
            "createdAt": .string(isoNow()),
            "notice": JSON.maybe(notice),
            "summary": result["summary"] ?? "",
            "itemIds": JSON(items.compactMap { $0["id"]?.string }),
            "actions": .array(actions),
            "questions": .array(questions),
        ])
        try await update(dir) { $0["feedbackPlan"] = feedbackPlan }
        return feedbackPlan
    }

    /// 按确认后的动作统一修改：先改好所有要重生截图的提示词，再一次运行
    /// （截图同时生成、一起验收、一起重写说明、只构建一次）。actions 是界面上勾选、改过措辞后的动作。
    public func applyFeedback(_ dir: String, actions chosen: [JSON]) async throws -> JSON {
        try assertEditable(dir)
        try assertIdle(dir)
        let entered: Bool = applying.withLock { set in set.insert(dir).inserted }
        if !entered { throw StudioError("正在处理上一次的修改") }
        defer { applying.withLock { _ = $0.remove(dir) } }
        let state = try readState(dir)
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let screenIds = plan["screens"].items.map { $0["id"]?.jsString ?? "" }
        // 「全部截图」展开成每一屏
        let expanded: [JSON] = chosen.flatMap { action -> [JSON] in
            guard action["type"]?.string == "image", action["target"]?.string == "all" else { return [action] }
            return screenIds.enumerated().map { index, id in action.merging(.obj(["target": .string(id), "targetLabel": .string("图\(index + 1)")])) }
        }
        // 同一屏同一类型的修改合并成一条（确认窗口里手动加的可能和整理结果重复），免得同时改写同一份提示词
        var actions: [JSON] = []
        for action in expanded {
            let type = action["type"]?.string ?? ""
            let instruction = (action["instruction"]?.jsString ?? "").jsTrimmed
            guard ["image", "text", "overview", "design", "replan"].contains(type), !instruction.isEmpty else { continue }
            let target = ["overview", "design"].contains(type) ? type : action["target"]?.jsString ?? ""
            let items = action["items"]?.array ?? []
            if let index = actions.firstIndex(where: { $0["type"]?.string == type && ($0["target"]?.jsString ?? "") == target }) {
                let previous = actions[index]
                let joined = previous["instruction"]?.jsString == instruction ? instruction : "\(previous["instruction"]?.jsString ?? "")；\(instruction)"
                actions[index] = previous.merging(.obj(["instruction": .string(joined), "items": JSON(uniqued(previous["items"].items.map(\.jsString) + items.map(\.jsString)))]))
            } else {
                actions.append(action.merging(.obj(["target": .string(target), "instruction": .string(instruction), "items": .array(items)])))
            }
        }
        for action in actions where ["image", "text"].contains(action["type"]?.string ?? "") {
            let target = action["target"]?.jsString ?? ""
            if !screenIds.contains(target) { throw StudioError("找不到这一屏：\(target)") }
        }
        if actions.isEmpty { throw StudioError("没有勾选任何修改") }
        let replan = actions.first { $0["type"]?.string == "replan" }
        let imageActions = replan != nil ? [] : actions.filter { $0["type"]?.string == "image" }
        let textActions = replan != nil ? [] : actions.filter { $0["type"]?.string == "text" }
        let overview = actions.first { $0["type"]?.string == "overview" }
        let design = actions.first { $0["type"]?.string == "design" }
        if design != nil, !(state["request"]?["wantDesign"].isTruthy ?? false) { throw StudioError("这个项目没有开启「设计说明」章节，先在概览里打开") }

        // 1. 改写要重生的截图的提示词（几张同时改）
        let paths = projectPaths(dir)
        let name = softwareName(state)
        let tokens = forbiddenBrandTokens(name, extraTokens(state))
        let settings = try await settingsStore.get()
        let withoutNameLines: @Sendable (String) -> String = { text in
            text.components(separatedBy: "\n").filter { !$0.hasPrefix("Project context exact software name:") && !$0.contains(BRAND_BAN_BLOCK) }.joined(separator: "\n")
        }
        let platform = platformOf(state, settings)
        let ui = normalizedUi(plan)
        let editedResults: [Result<(String, String), Error>] = await mapLimit(imageActions, 3) { action, _ in
            do {
                let target = action["target"]?.jsString ?? ""
                var current = FS.readTextIfExists(paths.promptFile(target))
                if current == nil || current!.isEmpty {
                    let screen = plan["screens"].items.first { $0["id"]?.string == target } ?? .emptyObject
                    current = composeScreenPrompt(softwareName: name, platform: platform, targetSize: settings.image.targetSize, ui: ui, screen: screen)
                }
                let result = try await self.callLlm("plan", dir, ChatJsonRequest(
                    system: PROMPT_EDIT_SYSTEM,
                    user: promptEditUserPrompt(prompt: current!, instruction: action["instruction"]?.jsString ?? ""),
                    schema: PROMPT_EDIT_SCHEMA,
                    check: { draft in
                        let hits = findBrandHits([withoutNameLines(draft["prompt"].text)], tokens)
                        return hits.isEmpty ? [] : ["新提示词里出现了软件名/品牌词：\(hits.joined(separator: "、"))，界面上不能出现，请去掉"]
                    },
                    temperature: 0.3,
                    maxTokens: 6000
                ))
                return .success((target, ensureBrandBan(result["prompt"]?.jsString ?? "")))
            } catch {
                return .failure(error)
            }
        }
        var edited: [(String, String)] = []
        for result in editedResults {
            switch result {
            case .success(let item): edited.append(item)
            case .failure(let error): throw error
            }
        }
        try FS.mkdirp(paths.prompts)
        for (id, prompt) in edited { try FS.writeAtomic(paths.promptFile(id), prompt) }

        // 2. 记下这次处理了哪些意见
        let appliedItemIds = uniqued(actions.flatMap { $0["items"].items.map(\.jsString) })
        let at = isoNow()
        let summary = actions.map { "\($0["targetLabel"].truthyValue?.jsString ?? $0["target"]?.jsString ?? "")：\($0["instruction"]?.jsString ?? "")" }.joined(separator: "；")
        let editedList = edited
        // 重生后验收时核对这条修改有没有体现在图上，没有就自动重生
        let requestedChanges: [(String, String)] = imageActions.map { ($0["target"]?.jsString ?? "", $0["instruction"]?.jsString ?? "") }
        let textTargets = textActions.map { $0["target"]?.jsString ?? "" }
        let replanInstruction = replan?["instruction"]?.jsString
        let hasOverview = overview != nil
        try await update(dir) { draft in
            for (id, prompt) in editedList {
                draft.mergeChild("screens", id, .obj(["promptEdited": true, "promptHash": .string(promptIdentity(prompt, draft["request"]?["softwareName"]?.jsString ?? ""))]))
            }
            for (id, change) in requestedChanges where !id.isEmpty && !change.isEmpty { draft.mergeChild("screens", id, .obj(["requestedChange": .string(change)])) }
            for target in textTargets where draft["screens"]?[target] != nil { draft["screens"]?[target]?["textEdited"] = false }
            if hasOverview { draft["overviewEdited"] = false }
            if let replanInstruction {
                let notes = [draft["request"]?["notes"].text ?? "", "修改意见：\(replanInstruction)"].filter { !$0.isEmpty }.joined(separator: "\n")
                draft["request"]?["notes"] = .string(notes)
            }
            let applied = Set(appliedItemIds)
            draft["feedback"] = .array(draft["feedback"].items.map { item in
                applied.contains(item["id"]?.jsString ?? "") && item["status"]?.string == "pending" ? item.merging(.obj(["status": "done", "doneAt": .string(at), "appliedAs": .string(summary)])) : item
            })
            draft["feedbackPlan"] = .null
            appendLog(&draft, "按修改意见统一修改：\(summary)")
        }
        let texts: [JSON] = state["feedback"].items.filter { appliedItemIds.contains($0["id"]?.jsString ?? "") }.map { .obj(["id": $0["id"], "text": $0["text"]]) }
        let actionRecords: [JSON] = actions.map { .obj(["type": $0["type"], "target": $0["target"], "instruction": $0["instruction"]]) }
        try await updateRecord(dir) { record in
            let entry: JSON = .obj(["at": .string(at), "items": .array(texts), "actions": .array(actionRecords)])
            record["feedback"] = .array(Array((record["feedback"].items + [entry]).suffix(100)))
            record.append("history", JSON.obj(["event": "feedback"]).merging(entry))
        }

        // 3. 一次运行完成所有修改
        var contentInstructions: [String: String] = [:]
        for action in textActions { contentInstructions[action["target"]?.jsString ?? ""] = action["instruction"]?.jsString ?? "" }
        if let overview { contentInstructions["overview"] = overview["instruction"]?.jsString ?? "" }
        let from = replan != nil ? "plan" : !imageActions.isEmpty ? "prompts" : !textActions.isEmpty || overview != nil ? "content" : "design"
        start(dir, RunOptions(
            from: from,
            force: (replan != nil ? ["plan"] : []) + (design != nil ? ["design"] : []),
            forceScreens: imageActions.map { $0["target"]?.jsString ?? "" },
            contentInstructions: contentInstructions,
            designInstruction: design?["instruction"]?.jsString,
            reason: "修改意见"
        ))
        return .obj(["started": true, "images": .number(Double(imageActions.count)), "texts": .number(Double(textActions.count + (overview != nil ? 1 : 0))), "design": .bool(design != nil), "replan": .bool(replan != nil), "appliedItems": .number(Double(appliedItemIds.count))])
    }

    /// 导入的历史项目：沿用原有提示词、截图和验收回执，算好各步骤的输入哈希，
    /// 避免第一次运行时把已有截图当成「过期」而重新生成。
    public func adoptImported(_ dir: String) async throws {
        let settings = try await settingsStore.get()
        let paths = projectPaths(dir)
        let plan = try readPlan(dir)
        var state = try readState(dir)
        let platform = platformOf(state, settings)
        if let plan {
            let ui = normalizedUi(plan)
            var patches = JSONObject()
            let name = softwareName(state)
            for screen in plan["screens"].items {
                let id = screen["id"]?.jsString ?? ""
                let prompt = FS.readTextIfExists(paths.promptFile(id))
                let identity = prompt.map { promptIdentity($0, name) }
                patches[id] = .obj(["planRowHash": .string(planRowHash(screen, ui, platform, settings.image.targetSize)), "promptHash": JSON.orNull(identity), "imagePromptHash": JSON.orNull(identity), "promptEdited": .bool(prompt != nil)])
            }
            let all = patches
            try await update(dir) { draft in
                for (id, patch) in all { draft.mergeChild("screens", id, patch) }
                draft["promptsName"] = draft["request"]?["softwareName"]
            }
        }
        state = try readState(dir)
        var hashes: [(String, String)] = []
        for step in ["plan", "prompts", "build"] where state["steps"]?[step]?["status"]?.string == "done" {
            if let hash = stepInputHash(step, dir, state, settings) { hashes.append((step, hash)) }
        }
        let computed = hashes
        try await update(dir) { draft in
            for (step, hash) in computed { draft.mergeChild("steps", step, .obj(["inputHash": .string(hash)])) }
        }
    }
}

extension Pipeline {
    /// 已提交的项目只读
    func assertEditable(_ dir: String) throws { try assertNotSubmitted(try projectStore.read(dir)) }
}
