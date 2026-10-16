import Foundation

let IMPORT_SKIP_DIRS: Set<String> = ["node_modules", "docs", "tools", "tmp", "archive", "尺寸兼容测试"]

/// 扫描工作区里的历史项目（只读）。分级：
/// - ready：文案、截图齐全，审查回执和当前截图一致，可以直接编辑
/// - needs-gate：有文案和截图，但回执缺失或对不上，需要重新验收
/// - readonly：只有交付包，没有 content.json，只能查看
public func scanWorkspace(_ workspaceDir: String, isManaged: (String) -> Bool = { _ in false }) throws -> [JSON] {
    guard let entries = FS.list(workspaceDir) else { throw StudioError("工作区不存在：\(workspaceDir)") }
    var results: [JSON] = []
    for name in entries {
        let dir = Path.join(workspaceDir, name)
        guard FS.isDirectory(dir), !name.hasPrefix("."), !IMPORT_SKIP_DIRS.contains(name) else { continue }
        guard var info = inspectProject(dir) else { continue }
        info["managed"] = .bool(isManaged(dir))
        results.append(info)
    }
    return results.sorted { ($0["mtime"]?.number ?? 0) > ($1["mtime"]?.number ?? 0) }
}

public func inspectProject(_ dir: String) -> JSON? {
    let paths = projectPaths(dir)
    let content = FS.readJSONQuiet(paths.content)
    let manifest = FS.readJSONQuiet(paths.manifest)
    let softwareName = (content?["softwareName"].truthyValue ?? manifest?["softwareName"].truthyValue)?.jsString ?? Path.basename(dir)
    let hasBundle = FS.isDirectory(paths.bundle(softwareName))
    let screenFiles = (FS.list(paths.screens) ?? []).filter { Rx.test("^screen-[0-9]+\\.png$", $0, "i") }.sorted()
    if content == nil, !hasBundle, screenFiles.isEmpty { return nil }
    let mtime = FS.mtimeMs(dir) ?? 0
    var grade = "readonly"
    let contentScreens = content?["screens"].items ?? []
    if !contentScreens.isEmpty, screenFiles.count >= contentScreens.count {
        let reviewed = content?["screenshotReview"]?["reviewedScreens"].items ?? []
        var receiptMatches = content?["screenshotReview"]?["status"]?.string == "passed" && reviewed.count == contentScreens.count
        if receiptMatches {
            for index in 0..<contentScreens.count {
                let id = screenId(index)
                let record = reviewed.first { $0["screenId"]?.string == id }
                let file = paths.screenFile(id)
                guard let record, FS.exists(file), record["sha256"]?.string == (try? sha256File(file)) else {
                    receiptMatches = false
                    break
                }
            }
        }
        grade = receiptMatches ? "ready" : "needs-gate"
    }
    return .obj([
        "dir": .string(dir),
        "name": .string(softwareName),
        "grade": .string(grade),
        "screens": .number(Double(contentScreens.isEmpty ? screenFiles.count : contentScreens.count)),
        "hasBundle": .bool(hasBundle),
        "hasPlan": .bool(FS.exists(paths.screenPlan)),
        "hasCodeDoc": .bool(hasBundle && FS.exists(Path.join(paths.bundle(softwareName), "\(softwareName)指南_代码-（JAVA）.docx"))),
        "mtime": .number(mtime),
    ])
}

/// 为历史项目建立状态（不改动项目文件夹里的任何文件）。
public func createImportedState(_ dir: String, _ info: JSON) throws -> JSON {
    let paths = projectPaths(dir)
    let content = FS.readJSONQuiet(paths.content)
    let manifest = FS.readJSONQuiet(paths.manifest)
    let name = info["name"]?.jsString ?? Path.basename(dir)
    let contentScreens = content?["screens"].items ?? []
    var request = JSONObject()
    request["softwareName"] = .string(name)
    request["versionPolicy"] = content?["versionPolicy"].truthyValue ?? manifest?["versionPolicy"].truthyValue ?? "in-name"
    request["applicableVersion"] = .string(content?["applicableVersion"].text ?? "")
    request["screenCount"] = contentScreens.isEmpty ? info["screens"].or(.null) : .number(Double(contentScreens.count))
    if let createdAt = content?["createdAt"].truthyValue ?? manifest?["createdAt"].truthyValue { request["createdAt"] = createdAt }
    if let date = [content?["contentDate"].text, manifest?["contentDate"].text].compactMap({ $0 }).first(where: validContentDate) {
        request["contentDate"] = .string(date)
    }
    if let date = [content?["earliestDate"].text, manifest?["earliestDate"].text].compactMap({ $0 }).first(where: validContentDate) {
        request["earliestDate"] = .string(date)
    }
    if let override = content?["compileDateOverride"] {
        request["compileDate"] = override
    } else if let compileDate = content?["compileDate"]?.string, let date = request["contentDate"]?.string, compileDate != contentDateChinese(date) {
        request["compileDate"] = .string(compileDate)
    }
    request["wantDesign"] = .bool(!(content?["design"]?["sections"]?.array?.isEmpty ?? true))
    request["origin"] = "imported"
    var state = newState(.object(request))
    let importedAt = isoNow()
    let grade = info["grade"]?.string ?? "readonly"
    let hasCodeDoc = info["hasCodeDoc"].isTruthy
    state["imported"] = .obj(["grade": .string(grade), "importedAt": .string(importedAt), "hadCodeDoc": .bool(hasCodeDoc)])
    state["readOnly"] = .bool(grade == "readonly")
    if hasCodeDoc {
        state.append("warnings", "这个历史项目的代码文档来自旧 skill 内置的固定正文，不是这个软件的代码。重建前请在「交付」里指定代码来源；不指定则重建后不含代码文档（旧交付包会先归档）。")
    }
    if grade == "readonly" { return state }

    let plan = FS.readJSONQuiet(paths.screenPlan)
    if plan != nil { state.setChild("steps", "plan", .obj(["status": "done", "finishedAt": .string(importedAt), "message": "沿用历史规划"])) }
    var promptsAll = !contentScreens.isEmpty
    for index in 0..<contentScreens.count where !FS.exists(paths.promptFile(screenId(index))) { promptsAll = false }
    // 缺标准提示词文件的历史项目也算「提示词」完成：只有真要重生某一屏时才补写那一屏的提示词
    if plan != nil { state.setChild("steps", "prompts", .obj(["status": "done", "finishedAt": .string(importedAt), "message": promptsAll ? .null : "部分提示词不是标准文件名，重生时再补写"])) }
    if !contentScreens.isEmpty {
        state.setChild("steps", "images", .obj(["status": "done", "finishedAt": .string(importedAt)]))
        state.setChild("steps", "content", .obj(["status": "done", "finishedAt": .string(importedAt)]))
        state.setChild("steps", "design", .obj(["status": .string(content?["design"]?["sections"]?.array?.isEmpty ?? true ? "skipped" : "done")]))
        let tokensHash = hashObject(JSON(forbiddenBrandTokens(name)))
        for index in 0..<contentScreens.count {
            let id = screenId(index)
            let file = paths.screenFile(id)
            guard FS.exists(file) else { continue }
            let sha = try sha256File(file)
            var screen: JSON = .obj(["imageSha": .string(sha)])
            if grade == "ready" {
                screen["gate"] = .obj(["status": "passed", "method": "imported-receipt", "sha": .string(sha), "tokensHash": .string(tokensHash), "checkedAt": .string(importedAt), "reasons": []])
            }
            state.setChild("screens", id, screen)
        }
        if grade == "ready" {
            state.setChild("steps", "gate", .obj(["status": "done", "finishedAt": .string(importedAt), "message": "沿用历史审查回执"]))
            state.setChild("steps", "receipt", .obj(["status": "done", "finishedAt": .string(importedAt)]))
            if info["hasBundle"].isTruthy { state.setChild("steps", "build", .obj(["status": "done", "finishedAt": .string(importedAt), "message": "沿用历史交付包"])) }
        }
    }
    let allDone = state["steps"].fields.values.allSatisfy { ["done", "skipped"].contains($0["status"]?.string ?? "") }
    state["status"] = .string(allDone ? "done" : "idle")
    return state
}

/// 历史生图记录（image-cli-summary.json）导入为调用记录，作为补发线的初始数据。
public func importLegacyTimings(_ workspaceDir: String, _ callLog: CallLog) async -> Int {
    var existingKeys = Set(callLog.all().filter { $0["role"]?.string == "history" }.map { "\($0["projectDir"]?.jsString ?? "undefined")|\($0["startedAt"]?.jsString ?? "undefined")|\($0["durationMs"]?.jsString ?? "undefined")" })
    var added = 0
    guard let entries = FS.list(workspaceDir) else { return 0 }
    for name in entries.sorted() {
        let projectDir = Path.join(workspaceDir, name)
        guard FS.isDirectory(projectDir), let summary = FS.readJSONQuiet(Path.join(projectDir, "tmp", "imagegen-cli", "image-cli-summary.json")), let invocations = summary["invocations"]?.array else { continue }
        for invocation in invocations where invocation["exitCode"]?.number == 0 {
            let providerId = invocation["providerId"].truthyValue?.jsString ?? "legacy-gpt-image-2-cli"
            let jobTimes = Rx.matches(#"completed in ([0-9.]+)s"#, invocation["stderrTail"].text).compactMap { Double($0[1] ?? "") }.map { $0 * 1000 }
            var durations = jobTimes
            if durations.isEmpty, invocation["jobCount"]?.number == 1, let duration = invocation["durationMs"]?.number, duration > 0 { durations = [duration] }
            let startedAt = invocation["startedAt"] ?? .null
            for duration in durations {
                let rounded = jsRound(duration)
                let key = "\(projectDir)|\(startedAt.jsString)|\(JSON.formatNumber(rounded))"
                if existingKeys.contains(key) { continue }
                existingKeys.insert(key)
                await callLog.append(.obj([
                    "ts": startedAt, "projectDir": .string(projectDir), "providerId": .string(providerId), "model": invocation["model"].truthyValue ?? summary["model"],
                    "role": "history", "ok": true, "kind": "success", "durationMs": .number(rounded), "startedAt": startedAt,
                ]))
                added += 1
            }
        }
    }
    return added
}

/// 从旧 skill 的线路配置（~/.codex/software-manual-image-providers.json）导入线路和密钥。
/// 只读取，不修改旧文件；密钥加密保存在本软件里。
public func importLegacyProviders(settingsStore: SettingsStore, secrets: SecretStore, file: String = Path.join(NSHomeDirectory(), ".codex", "software-manual-image-providers.json")) async throws -> JSON {
    guard let legacy = try FS.readJSON(file) else { throw StudioError("没有找到旧线路配置：\(file)") }
    let rows = legacy.array ?? legacy["providers"].items
    var imported: [String] = []
    var skipped: [String] = []
    var providers = try await settingsStore.get().providers
    for row in rows {
        guard let id = row["id"].truthyValue?.jsString else { continue }
        let protocolName = row["protocol"].truthyValue?.jsString ?? "cli"
        if protocolName == "cli" {
            skipped.append("\(id)（命令行路线依赖 Codex 自带脚本，新软件不支持；如果它是 OpenAI 兼容中转，可以手动按「OpenAI 兼容」添加）")
            continue
        }
        let preset = protocolName == "async" ? "apimart-async" : "openai-sync"
        let size = row["size"].text
        let sizeIsRatio = Rx.test(#"^[0-9]+(?:\.[0-9]+)?:[0-9]+(?:\.[0-9]+)?$"#, size)
        let model = row["model"].truthyValue?.jsString ?? "gpt-image-2"
        var provider = newProviderFromPreset(preset, id: id, name: id)
        provider.baseUrl = Rx.replace("/+$", in: row["baseUrl"].text, with: "")
        provider.model = model
        provider.modelGroup = Rx.test(#"2\.5"#, model) ? "gpt-image-2.5" : model
        provider.enabled = row["enabled"] != .bool(false)
        if sizeIsRatio {
            provider.sizeMode = "ratio"
        } else if !size.isEmpty {
            provider.sizeMode = "pixel"
            provider.pixelSize = size
        }
        if preset == "openai-sync", provider.sizeMode == "pixel", !size.isEmpty, size != "864x1824" { provider.pixelSize = "864x1824" }
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            // 保留原有的其他字段，用旧配置覆盖这些
            var merged = providers[index]
            merged.name = provider.name
            merged.enabled = provider.enabled
            merged.preset = provider.preset
            merged.baseUrl = provider.baseUrl
            merged.model = provider.model
            merged.modelGroup = provider.modelGroup
            merged.sizeMode = provider.sizeMode
            merged.pixelSize = provider.pixelSize
            merged.ratios = provider.ratios
            merged.quality = provider.quality
            merged.concurrency = provider.concurrency
            merged.hardTimeoutSec = provider.hardTimeoutSec
            merged.hedgeDefaultSec = provider.hedgeDefaultSec
            merged.mapping = provider.mapping
            providers[index] = merged
        } else {
            providers.append(provider)
        }
        if let apiKey = row["apiKey"].truthyValue?.jsString {
            try await secrets.set(SecretIds.imageProvider(provider.id), apiKey)
        } else if let envName = row["apiKeyEnv"].truthyValue?.jsString, let value = ProcessInfo.processInfo.environment[envName], !value.isEmpty {
            try await secrets.set(SecretIds.imageProvider(provider.id), value)
        }
        imported.append(provider.id)
    }
    let finalProviders = providers
    try await settingsStore.update { $0.providers = finalProviders }
    return .obj(["imported": JSON(imported), "skipped": JSON(skipped)])
}
