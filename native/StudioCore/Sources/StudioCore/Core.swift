import Foundation

/// 组装所有核心服务。App 和测试都通过它使用核心功能（对应 Electron 版的 core/index.mjs）。
public final class StudioCore: @unchecked Sendable {
    public let dataDir: String
    public let settingsStore: SettingsStore
    public let secrets: SecretStore
    public let callLog: CallLog
    public let llmLog: CallLog
    public let ledger: Ledger
    public let health: HealthStore
    public let projectStore: ProjectStore
    public let gateway: ImageGateway
    public let pipeline: Pipeline
    public let batch: BatchQueue
    public let http: HTTPClient
    public let appVersion: String
    let emitEvent: @Sendable (JSON) -> Void
    let indexFile: String
    let indexSerial = SerialQueue()
    let trashItem: @Sendable (String) throws -> Void

    /// - secrets：App 里用 LocalSecrets（secrets.json + 本机密钥文件）；测试用 MemorySecrets。
    public init(dataDir: String, secrets: SecretStore? = nil, http: HTTPClient = URLSessionHTTPClient(), visionImage: @escaping @Sendable (String) throws -> String = visionDataUrl, appVersion: String = "", onEvent: @escaping @Sendable (JSON) -> Void = { _ in }, gatewaySleep: (@Sendable (Double) async throws -> Void)? = nil, randomDelayMs: (@Sendable () -> Double)? = nil, llmRetryDelay: (@Sendable (Double) async throws -> Void)? = nil, trashItem: (@Sendable (String) throws -> Void)? = nil) async throws {
        try FS.mkdirp(dataDir)
        self.dataDir = dataDir
        self.trashItem = trashItem ?? { path in try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        self.http = http
        self.appVersion = appVersion
        let batchRef = Locked<BatchQueue?>(nil)
        let emit: @Sendable (JSON) -> Void = { event in
            onEvent(event)
            // 项目在批量之外跑完了（手动继续、确认规划、人工验收……），同步批量队列里那条记录
            if event["type"]?.string == "run-finished", event["status"]?.string == "done", let dir = event["projectDir"]?.string, let batch = batchRef.current {
                Task { await batch.settle { $0 == dir ? "done" : nil } }
            }
        }
        emitEvent = emit
        let settingsStore = SettingsStore(dataDir: dataDir)
        self.settingsStore = settingsStore
        let secrets = secrets ?? LocalSecrets.open(dataDir: dataDir)
        self.secrets = secrets
        let callLog = CallLog(dataDir: dataDir, fileName: "image-calls.jsonl")
        self.callLog = callLog
        let llmLog = CallLog(dataDir: dataDir, fileName: "llm-calls.jsonl")
        self.llmLog = llmLog
        let ledger = Ledger(dataDir: dataDir)
        self.ledger = ledger
        await ledger.initialize()
        let health = HealthStore(dataDir: dataDir)
        self.health = health
        let projectStore = ProjectStore(dataDir: dataDir)
        self.projectStore = projectStore
        indexFile = Path.join(dataDir, "projects-index.json")
        let pipelineRef = Locked<Pipeline?>(nil)
        let gateway = ImageGateway(
            getSettings: { try await settingsStore.get() },
            updateProvider: { id, fallback in
                _ = try? await settingsStore.update { settings in
                    if let index = settings.providers.firstIndex(where: { $0.id == id }) { fallback.apply(to: &settings.providers[index]) }
                }
            },
            secrets: secrets, ledger: ledger, health: health, callLog: callLog, http: http,
            onEvent: { event in
                pipelineRef.current?.onImageEvent(event)
                var wrapped = event
                wrapped["kind"] = event["type"]
                wrapped["type"] = "image"
                emit(wrapped)
            },
            sleepImpl: gatewaySleep ?? { try await sleepMs($0) },
            randomDelayMs: randomDelayMs ?? { Double(2000 + Int.random(in: 0..<3000)) }
        )
        self.gateway = gateway
        let pipeline = Pipeline(settingsStore: settingsStore, secrets: secrets, gateway: gateway, projectStore: projectStore, llmLog: llmLog, emit: emit, http: http, visionImage: visionImage, appVersion: appVersion, statsFile: Path.join(dataDir, "step-durations.json"), llmRetryDelay: llmRetryDelay ?? { try await sleepMs($0) })
        self.pipeline = pipeline
        pipelineRef.withLock { $0 = pipeline }
        batch = BatchQueue(dataDir: dataDir, settingsStore: settingsStore, pipeline: pipeline, emit: emit)
        batchRef.withLock { $0 = batch }
        callLog.onAppend { row in emit(.obj(["type": "call", "row": row])) }
    }

    // MARK: - 项目索引：工作区里由本软件管理的项目

    func readIndex() -> JSON { FS.readJSONQuiet(indexFile) ?? ["projects": []] }

    func updateIndex(_ mutate: @escaping @Sendable (inout [JSON]) -> Void) async throws {
        let file = indexFile
        try await indexSerial.run {
            var index = FS.readJSONQuiet(file) ?? ["projects": []]
            var projects = index["projects"].items
            mutate(&projects)
            index["projects"] = .array(projects)
            try FS.writeJSONAtomic(file, index)
        }
    }

    func summarizeScreens(_ screens: JSON?) -> JSON {
        let values = screens.fields.values.filter { $0["status"]?.string != "kept" }
        if values.isEmpty { return .null }
        let finished = values.filter { ["generated", "passed"].contains($0["status"]?.string ?? "") }.count
        return .obj(["total": .number(Double(values.count)), "finished": .number(Double(finished)), "failed": .number(Double(values.filter { $0["status"]?.string == "failed" }.count))])
    }

    func queueIndex() -> [String: JSON] {
        let items = batch.list().items
        var map: [String: JSON] = [:]
        var position = 0
        for item in items {
            let status = item["status"]?.string ?? ""
            if status == "queued" { position += 1 }
            let dir = item["projectDir"]?.string ?? ""
            // 同一项目在队列里有多条时，以「排队/运行中」的那条为准
            if map[dir] == nil || ["queued", "running"].contains(status) {
                map[dir] = item.merging(.obj(["position": status == "queued" ? .number(Double(position)) : .null]))
            }
        }
        return map
    }

    func summarize(_ entry: JSON, _ settings: Settings, _ queueByDir: [String: JSON]) -> JSON? {
        let dir = entry["dir"]?.jsString ?? ""
        guard let state = try? projectStore.read(dir) else { return nil }
        let alive = FS.exists(dir)
        let queued = queueByDir[dir]
        let live = pipeline.getProgress(dir)
        let running = pipeline.isRunning(dir)
        var steps = JSONObject()
        for step in PIPELINE_STEPS { steps[step] = state["steps"]?[step]?["status"] ?? "pending" }
        let lastBuild = state["lastBuild"]
        let timing = state["timing"]
        let screenCount = state["screens"].fields.count
        var summary = JSONObject()
        summary["dir"] = .string(dir)
        summary["name"] = state["request"]?["softwareName"] ?? .null
        summary["origin"] = state["origin"] ?? .null
        summary["grade"] = state["imported"]?["grade"].truthyValue ?? .null
        summary["readOnly"] = .bool(state["readOnly"].isTruthy)
        summary["status"] = !alive ? "missing" : state["readOnly"].isTruthy ? "readonly" : running ? "running" : state["status"] ?? "idle"
        summary["steps"] = .object(steps)
        summary["screens"] = .number(Double(screenCount > 0 ? screenCount : state["request"]?["screenCount"]?.int ?? 0))
        summary["hasCodeSource"] = .bool(codeSourceFor(state, settings).source?["path"].isTruthy ?? false)
        summary["hasBundle"] = .bool(lastBuild.isTruthy || state["origin"]?.string == "imported")
        summary["bundleFiles"] = lastBuild?["files"]?.array.map { .number(Double($0.count)) } ?? .null
        summary["pdfFontProblem"] = .bool(lastBuild?["pdfFonts"].fields.values.contains { $0.isObject && $0["ok"] == .bool(false) } ?? false)
        summary["timing"] = timing.isTruthy ? .obj(["totalMs": timing?["totalMs"] ?? .null, "completedMs": timing?["completedMs"].truthyValue ?? .null, "completedAt": timing?["completedAt"].truthyValue ?? .null, "lastMs": timing?["runs"]?.array?.last?["ms"].truthyValue ?? .null]) : .null
        summary["queue"] = queued.map { .obj(["id": $0["id"], "status": $0["status"], "position": $0["position"] ?? .null, "error": $0["error"].truthyValue ?? .null]) } ?? .null
        summary["progress"] = live.map { .obj(["step": $0["step"], "started": $0["started"], "stepStarted": $0["stepStarted"], "screens": summarizeScreens($0["screens"]), "detail": $0["detail"]]) } ?? .null
        summary["feedbackPending"] = .number(Double(state["feedback"].items.filter { $0["status"]?.string == "pending" }.count))
        summary["lastBuildAt"] = lastBuild?["at"].truthyValue ?? .null
        summary["lastError"] = state["lastError"].truthyValue ?? .null
        summary["warnings"] = .number(Double(state["warnings"].items.count))
        summary["addedAt"] = entry["addedAt"] ?? .null
        summary["updatedAt"] = state["log"]?.array?.last?["at"] ?? entry["addedAt"] ?? .null
        return .object(summary)
    }

    func emit(_ event: JSON) { emitEvent(event) }

    // MARK: - 设置

    public struct SettingsBundle: Sendable {
        public let settings: Settings
        public let providerKeys: [String: Bool]
        public let vendorKeys: [String: Bool]
    }

    public func getSettings() async throws -> SettingsBundle {
        let settings = try await settingsStore.get()
        var providerKeys: [String: Bool] = [:]
        for provider in settings.providers { providerKeys[provider.id] = await secrets.has(SecretIds.imageProvider(provider.id)) }
        var vendorKeys: [String: Bool] = [:]
        for vendor in settings.llm.vendors { vendorKeys[vendor.id] = await secrets.has(SecretIds.llmVendor(vendor.id)) }
        return SettingsBundle(settings: settings, providerKeys: providerKeys, vendorKeys: vendorKeys)
    }

    /// 只允许改这些顶层设置（线路、大模型有各自的接口）。
    @discardableResult
    public func updateSettings(_ patch: JSON) async throws -> Settings {
        let allowed = ["workspaceDir", "image", "pipeline", "txtFields", "codeDefaults", "codeSource", "pdf", "export"]
        var filtered = JSONObject()
        for (key, value) in patch.fields where allowed.contains(key) { filtered[key] = value }
        let next = try await settingsStore.update(patch: .object(filtered))
        // 调大「同时处理几个项目」后马上补上排队的项目
        if filtered["pipeline"] != nil { batch.kick() }
        return next
    }

    public func libreOfficeStatus() async -> String? {
        resetLibreOfficeCache()
        return await findLibreOffice()
    }

    // MARK: - 生图线路

    /// 保存线路；apiKey 为空表示不修改密钥。
    @discardableResult
    public func saveProvider(_ input: ImageProvider, apiKey: String? = nil) async throws -> String {
        let id = input.id.isEmpty ? "img-\(randomHex(3))" : input.id
        if input.baseUrl.jsTrimmed.isEmpty { throw StudioError("请填写接口地址") }
        if input.model.isEmpty { throw StudioError("请填写模型名") }
        var provider = input
        provider.id = id
        provider.baseUrl = Rx.replace("/+$", in: input.baseUrl.jsTrimmed, with: "")
        let saved = provider
        try await settingsStore.update { settings in
            if let index = settings.providers.firstIndex(where: { $0.id == id }) { settings.providers[index] = saved } else { settings.providers.append(saved) }
        }
        if let apiKey, !apiKey.jsTrimmed.isEmpty { try await secrets.set(SecretIds.imageProvider(id), apiKey.jsTrimmed) }
        await health.reset(id)
        return id
    }

    public func deleteProvider(_ id: String) async throws {
        try await settingsStore.update { $0.providers.removeAll { $0.id == id } }
        try await secrets.delete(SecretIds.imageProvider(id))
    }

    public func reorderProviders(_ ids: [String]) async throws {
        try await settingsStore.update { settings in
            var ordered = ids.compactMap { id in settings.providers.first { $0.id == id } }
            for provider in settings.providers where !ids.contains(provider.id) { ordered.append(provider) }
            settings.providers = ordered
        }
    }

    public func providerStatuses() async throws -> [String: JSON] {
        let settings = try await settingsStore.get()
        var result: [String: JSON] = [:]
        for provider in settings.providers {
            var status = gateway.providerStatus(provider)
            status["hedgeThresholdSec"] = .number(gateway.hedgeThresholdMs(provider, settings.image.hedge) / 1000)
            result[provider.id] = status
        }
        return result
    }

    public func probeProvider(_ id: String, realImage: Bool) async throws -> JSON { try await gateway.probe(id, realImage: realImage) }

    public func resetProviderHealth(_ id: String) async { await health.reset(id) }

    public func importLegacyProviders(file: String? = nil) async throws -> JSON {
        if let file { return try await StudioCore_importLegacyProviders(settingsStore: settingsStore, secrets: secrets, file: file) }
        return try await StudioCore_importLegacyProviders(settingsStore: settingsStore, secrets: secrets)
    }

    // MARK: - 大模型

    @discardableResult
    public func saveVendor(_ input: LlmVendor, apiKey: String? = nil) async throws -> String {
        let id = input.id.isEmpty ? "llm-\(randomHex(3))" : input.id
        if input.baseUrl.jsTrimmed.isEmpty { throw StudioError("请填写接口地址") }
        var vendor = input
        vendor.id = id
        vendor.baseUrl = Rx.replace("/+$", in: input.baseUrl.jsTrimmed, with: "")
        try await settingsStore.update { settings in
            if let index = settings.llm.vendors.firstIndex(where: { $0.id == id }) {
                var merged = vendor
                if merged.models.isEmpty { merged.models = settings.llm.vendors[index].models }
                settings.llm.vendors[index] = merged
            } else {
                settings.llm.vendors.append(vendor)
            }
        }
        if let apiKey, !apiKey.jsTrimmed.isEmpty { try await secrets.set(SecretIds.llmVendor(id), apiKey.jsTrimmed) }
        return id
    }

    public func deleteVendor(_ id: String) async throws {
        try await settingsStore.update { settings in
            for (step, value) in settings.llm.assignments where value?.vendorId == id { settings.llm.assignments[step] = .some(nil) }
            settings.llm.vendors.removeAll { $0.id == id }
        }
        try await secrets.delete(SecretIds.llmVendor(id))
    }

    public func fetchVendorModels(_ id: String) async throws -> [String] {
        let settings = try await settingsStore.get()
        guard let vendor = settings.llm.vendors.first(where: { $0.id == id }) else { throw StudioError("厂商不存在") }
        let apiKey = await secrets.get(SecretIds.llmVendor(id))
        if apiKey.isEmpty { throw StudioError("请先填写密钥") }
        let models = try await listModels(vendor: vendor, apiKey: apiKey, http: http)
        try await settingsStore.update { settings in
            if let index = settings.llm.vendors.firstIndex(where: { $0.id == id }) { settings.llm.vendors[index].models = models }
        }
        return models
    }

    public func testVendor(_ id: String, model: String, vision: Bool) async throws -> (reply: String, ms: Double) {
        let settings = try await settingsStore.get()
        guard let vendor = settings.llm.vendors.first(where: { $0.id == id }) else { throw StudioError("厂商不存在") }
        let apiKey = await secrets.get(SecretIds.llmVendor(id))
        let started = nowMs()
        let imageUrl = "data:image/png;base64,\(solidPng(64, 64, (220, 38, 38)).base64EncodedString())"
        let content: JSON = vision
            ? .array([["type": "text", "text": "这张图主要是什么颜色？只回答一个词。"], ["type": "image_url", "image_url": ["url": .string(vendor.preset == "zhipu" ? Rx.replaceFirst("^data:[^;]+;base64,", in: imageUrl, with: "") : imageUrl)]]])
            : "回复「连接正常」四个字。"
        let result = try await chatCompletion(vendor: vendor, apiKey: apiKey, model: model, messages: [["role": "user", "content": content]], maxTokens: 50, jsonMode: false, http: http, timeoutSec: 60)
        return (result.text.jsSlice(0, 100), nowMs() - started)
    }

    public func setAssignment(_ step: String, _ value: LlmAssignment?) async throws {
        guard LLM_STEPS[step] != nil else { throw StudioError("未知步骤") }
        try await settingsStore.update { $0.llm.assignments[step] = .some(value) }
    }

    // MARK: - 项目

    public func listProjects() async throws -> [JSON] {
        let index = readIndex()
        let settings = try await settingsStore.get()
        let queueByDir = queueIndex()
        let entries = index["projects"].items
        let batches = projectBatches(entries)
        return entries.compactMap { entry in
            guard var summary = summarize(entry, settings, queueByDir) else { return nil }
            if let batch = batches[entry["dir"]?.string ?? ""] { summary["batch"] = batch }
            return summary
        }
    }

    public func getProgress(_ dir: String) -> JSON? { pipeline.getProgress(dir) }
    public func stepEstimates() -> [String: Double] { pipeline.stepEstimates() }

    public func getProject(_ dir: String) async throws -> JSON {
        guard let state = try projectStore.read(dir) else { throw StudioError("项目不存在") }
        let plan = try? readPlan(dir)
        let content = FS.readJSONQuiet(projectPaths(dir).content)
        let paths = projectPaths(dir)
        var ids: [String] = []
        if let plan = plan ?? nil {
            ids = plan["screens"].items.map { $0["id"]?.jsString ?? "" }
        } else {
            ids = (content?["screens"].items ?? []).enumerated().map { $0.element["id"].or(.string(screenId($0.offset))).jsString }
        }
        var screens: [JSON] = []
        for id in ids {
            let file = paths.screenFile(id)
            let mtime = FS.mtimeMs(file)
            screens.append(.obj([
                "id": .string(id),
                "file": mtime != nil ? .string(file) : .null,
                "mtime": JSON.orNull(mtime),
                "prompt": .string(FS.readTextIfExists(paths.promptFile(id)) ?? ""),
                "state": state["screens"]?[id] ?? .emptyObject,
                "alternates": .array(listAlternates(dir, id)),
                "plan": (plan ?? nil)?["screens"].items.first { $0["id"]?.string == id } ?? .null,
            ]))
        }
        let name = state["request"]?["softwareName"]?.jsString ?? ""
        let bundleDir = paths.bundle(name)
        let bundleFiles = (FS.list(bundleDir) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let settings = try await settingsStore.get()
        let code = codeSourceFor(state, settings)
        return .obj([
            "dir": .string(dir), "state": state, "plan": (plan ?? nil) ?? .null, "content": content ?? .null, "screens": .array(screens),
            "bundleDir": .string(bundleDir), "bundleFiles": JSON(bundleFiles), "running": .bool(pipeline.isRunning(dir)), "progress": pipeline.getProgress(dir) ?? .null,
            "codeSource": .obj(["source": code.source ?? .null, "locked": .bool(code.locked), "global": settings.codeSource.path.isEmpty ? .null : settings.codeSource.json]),
        ])
    }

    /// request：{ softwareName, screenCount, emphasis, notes, platform, wantDesign, versionPolicy?, workspaceDir? }
    public func createProject(_ request: JSON) async throws -> String {
        let settings = try await settingsStore.get()
        let softwareName = request["softwareName"].text.jsTrimmed
        try assertSafeSoftwareName(softwareName)
        let workspace = request["workspaceDir"].truthyValue?.jsString ?? settings.workspaceDir
        let dir = Path.join(workspace, softwareName)
        if projectStore.exists(dir) { throw StudioError("已经有「\(softwareName)」这个项目了，可以在项目列表里找到它") }
        if FS.exists(dir), inspectProject(dir) != nil { throw StudioError("工作区里已经有「\(softwareName)」这个项目，请用「导入历史项目」或换个名字") }
        try FS.mkdirp(dir)
        // 版本号自动判断；代码来源用总设置里的（第一次生成交付包时记下来）
        let versionPolicy = request["versionPolicy"]?.string == "separate-metadata" ? "separate-metadata" : detectVersion(softwareName) != nil ? "in-name" : "none"
        var fields = request
        fields["softwareName"] = .string(softwareName)
        fields["versionPolicy"] = .string(versionPolicy)
        fields["codeSource"] = .null
        fields["workspaceDir"] = nil
        let state = newState(fields)
        try await projectStore.write(dir, state)
        let addedAt = isoNow()
        try await updateIndex { projects in
            if !projects.contains(where: { $0["dir"]?.string == dir }) { projects.insert(.obj(["dir": .string(dir), "addedAt": .string(addedAt), "origin": "created"]), at: 0) }
        }
        return dir
    }

    /// 批量新建：每行一个软件名，可选用逗号带上 截图数、重点功能、补充说明。
    public func createProjectsFromList(_ text: String, screenCount: Int?, platform: String, wantDesign: Bool) async throws -> (created: [String], errors: [String]) {
        let rows = parseBatchList(text)
        if rows.isEmpty { throw StudioError("没有读到软件名（每行一个）") }
        var created: [String] = []
        var errors: [String] = []
        var seen = Set<String>()
        for row in rows {
            do {
                if seen.contains(row.softwareName) { throw StudioError("列表里重复了") }
                seen.insert(row.softwareName)
                let dir = try await createProject(.obj([
                    "softwareName": .string(row.softwareName), "screenCount": JSON.orNull(row.screenCount ?? screenCount), "emphasis": .string(row.emphasis),
                    "notes": .string(row.notes), "platform": .string(platform), "wantDesign": .bool(wantDesign),
                ]))
                created.append(dir)
            } catch {
                errors.append("\(row.softwareName)：\(messageOf(error))")
            }
        }
        // 记下批次，历史项目里可以按批次一次选中
        if created.count > 1 {
            let batchId = "batch-\(randomHex(4))"
            let members = Set(created)
            try await updateIndex { projects in
                for index in projects.indices where members.contains(projects[index]["dir"]?.string ?? "") {
                    projects[index]["batchId"] = .string(batchId)
                }
            }
        }
        return (created, errors)
    }

    /// 从列表移除。deleteFolder 为 true 时连项目文件夹一起移到废纸篓（可以从废纸篓恢复）。
    public func removeFromList(_ dir: String, deleteFolder: Bool = false) async throws {
        if pipeline.isRunning(dir) { throw StudioError("项目正在运行，先停止") }
        if deleteFolder, FS.exists(dir) {
            let settings = try await settingsStore.get()
            let target = Path.resolve(dir)
            // 只读项目（比如 skill 自带的示例）的文件夹不是这个软件的，不删
            if (try? projectStore.read(dir))??["readOnly"].isTruthy == true { throw StudioError("只读项目的文件夹不能删除，只能从列表移除") }
            // 防止误删工作区、主目录这类上层文件夹，以及不像项目的文件夹
            let protected = [settings.workspaceDir, NSHomeDirectory(), Path.join(NSHomeDirectory(), "Desktop"), Path.join(NSHomeDirectory(), "Documents"), Path.join(NSHomeDirectory(), "Downloads"), "/"].map(Path.resolve)
            let markers = ["content.json", "screen-plan.json", "project-manifest.json", "generation-record.json", "screens"]
            // 工作区里直接的子文件夹（包括刚建、还空着的）可以删；工作区以外的必须看得出是项目文件夹
            let insideWorkspace = Path.dirname(target) == Path.resolve(settings.workspaceDir)
            if protected.contains(target) || Path.basename(target).isEmpty || !(insideWorkspace || markers.contains(where: { FS.exists(Path.join(target, $0)) })) {
                throw StudioError("这个文件夹看起来不是项目文件夹，没有删除：\(dir)")
            }
            try trashItem(target)
        }
        for item in batch.list().items where item["projectDir"]?.string == dir {
            await batch.remove(item["id"]?.string ?? "")
        }
        try await updateIndex { $0.removeAll { $0["dir"]?.string == dir } }
        await projectStore.remove(dir)
    }

    public func scanWorkspace(_ workspaceDir: String? = nil) async throws -> [JSON] {
        let settings = try await settingsStore.get()
        let store = projectStore
        return try StudioCore_scanWorkspace(workspaceDir ?? settings.workspaceDir) { store.exists($0) }
    }

    public func importProjects(_ dirs: [String]) async throws -> (imported: [String], failed: [String], timings: Int) {
        var imported: [String] = []
        var failed: [String] = []
        for dir in dirs {
            do {
                if projectStore.exists(dir) { continue }
                guard let info = inspectProject(dir) else { throw StudioError("不是项目文件夹") }
                let state = try createImportedState(dir, info)
                try await projectStore.write(dir, state)
                if !state["readOnly"].isTruthy { try await pipeline.adoptImported(dir) }
                let addedAt = isoNow()
                try await updateIndex { projects in
                    if !projects.contains(where: { $0["dir"]?.string == dir }) { projects.append(.obj(["dir": .string(dir), "addedAt": .string(addedAt), "origin": "imported"])) }
                }
                imported.append(dir)
            } catch {
                failed.append("\(Path.basename(dir))：\(messageOf(error))")
            }
        }
        let settings = try await settingsStore.get()
        let timings = await importLegacyTimings(settings.workspaceDir, callLog)
        return (imported, failed, timings)
    }

    public func renameSoftware(_ dir: String, _ newName: String) async throws -> String {
        let name = newName.jsTrimmed
        try assertSafeSoftwareName(name)
        if pipeline.isRunning(dir) { throw StudioError("项目正在运行，先停止") }
        if batch.list().items.contains(where: { $0["projectDir"]?.string == dir && ["queued", "running"].contains($0["status"]?.string ?? "") }) {
            throw StudioError("项目还在批量队列里，先从队列移除再改名")
        }
        guard let state = try projectStore.read(dir) else { throw StudioError("项目不存在") }
        let oldName = state["request"]?["softwareName"]?.jsString ?? ""
        if oldName == name { return dir }
        try await pipeline.updateRequest(dir, .obj(["softwareName": .string(name)]))
        // 文件夹名和软件名一致时，一并改名
        var finalDir = dir
        if Path.basename(dir) == oldName {
            let target = Path.join(Path.dirname(dir), name)
            if !FS.exists(target) {
                try FS.move(dir, target)
                try projectStore.move(dir, target)
                try await updateIndex { projects in
                    projects = projects.map { $0["dir"]?.string == dir ? $0.merging(.obj(["dir": .string(target)])) : $0 }
                }
                finalDir = target
            }
        }
        return finalDir
    }

    @discardableResult
    public func run(_ dir: String, _ options: RunOptions = RunOptions()) -> Task<RunResult, Never> {
        let task = pipeline.start(dir, options)
        return task
    }

    public func cancel(_ dir: String) { pipeline.cancel(dir) }

    // MARK: - 导出

    public func planExport(_ dirs: [String], targetDir: String, groupName: String = "") throws -> JSON {
        try StudioCore_planExport(dirs: dirs, targetDir: targetDir, projectStore: projectStore, groupName: groupName)
    }

    public func defaultExportGroupName() -> String { defaultGroupName() }

    public func exportBundles(_ dirs: [String], targetDir: String, conflict: String = "skip", groupName: String = "") async throws -> JSON {
        for dir in dirs where pipeline.isRunning(dir) { throw StudioError("「\(Path.basename(dir))」正在运行，等它跑完再导出") }
        let result = try StudioCore_exportBundles(dirs: dirs, targetDir: targetDir, projectStore: projectStore, conflict: conflict, groupName: groupName, trashItem: trashItem)
        try await settingsStore.update { $0.export.lastDir = targetDir }
        return result
    }

    // MARK: - PDF 与字体

    public func fontStatus() async throws -> JSON {
        let settings = try await settingsStore.get()
        let families = installedFontFamilies(refresh: true)
        let plan = resolveFontPlan(settings.pdf, families: families)
        var docs = JSONObject()
        for kind in DOC_FONT_ORDER {
            let doc = DOC_FONTS[kind]!
            docs[kind] = .obj([
                "label": .string(doc.label), "original": .string(doc.original), "installed": .bool(plan[kind]!.mode == "original"),
                "using": .string(plan[kind]!.label), "choice": .string(settings.pdf[kind]),
                "choices": .array(SUBSTITUTE_CHOICES[kind]!.map { .obj(["value": .string($0), "label": .string(SUBSTITUTES[$0]!.label)]) }),
            ])
        }
        return .obj(["detected": .bool(!families.isEmpty), "docs": .object(docs)])
    }

    public func installFonts(_ files: [String]) -> JSON { installFontFiles(files) }

    /// 批量只重导 PDF（一个个来；LibreOffice 本来就排队）。
    public func reexportPdfs(_ dirs: [String]) async -> JSON {
        var done: [JSON] = []
        var failed: [String] = []
        for (index, dir) in dirs.enumerated() {
            emit(.obj(["type": "pdf-reexport", "current": .string(dir), "index": .number(Double(index)), "total": .number(Double(dirs.count))]))
            do {
                let result = try await pipeline.reexportPdfs(dir)
                done.append(.obj(["dir": .string(dir), "warnings": result["warnings"] ?? []]))
            } catch {
                failed.append("\(Path.basename(dir))：\(messageOf(error))")
            }
        }
        emit(.obj(["type": "pdf-reexport", "current": .null, "index": .number(Double(dirs.count)), "total": .number(Double(dirs.count))]))
        return .obj(["done": .array(done), "failed": JSON(failed)])
    }

    public func inspectCodeSource(path: String, extensions: [String]) async throws -> JSON {
        let settings = try await settingsStore.get()
        let result = try collectCodeSource(path: path, extensions: extensions, excludeDirs: settings.codeDefaults.excludeDirs)
        return .obj([
            "fileCount": .number(Double(result.fileCount)), "lineCount": .number(Double(result.lineCount)), "nonEmptyLines": .number(Double(result.nonEmptyLines)),
            "estimatedPages": .number(Double(result.estimatedPages)), "files": JSON(Array(result.files.prefix(50))), "warnings": JSON(result.warnings),
        ])
    }

    /// 把交付包打成 zip，放在项目文件夹里。
    public func zipBundle(_ dir: String) throws -> String {
        guard let state = try projectStore.read(dir) else { throw StudioError("项目不存在") }
        let name = state["request"]?["softwareName"]?.jsString ?? ""
        let bundleDir = projectPaths(dir).bundle(name)
        var zip = ZipWriter()
        zip.addDirectory("\(name)/")
        for file in (FS.list(bundleDir) ?? []).sorted() where !file.hasPrefix(".") {
            zip.addFile("\(name)/\(file)", try FS.read(Path.join(bundleDir, file)))
        }
        let target = Path.join(dir, "\(name).zip")
        try FS.write(target, zip.finish())
        return target
    }

    // MARK: - 批量

    public func batchRemoveProjects(_ dirs: [String]) async {
        for item in batch.list().items where dirs.contains(item["projectDir"]?.string ?? "") && ["queued", "paused", "failed", "needs-attention"].contains(item["status"]?.string ?? "") {
            await batch.remove(item["id"]?.string ?? "")
        }
    }

    // MARK: - 记录

    public func queryCalls(limit: Int = 200, providerId: String? = nil) -> [JSON] { callLog.query(limit: limit, providerId: providerId) }
    public func queryLlmCalls(limit: Int = 200) -> [JSON] { llmLog.query(limit: limit) }
    /// 统计页数据；days 为 nil 时统计全部。
    public func usageStats(days: Int?) async throws -> JSON {
        let since = days.map { Calendar.current.date(byAdding: .day, value: -($0 - 1), to: Calendar.current.startOfDay(for: Date()))!.timeIntervalSince1970 * 1000 }
        return UsageStats.compute(imageCalls: callLog.all(), llmCalls: llmLog.all(), projects: try await listProjects(), sinceMs: since)
    }
    public func pendingJobs() -> [JSON] { ledger.list { ["needs-attention", "interrupted"].contains($0["state"]?.string ?? "") } }
    public func dismissJob(_ jobId: String) async { await ledger.dismiss(jobId) }

    /// 启动时：清理一天前失败构建留下的临时文件夹，续查异步任务，恢复批量队列。
    public func start() async {
        let stagingRoot = projectStore.stagingRoot
        for name in FS.list(stagingRoot) ?? [] {
            let target = Path.join(stagingRoot, name)
            if let mtime = FS.mtimeMs(target), nowMs() - mtime > 86_400_000 { FS.remove(target) }
        }
        _ = await gateway.resumePending()
        await batch.initialize()
        // 上次关软件前已经手动处理完的项目
        let projectStore = self.projectStore
        await batch.settle { dir in (try? projectStore.read(dir))??["status"]?.string }
    }
}

// 和同名方法区分开的自由函数别名
func StudioCore_importLegacyProviders(settingsStore: SettingsStore, secrets: SecretStore, file: String = Path.join(NSHomeDirectory(), ".codex", "software-manual-image-providers.json")) async throws -> JSON {
    try await importLegacyProviders(settingsStore: settingsStore, secrets: secrets, file: file)
}
func StudioCore_scanWorkspace(_ dir: String, isManaged: (String) -> Bool) throws -> [JSON] { try scanWorkspace(dir, isManaged: isManaged) }
func StudioCore_planExport(dirs: [String], targetDir: String, projectStore: ProjectStore, groupName: String) throws -> JSON {
    try planExport(dirs: dirs, targetDir: targetDir, projectStore: projectStore, groupName: groupName)
}
func StudioCore_exportBundles(dirs: [String], targetDir: String, projectStore: ProjectStore, conflict: String, groupName: String, trashItem: @escaping @Sendable (String) throws -> Void) throws -> JSON {
    try exportBundles(dirs: dirs, targetDir: targetDir, projectStore: projectStore, conflict: conflict, groupName: groupName, trashItem: trashItem)
}
