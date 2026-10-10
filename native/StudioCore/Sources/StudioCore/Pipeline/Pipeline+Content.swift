import Foundation

extension Pipeline {
    // MARK: - S5 文案

    func stepContent(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let settings = ctx.settings
        let state = try readState(dir)
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let paths = projectPaths(dir)
        let floor = max(300, settings.pipeline.featureTextFloor == 0 ? 300 : settings.pipeline.featureTextFloor)
        let name = softwareName(state)
        let existing = try FS.readJSON(paths.content)
        var existingById: [String: JSON] = [:]
        var existingOrder: [String] = []
        for (index, screen) in (existing?["screens"].items ?? []).enumerated() {
            let id = screen["id"].or(.string(screenId(index))).jsString
            if existingById[id] == nil { existingOrder.append(id) }
            existingById[id] = screen
        }
        let planScreens = plan["screens"].items
        let planHash = hashObject(.obj(["profile": plan["profile"] ?? .null, "titles": .array(planScreens.map { $0["title"] ?? .null })]))
        let neutral = !softwareNameNamesPlatform(name)
        var autoInstructions: [String: String] = [:]
        var inventories: [String: String] = [:]
        var targets: [JSON] = []
        var staleEdited: [String] = []
        var contentHashes: [(String, String)] = []
        for screen in planScreens {
            let id = screen["id"]?.jsString ?? ""
            let gate = state["screens"]?[id]?["gate"]
            if let inventory = gate?["inventory"].truthyValue { inventories[id] = inventory.jsString }
            let hash = hashObject(.obj([
                "title": screen["title"], "contract": screen["textContract"], "mustShow": screen["mustShow"], "sampleData": screen["sampleData"],
                "inventory": inventories[id].map(JSON.string) ?? .null,
            ]))
            contentHashes.append((id, hash))
            let old = existingById[id]
            let shot = state["screens"]?[id] ?? .emptyObject
            let forced = (ctx.forceContent?.contains(id) ?? false) || !(ctx.contentInstructions?[id] ?? "").isEmpty
            let unchanged = shot["contentHash"].isTruthy ? shot["contentHash"]?.string == hash : state["origin"]?.string == "imported"
            var keep = old?["text"].isTruthy == true && !forced && (shot["textEdited"].isTruthy || (unchanged && !shot["contentStale"].isTruthy))
            // 软件名没指明系统，旧说明里却有 iPhone、安卓 等字样：只改掉这些字样，其余保持
            let platformHits = keep && neutral ? findPlatformTerms([old?["text"].text ?? ""]) : []
            if !platformHits.isEmpty {
                keep = false
                autoInstructions[id] = platformFixInstruction(platformHits)
            }
            if !keep { targets.append(screen) }
            if keep, shot["textEdited"].isTruthy, shot["contentStale"].isTruthy { staleEdited.append(id) }
        }
        let existingOverviewValue = existing?["cover"]?["overview"]
        let overviewHits = neutral ? findPlatformTerms([existingOverviewValue.text]) : []
        if !overviewHits.isEmpty { autoInstructions["overview"] = platformFixInstruction(overviewHits) }
        // 用户自己的修改要求优先；自动去系统字样的要求只补在没有要求的部分
        let instructions = (ctx.contentInstructions ?? [:]).merging(autoInstructions) { user, auto in user.isEmpty ? auto : user }
        if !autoInstructions.isEmpty {
            try await log(dir, "说明里出现了系统或设备字样，改成通用说法：\(autoInstructions.keys.sorted().map { $0 == "overview" ? "封面介绍" : $0 }.joined(separator: "、"))")
        }
        let needOverview = !existingOverviewValue.isTruthy
            || (state["contentPlanHash"].isTruthy && state["contentPlanHash"]?.string != planHash && !state["overviewEdited"].isTruthy)
            || (ctx.forceContent?.contains("overview") ?? false)
            || !(instructions["overview"] ?? "").isEmpty
        var currentTexts: [String: String] = [:]
        for (id, screen) in existingById { currentTexts[id] = screen["text"].text }
        var written: [String: JSON] = [:]
        var overview = existingOverviewValue.text
        if !targets.isEmpty || needOverview {
            try await log(dir, "正在撰写 \(targets.count) 屏说明\(needOverview ? "和封面介绍" : "")…")
            var chunks: [[JSON]] = stride(from: 0, to: targets.count, by: 4).map { Array(targets[$0..<min($0 + 4, targets.count)]) }
            if chunks.isEmpty { chunks.append([]) }
            for (index, chunk) in chunks.enumerated() {
                let wantsOverview = needOverview && index == 0
                setProgress(dir, .obj(["detail": .string(targets.isEmpty ? "撰写封面介绍" : "撰写说明：第 \(min(targets.count, index * 4 + 1))–\(min(targets.count, index * 4 + chunk.count)) 屏（共 \(targets.count) 屏）")]))
                let result = try await callLlm("content", dir, ChatJsonRequest(
                    system: CONTENT_SYSTEM.replacingOccurrences(of: "{floor}", with: String(floor)),
                    user: contentUserPrompt(softwareName: softwareName(state), profile: plan["profile"], screens: chunk, inventories: inventories, needOverview: wantsOverview, existingOverview: overview, floor: floor, instructions: instructions, currentTexts: currentTexts) + platformNeutralRule(softwareName(state)),
                    schema: CONTENT_SCHEMA,
                    check: { contentCheck($0, screens: chunk, needOverview: wantsOverview, floor: floor) + platformProblems(name, "封面介绍或功能说明", [$0["overview"].text] + $0["screens"].items.flatMap { [$0["title"].text, $0["text"].text] }) },
                    temperature: 0.7,
                    maxTokens: 8000
                ))
                if wantsOverview { overview = (result["overview"]?.jsString ?? "undefined").jsTrimmed }
                for item in result["screens"].items { written[item["id"]?.jsString ?? ""] = item }
            }
        }
        let existingScreens = existing?["screens"].items ?? []
        let sameScreens = existing != nil && existingScreens.count == planScreens.count && planScreens.enumerated().allSatisfy { index, screen in
            existingScreens[index]["id"].or(.string(screenId(index))).jsString == screen["id"]?.jsString && existingScreens[index]["title"].isTruthy
        }
        let staleList = staleEdited
        let hashes = contentHashes
        let recordStaleWarning: @Sendable (inout JSON) -> Void = { draft in
            var warnings = draft["warnings"].items.filter { !($0.string ?? "").hasPrefix("截图已更换") }
            if !staleList.isEmpty { warnings.append(.string("截图已更换，但这些屏的说明是人工改过的，没有自动重写，请检查是否还和新截图一致：\(staleList.joined(separator: "、"))")) }
            draft["warnings"] = .array(warnings)
        }
        if existing != nil, sameScreens, targets.isEmpty, !needOverview {
            try await update(dir) { draft in
                for (id, hash) in hashes {
                    draft.mergeChild("screens", id, .obj(["contentHash": .string(hash), "contentStale": .bool(staleList.contains(id))]))
                }
                draft["contentPlanHash"] = .string(planHash)
                recordStaleWarning(&draft)
            }
            return StepOutcome(status: "done")
        }
        let featureMap = plan["featureMap"].or(.emptyObject)
        let regenerated = planScreens.contains { state["screens"]?[$0["id"]?.jsString ?? ""]?["providerId"].isTruthy == true }
        var content = existing ?? .emptyObject
        let request = state["request"] ?? .emptyObject
        content["softwareName"] = request["softwareName"]
        content["versionPolicy"] = request["versionPolicy"]
        if request["versionPolicy"]?.string == "separate-metadata", let version = request["applicableVersion"].truthyValue { content["applicableVersion"] = version }
        content["createdAt"] = request["createdAt"]
        content["screenshotCount"] = .number(Double(planScreens.count))
        content["screenCountReason"] = featureMap["coverageReason"].truthyValue ?? existing?["screenCountReason"]
        content["featureTier"] = 300
        content["imageRoute"] = regenerated || !(existing?["imageRoute"].isTruthy ?? false) ? "image-gateway" : existing!["imageRoute"]!
        content["cover"] = (existing?["cover"].or(.emptyObject) ?? .emptyObject).merging(.obj(["overview": .string(overview)]))
        content["screens"] = .array(planScreens.enumerated().map { index, screen in
            let id = screen["id"]?.jsString ?? ""
            let old = existingById[id] ?? .emptyObject
            let fresh = written[id]
            let shot = state["screens"]?[id] ?? .emptyObject
            let title = (fresh?["title"].truthyValue ?? old["title"].truthyValue ?? screen["title"] ?? .null).jsString.jsTrimmed
            let imageSize: JSON? = shot["width"].isTruthy ? .string("\(shot["width"]!.jsString)x\(shot["height"]?.jsString ?? "undefined")") : old["image_size"]
            return .obj([
                "id": .string(id),
                "title": .string(title),
                "caption": .string("图\(index + 1) \(title)"),
                "image": .string("screens/\(id).png"),
                "image_size": imageSize,
                "text_anchor": screen["textContract"]?["entry"].truthyValue ?? .string(title),
                "summary": .string(title),
                "text": .string((fresh?["text"].truthyValue ?? old["text"].truthyValue ?? "").jsString.jsTrimmed),
            ])
        })
        content["screenshotReview"] = nil
        try FS.writeJSONAtomic(paths.content, content)
        let writtenIds = Set(written.keys)
        let missing = planScreens.compactMap { screen -> String? in
            let id = screen["id"]?.jsString ?? ""
            return inventories[id] == nil ? id : nil
        }
        try await update(dir) { draft in
            for (id, hash) in hashes {
                var patch: JSON = .obj(["contentHash": .string(hash), "contentStale": .bool(staleList.contains(id))])
                if writtenIds.contains(id) { patch["textEdited"] = false }
                draft.mergeChild("screens", id, patch)
            }
            draft["contentPlanHash"] = .string(planHash)
            recordStaleWarning(&draft)
            var warnings = draft["warnings"].items.filter { !($0.string ?? "").hasPrefix("文案未按截图对账") }
            if !missing.isEmpty, !writtenIds.isEmpty { warnings.append(.string("文案未按截图对账：\(missing.joined(separator: "、"))（没有看图模型的抄录结果）")) }
            draft["warnings"] = .array(warnings)
        }
        return StepOutcome(status: "done")
    }

    // MARK: - S6 设计说明

    func stepDesign(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = try readState(dir)
        let paths = projectPaths(dir)
        guard var content = try FS.readJSON(paths.content) else { throw StudioError("还没有文案") }
        if !(state["request"]?["wantDesign"].isTruthy ?? false) {
            if content["design"] != nil {
                content["design"] = nil
                try FS.writeJSONAtomic(paths.content, content)
            }
            return StepOutcome(status: "skipped")
        }
        let designName = softwareName(state)
        let designHits = softwareNameNamesPlatform(designName) ? [] : findPlatformTerms(content["design"]?["sections"].items.flatMap { [$0["title"].text, $0["text"].text] } ?? [])
        let designInstruction = (ctx.designInstruction ?? "").isEmpty && !designHits.isEmpty ? platformFixInstruction(designHits) : ctx.designInstruction
        if !(content["design"]?["sections"]?.array?.isEmpty ?? true), !ctx.forceDesign, (designInstruction ?? "").isEmpty { return StepOutcome(status: "done") }
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        try await log(dir, "正在撰写设计说明…")
        let name = softwareName(state)
        let current = (content["design"]?["sections"].items ?? []).map { "\(templateText($0["title"]))\n\(templateText($0["text"]))" }.joined(separator: "\n\n")
        let result = try await callLlm("design", dir, ChatJsonRequest(
            system: DESIGN_SYSTEM,
            user: designUserPrompt(softwareName: softwareName(state), profile: plan["profile"], features: plan["featureMap"]?["features"].items ?? [], screens: plan["screens"].items, instruction: designInstruction, current: current) + platformNeutralRule(softwareName(state)),
            schema: DESIGN_SCHEMA,
            check: { designCheck($0) + platformProblems(name, "设计说明", $0["sections"].items.flatMap { [$0["title"].text, $0["text"].text] }) },
            temperature: 0.6,
            maxTokens: 8000
        ))
        content["design"] = .obj(["sections": .array(result["sections"].items.map { .obj(["title": .string($0["title"]?.jsString.jsTrimmed ?? ""), "text": .string($0["text"]?.jsString.jsTrimmed ?? "")]) })])
        try FS.writeJSONAtomic(paths.content, content)
        return StepOutcome(status: "done")
    }

    // MARK: - S7 回执

    func stepReceipt(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = try readState(dir)
        let paths = projectPaths(dir)
        guard var content = try FS.readJSON(paths.content) else { throw StudioError("还没有文案") }
        let tokensHash = hashObject(JSON(forbiddenBrandTokens(softwareName(state), extraTokens(state))))
        var reviewed: [JSON] = []
        var pending: [String] = []
        for index in 0..<content["screens"].items.count {
            let id = screenId(index)
            let sha = try sha256File(paths.screenFile(id))
            let gate = state["screens"]?[id]?["gate"]
            let ok = gate.isTruthy && gate?["sha"]?.string == sha && ["passed", "manual-passed"].contains(gate?["status"]?.string ?? "")
                && (gate?["tokensHash"]?.string == tokensHash || gate?["method"]?.string == "imported-receipt")
            if !ok { pending.append(id) }
            reviewed.append(.obj(["screenId": .string(id), "image": .string("screens/\(id).png"), "sha256": .string(sha)]))
        }
        if !pending.isEmpty { throw StudioError("这些截图还没有通过验收（或验收后图片被替换）：\(pending.joined(separator: "、"))") }
        let existing = content["screenshotReview"]
        let existingScreens = existing?["reviewedScreens"]?.array
        let sameReview = existing?["status"]?.string == "passed" && existingScreens?.count == reviewed.count && reviewed.enumerated().allSatisfy { index, item in
            let old = existingScreens?[index] ?? .emptyObject
            return old["screenId"] == item["screenId"] && old["image"] == item["image"] && old["sha256"] == item["sha256"]
        }
        if !sameReview {
            content["screenshotReview"] = .obj(["status": "passed", "reviewedScreens": .array(reviewed)])
            try FS.writeJSONAtomic(paths.content, content)
        }
        return StepOutcome(status: "done")
    }

    // MARK: - S8 构建

    func stepBuild(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let settings = ctx.settings
        let state = try readState(dir)
        let paths = projectPaths(dir)
        guard var content = try FS.readJSON(paths.content), content["screenshotReview"].isTruthy else { throw StudioError("没有审查回执，不能构建") }
        let name = softwareName(state)
        let request = state["request"] ?? .emptyObject
        let hasCodeDoc = FS.exists(Path.join(paths.bundle(name), "\(name)指南_代码-（JAVA）.docx"))
        let codeSource = codeSourceFor(state, settings).source
        let codePath = codeSource?["path"]?.string ?? ""
        if codePath.isEmpty, hasCodeDoc, !request["allowDropCodeDoc"].isTruthy {
            throw StudioError("现有交付包里有代码文档，但这个项目没有代码来源，重建后新交付包将不含代码文档（旧交付包会先归档）。请在「交付」里点「改用总设置的代码来源」或「确认不含代码文档」后再继续。")
        }
        if !codePath.isEmpty, !FS.exists(codePath) { throw StudioError("代码来源不存在：\(codePath)（在「设置 → 代码来源」里重新选择）") }
        let fontPlan = resolveFontPlan(settings.pdf)
        content["softwareName"] = .string(name)
        content["compileDate"] = request["compileDate"].truthyValue ?? .string(chineseDate())
        content["screens"] = .array(content["screens"].items.enumerated().map { index, screen in screen.merging(.obj(["image": .string("screens/\(screenId(index)).png")])) })
        var txtFields = settings.txtFields
        for (key, value) in request["txtFields"].fields { txtFields[key] = value.jsString }
        let languageOverride = request["txtFields"]?["language"].isTruthy ?? false
        let record = readRecord(dir)
        var provenanceScreens = JSONObject()
        for index in 0..<content["screens"].items.count {
            let id = screenId(index)
            let entry: JSON = record?["screens"]?[id] ?? .emptyObject
            let gate: JSON = state["screens"]?[id]?["gate"] ?? .emptyObject
            let fallbackSource: JSON = .string(state["origin"]?.string == "imported" ? "imported-from-skill" : "unknown")
            var item = JSONObject()
            item["source"] = entry["source"].or(fallbackSource)
            item["provider"] = entry["providerName"].or(entry["providerId"].or(.null))
            item["model"] = entry["model"].or(.null)
            item["generatedAt"] = entry["generatedAt"].or(.null)
            item["hedged"] = entry["hedged"].or(false)
            item["gate"] = gate["method"].or(.null)
            provenanceScreens[id] = .object(item)
        }
        let provenance: JSON = .obj([
            "builtBy": .string("软件指南生成器\(appVersion.isEmpty ? "" : " \(appVersion)")"),
            "recordFile": record != nil ? "generation-record.json" : .null,
            "screens": .object(provenanceScreens),
            "llm": record?["llm"].truthyValue ?? .emptyObject,
        ])
        let input = BuildInput(
            projectDir: dir, softwareName: name, content: content, codeSource: codeSource, txtFields: txtFields, languageOverride: languageOverride,
            excludeDirs: settings.codeDefaults.excludeDirs, floor: max(300, settings.pipeline.featureTextFloor == 0 ? 300 : settings.pipeline.featureTextFloor),
            extraBrandTokens: extraTokens(state), stagingRoot: projectStore.stagingRoot, provenance: provenance, fontPlan: fontPlan
        )
        let result = try await buildBundle(input) { message in
            self.setProgress(dir, .obj(["detail": .string(message)]))
            try? await self.log(dir, message)
        }
        let at = isoNow()
        try await update(dir) { draft in
            draft["lastBuild"] = JSON.obj(["at": .string(at)]).merging(result)
            // 记下这次用的代码来源：以后改总设置，已完成的项目不受影响
            draft["request"]?["codeSource"] = codeSource ?? .null
            draft["request"]?["codeSourceLocked"] = true
            var warnings = draft["warnings"].items.filter { !($0.string ?? "").hasPrefix("构建：") }
            for warning in result["warnings"].items { warnings.append(.string("构建：\(warning.jsString)")) }
            if !(result["withCode"].isTruthy) { warnings.append("构建：没有代码来源，本次没有生成代码文档（在「设置 → 代码来源」里设置）") }
            draft["warnings"] = .array(warnings)
            appendLog(&draft, "交付包已生成：\(jsJoin(result["files"].items, "、"))")
        }
        let usedAt = isoNow()
        try await updateRecord(dir) { record in
            record.append("history", .obj([
                "at": .string(isoNow()), "event": "build", "files": result["files"], "withPdf": result["withPdf"], "withCode": result["withCode"],
                "codeLines": result["code"]?["lineCount"] ?? .null, "codeSource": JSON.orNull(codePath.isEmpty ? nil : codePath), "codeSha256": result["codeSha256"], "pdfFonts": result["pdfFonts"],
            ]))
            record["codeSource"] = codePath.isEmpty ? .null : .obj([
                "path": .string(codePath), "extensions": codeSource?["extensions"], "fileCount": result["code"]?["fileCount"],
                "lineCount": result["code"]?["lineCount"], "sha256": result["codeSha256"], "usedAt": .string(usedAt),
            ])
        }
        return StepOutcome(status: "done")
    }

    // MARK: - 输入哈希

    func stepInputHash(_ step: String, _ dir: String, _ state: JSON, _ settings: Settings) -> String? {
        let paths = projectPaths(dir)
        let request = state["request"] ?? .emptyObject
        let platform = platformOf(state, settings)
        switch step {
        case "plan":
            // 不含软件名：改名不应触发重新规划（需要时可以手动强制重新规划）
            return hashObject(.obj(["screenCount": request["screenCount"], "emphasis": request["emphasis"], "notes": request["notes"], "platform": .string(platform)]))
        case "prompts":
            let plan = FS.readJSONQuiet(paths.screenPlan)
            let ui = FS.readJSONQuiet(paths.uiContract)
            var edited = JSONObject()
            for (id, screen) in state["screens"].fields { edited[id] = .bool(screen["promptEdited"].isTruthy) }
            return hashObject(.obj(["plan": plan?["screens"].truthyValue ?? .null, "ui": ui ?? .null, "platform": .string(platform), "target": .string(settings.image.targetSize), "edited": .object(edited)]))
        case "build":
            let content = FS.readJSONQuiet(paths.content)
            var shas = JSONObject()
            for (id, screen) in state["screens"].fields {
                if let sha = screen["imageSha"].truthyValue ?? screen["gate"]?["sha"] { shas[id] = sha }
            }
            var txt = JSONObject()
            for (key, value) in settings.txtFields.sorted(by: { $0.key < $1.key }) { txt[key] = .string(value) }
            for (key, value) in request["txtFields"].fields { txt[key] = value }
            return hashObject(.obj([
                "content": content ?? .null, "shas": .object(shas), "code": codeSourceFor(state, settings).source ?? .null,
                "txt": .object(txt), "name": request["softwareName"], "bundle": .bool(FS.exists(paths.bundle(softwareName(state)))),
            ]))
        default:
            return nil // 其余步骤内部自行增量判断
        }
    }
}
