import Foundation

private let codeTemplateBatchOwners = Locked<Set<String>>([])

/// 写入正式材料前保存恢复日志。备份准备完成后才公开 pending 日志，重启恢复可重复执行。
struct CodeTemplateTransaction {
    let directory: String
    let dataDir: String
    var journal: JSON

    init(dataDir: String, projectDir: String, software: String, originals: [(String, Data?)]) throws {
        self.dataDir = dataDir
        let root = Path.join(dataDir, "code-template-transactions")
        let id = UUID().uuidString
        let preparing = Path.join(root, ".preparing-\(id)")
        directory = Path.join(root, id)
        try FS.mkdirp(preparing)
        defer { FS.remove(preparing) }
        var files: [JSON] = []
        for (index, original) in originals.enumerated() {
            let (target, bytes) = original
            let backup = "\(index).bin"
            if let bytes { try FS.writeAtomic(Path.join(preparing, backup), bytes) }
            files.append(.obj(["target": .string(target), "existed": .bool(bytes != nil), "backup": bytes == nil ? .null : .string(backup), "sha256": bytes.map { .string(sha256Hex($0)) } ?? .null]))
        }
        journal = .obj(["version": 1, "status": "pending", "projectDir": .string(projectDir), "softwareName": .string(software), "files": .array(files), "at": .string(isoNow())])
        try FS.writeJSONAtomic(Path.join(preparing, "journal.json"), journal)
        try FS.move(preparing, directory)
    }

    init(dataDir: String, directory: String) throws {
        self.dataDir = dataDir
        self.directory = directory
        guard let journal = try FS.readJSON(Path.join(directory, "journal.json")), journal["version"]?.int == 1 else { throw StudioError("代码模板恢复日志损坏：\(directory)") }
        self.journal = journal
    }

    mutating func markCommitted() throws {
        var committed = journal
        committed["status"] = "committed"
        try FS.writeJSONAtomic(Path.join(directory, "journal.json"), committed)
        journal = committed
        FS.remove(directory)
    }

    func restore() throws {
        guard journal["status"]?.string == "pending", let dir = journal["projectDir"]?.string, let name = journal["softwareName"]?.string else { throw StudioError("代码模板恢复日志状态无效：\(directory)") }
        try assertSafeSoftwareName(name)
        let paths = projectPaths(dir)
        let bundle = paths.bundle(name)
        let allowed = Set([Path.join(bundle, "\(name)\(CODE_SUFFIX).docx"), Path.join(bundle, "\(name)\(CODE_SUFFIX).pdf"), Path.join(bundle, "\(name)指南.txt"), paths.manifest, recordPath(dir), paths.regionIndex, ProjectStore(dataDir: dataDir).stateFile(dir)])
        let entries = journal["files"].items
        guard Set(entries.compactMap { $0["target"]?.string }) == allowed, entries.count == allowed.count else { throw StudioError("代码模板恢复日志文件清单无效：\(directory)") }
        // 先核对全部备份；缺失或损坏时不进行部分恢复。
        let snapshots = try entries.map { entry -> (String, Data?) in
            let target = entry["target"]!.jsString
            guard let existed = entry["existed"]?.bool else { throw StudioError("代码模板恢复记录无效") }
            guard existed else { return (target, nil) }
            guard let backup = entry["backup"]?.string, Rx.test(#"^[0-9]+\.bin$"#, backup) else { throw StudioError("代码模板恢复备份名无效") }
            let bytes = try FS.read(Path.join(directory, backup))
            guard sha256Hex(bytes) == entry["sha256"]?.string else { throw StudioError("代码模板恢复备份校验失败：\(target)") }
            return (target, bytes)
        }
        for (target, bytes) in snapshots {
            if let bytes { try FS.writeAtomic(target, bytes) }
            else {
                FS.remove(target)
                if FS.exists(target) { throw StudioError("无法清理未完成的代码材料：\(target)") }
            }
        }
        FS.remove(directory)
        if FS.exists(directory) { throw StudioError("材料已恢复，但日志无法清理：\(directory)") }
    }
}

private func codeTemplateTransactionDirectories(_ dataDir: String) throws -> [String] {
    let root = Path.join(dataDir, "code-template-transactions")
    guard FS.exists(root) else { return [] }
    guard let entries = FS.list(root) else { throw StudioError("代码模板恢复目录无法读取，请检查权限：\(root)") }
    return entries.filter { !$0.hasPrefix(".") }.sorted().map { Path.join(root, $0) }
}

extension StudioCore {
    /// 对已有交付包只更新代码材料；模板在本批开始时快照，逐项目失败不影响其余项目。
    public func applyCurrentCodeTemplate(_ directories: [String]) async -> JSON {
        let dirs = uniqued(directories.map(Path.resolve))
        let owner = Path.resolve(dataDir)
        guard codeTemplateBatchOwners.withLock({ $0.insert(owner).inserted }) else {
            return ["done": [], "failed": [], "skipped": JSON(dirs.map { "\(Path.basename($0))：已有代码模板批次正在执行" })]
        }
        defer { codeTemplateBatchOwners.withLock { $0.remove(owner) } }
        var done: [JSON] = []
        var failed: [String] = []
        var skipped: [String] = []
        do {
            guard try codeTemplateTransactionDirectories(dataDir).isEmpty else { throw StudioError("存在尚未恢复的代码模板更新，请重启软件完成恢复后再试") }
            let settings = try await settingsStore.get()
            guard Path.extname(settings.codeSource.path).lowercased() == ".docx" else {
                throw StudioError("请先在「设置 → 代码来源」选择新的 Word 代码模板")
            }
            let bytes = try FS.read(settings.codeSource.path)
            let template = try CodeWordTemplate(data: bytes)
            guard template.lines.filter({ !$0.jsTrimmed.isEmpty }).count > 3000 else {
                throw StudioError("代码模板的非空白代码行必须超过 3000 行")
            }
            let snapshot = Path.join(dataDir, "code-templates", "\(template.sha256).docx")
            if FS.exists(snapshot) {
                guard try FS.read(snapshot) == bytes else { throw StudioError("已保存的模板副本被修改，请重新导入") }
            } else { try FS.writeAtomic(snapshot, bytes) }
            let source: JSON = ["path": .string(snapshot), "extensions": [".java"]]
            let fontPlan = resolveFontPlan(settings.pdf)
            for (index, dir) in dirs.enumerated() {
                emit(.obj(["type": "code-template-batch", "current": .string(dir), "index": .number(Double(index)), "total": .number(Double(dirs.count))]))
                let queued = batch.list().items.contains { $0["projectDir"]?.string == dir && ["queued", "paused", "running"].contains($0["status"]?.string ?? "") }
                if queued || pipeline.isRunning(dir) {
                    skipped.append("\(Path.basename(dir))：正在运行或排队，请完成或移出队列后重试")
                    continue
                }
                do {
                    let result = try await pipeline.applyCodeTemplate(dir, source: source, template: template, fontPlan: fontPlan)
                    done.append(result.merging(["dir": .string(dir)]))
                } catch {
                    let message = "\(Path.basename(dir))：\(messageOf(error))"
                    failed.append(message)
                    try? await pipeline.log(dir, "批量应用代码模板失败：\(messageOf(error))", "error")
                }
            }
        } catch { failed.append(messageOf(error)) }
        emit(.obj(["type": "code-template-batch", "current": .null, "index": .number(Double(dirs.count)), "total": .number(Double(dirs.count))]))
        return .obj(["done": .array(done), "failed": JSON(failed), "skipped": JSON(skipped)])
    }

    /// 软件启动时在恢复批量队列之前调用；pending 恢复原字节，committed 只清理日志。
    @discardableResult
    public func recoverCodeTemplateTransactions() async throws -> [String] {
        let owner = Path.resolve(dataDir)
        guard codeTemplateBatchOwners.withLock({ $0.insert(owner).inserted }) else { throw StudioError("代码模板批次正在执行，不能同时恢复") }
        defer { codeTemplateBatchOwners.withLock { $0.remove(owner) } }
        var diagnostics: [String] = []
        for directory in try codeTemplateTransactionDirectories(dataDir) {
            let transaction = try CodeTemplateTransaction(dataDir: dataDir, directory: directory)
            if transaction.journal["status"]?.string == "committed" {
                FS.remove(directory)
                if FS.exists(directory) { throw StudioError("已完成的代码模板恢复日志无法清理：\(directory)") }
                continue
            }
            guard let dir = transaction.journal["projectDir"]?.string else { throw StudioError("代码模板恢复日志缺少项目路径") }
            try pipeline.running.withLock { table in
                guard table[dir] == nil else { throw StudioError("恢复日志对应项目正在运行，不能覆盖材料") }
                try transaction.restore()
            }
            diagnostics.append("已恢复中断的代码模板更新：\(transaction.journal["softwareName"].or("").jsString)")
        }
        let root = Path.join(dataDir, "code-template-transactions")
        for name in FS.list(root) ?? [] where name.hasPrefix(".preparing-") { FS.remove(Path.join(root, name)) }
        return diagnostics
    }
}

extension Pipeline {
    /// 在 running 的同一把锁内占用项目；开始处理、改名和移除等入口会看到这个占用。
    func applyCodeTemplate(_ dir: String, source: JSON, template: CodeWordTemplate, fontPlan: [String: FontPlanEntry]) async throws -> JSON {
        let (handle, job) = try running.withLock { table -> (RunHandle, Task<JSON, Error>) in
            guard table[dir] == nil else { throw StudioError("项目正在运行，未改动原交付包") }
            let handle = RunHandle(cancellable: false)
            let job = Task<JSON, Error> { try await self.replaceCodeTemplate(dir, source: source, template: template, fontPlan: fontPlan) }
            handle.task = Task {
                do { _ = try await job.value; return RunResult(status: "done") }
                catch { return RunResult(status: "failed", error: messageOf(error)) }
            }
            table[dir] = handle
            return (handle, job)
        }
        emit(.obj(["type": "project", "projectDir": .string(dir), "status": "running"]))
        defer {
            running.withLock { if $0[dir] === handle { $0[dir] = nil } }
            emit(.obj(["type": "project", "projectDir": .string(dir)]))
        }
        return try await job.value
    }

    private func replaceCodeTemplate(_ dir: String, source: JSON, template: CodeWordTemplate, fontPlan: [String: FontPlanEntry]) async throws -> JSON {
        guard let state = try projectStore.read(dir) else { throw StudioError("项目不存在") }
        let name = softwareName(state)
        try assertSafeSoftwareName(name)
        let paths = projectPaths(dir)
        let bundle = paths.bundle(name)
        guard FS.exists(bundle) else { throw StudioError("还没有交付包，请先完成项目") }
        // 已导入的项目无需规划或模型配置；已有指南和 TXT 即可只更新代码材料。
        guard FS.exists(Path.join(bundle, "\(name)指南.docx")), FS.exists(Path.join(bundle, "\(name)指南.txt")) else {
            throw StudioError("交付包缺少指南 Word 或 TXT，请先补齐材料")
        }
        let lines = template.lines.count
        let nonEmpty = template.lines.filter { !$0.jsTrimmed.isEmpty }.count
        guard nonEmpty > 3000 else { throw StudioError("代码必须超过 3000 个非空白行") }
        let operationSettings = try await settingsStore.get()
        let stamp = "\(timestampSlug())-\(randomHex(3))"
        let staging = Path.join(projectStore.stagingRoot, "\(Path.basename(dir))-code-template-\(stamp)")
        defer { FS.remove(staging) }
        let codeName = "\(name)\(CODE_SUFFIX)"
        let stagedBundle = Path.join(staging, name)
        try await log(dir, "按当前 Word 模板更新代码材料：\(lines) 行（非空白 \(nonEmpty) 行），验收正好 60 页")
        let fonts = try await renderCodeTemplate(template, project: staging, software: name, fontPlan: fontPlan)
        guard countPdfPages(fonts.pdfPath) == 60 else {
            throw StudioError("代码 PDF 实际 \(countPdfPages(fonts.pdfPath).map(String.init) ?? "无法识别") 页，必须正好 60 页；原交付包未改动")
        }
        let txtName = "\(name)指南.txt"
        let txt = try FS.readText(Path.join(bundle, txtName))
        let newTxt = try codeTemplateMetadata(txt, lineCount: lines)
        try FS.write(Path.join(stagedBundle, txtName), newTxt)
        let at = isoNow()
        let bodySha = sha256Hex(template.lines.joined(separator: "\n") + "\n")
        let pagination: JSON = ["templateSha256": .string(template.sha256), "targetPages": 60, "pdfPages": 60, "lineCount": .number(Double(lines)), "nonEmptyLines": .number(Double(nonEmpty))]
        var manifest = try FS.readJSON(paths.manifest) ?? ["softwareName": .string(name)]
        manifest["codeSource"] = source.merging(["fileCount": 1, "lineCount": .number(Double(lines)), "nonEmptyLines": .number(Double(nonEmpty)), "sha256": .string(bodySha)])
        manifest["codePagination"] = pagination
        manifest["codeDocument"] = "from-code-source"
        manifest["codeTemplateUpdatedAt"] = .string(at)
        manifest["pdfFonts"] = manifest["pdfFonts"].or(.emptyObject).merging(["code": fonts.summary])
        var artifacts = manifest["artifacts"].or(.emptyObject)
        for (role, file) in expectedBundleFiles(name, withCode: true, withPdf: true) where role.contains("code") { artifacts[role] = .string("\(name)/\(file)") }
        manifest["artifacts"] = artifacts
        let warning = pdfFontWarning("code", fonts)
        let files = (FS.list(bundle) ?? []).filter { !$0.hasPrefix(".") }
        let allFiles = uniqued(files + ["\(codeName).docx", "\(codeName).pdf"])
        let result: JSON = ["files": JSON(allFiles), "codePdfPages": 60, "withCode": true, "codeSha256": .string(bodySha), "code": ["fileCount": 1, "lineCount": .number(Double(lines)), "nonEmptyLines": .number(Double(nonEmpty)), "estimatedPages": 60], "warnings": JSON(warning.map { [$0] } ?? []), "pdfFonts": ["code": fonts.summary], "codePagination": pagination]

        // 所有生成与页数验收均在替换之前完成。保留可恢复的旧材料；写入失败恢复原字节。
        let modifiedFiles = [Path.join(bundle, "\(codeName).docx"), Path.join(bundle, "\(codeName).pdf"), Path.join(bundle, txtName), paths.manifest, recordPath(dir), paths.regionIndex, projectStore.stateFile(dir)]
        let originals = try modifiedFiles.map { file -> (String, Data?) in (file, FS.exists(file) ? try FS.read(file) : nil) }
        let archive = Path.join(paths.archive, "\(name)-代码模板-\(stamp)")
        try FS.mkdirp(archive)
        for (file, bytes) in originals { if let bytes { try FS.write(Path.join(archive, Path.basename(file)), bytes) } }
        var transaction = try CodeTemplateTransaction(dataDir: projectStore.dataDir, projectDir: dir, software: name, originals: originals)
        do {
            for file in ["\(codeName).docx", "\(codeName).pdf", txtName] { try FS.writeAtomic(Path.join(bundle, file), FS.read(Path.join(stagedBundle, file))) }
            try FS.writeJSONAtomic(paths.manifest, manifest)
            if var regions = try FS.readJSON(paths.regionIndex) {
                regions["regions"]?["artifact.docx.code"] = .obj(["label": "代码 Word", "summary": .string("Word 模板，共 \(lines) 行（非空白 \(nonEmpty) 行），PDF 60 页")])
                try FS.writeJSONAtomic(paths.regionIndex, regions)
            }
            try await updateRecord(dir) { record in
                record["codeSource"] = source.merging(["fileCount": 1, "lineCount": .number(Double(lines)), "nonEmptyLines": .number(Double(nonEmpty)), "sha256": .string(bodySha), "templateSha256": .string(template.sha256), "usedAt": .string(at)])
                record.append("history", .obj(["event": "code-template-updated", "at": .string(at), "codeSource": source, "codePdfPages": 60, "lineCount": .number(Double(lines)), "nonEmptyLines": .number(Double(nonEmpty)), "archive": .string(archive)]))
            }
            try await update(dir) { draft in
                if draft["request"] == nil { draft["request"] = .emptyObject }
                draft["request"]?["codeSource"] = source
                draft["request"]?["codeSourceLocked"] = true
                var build = draft["lastBuild"].or(.emptyObject)
                build = build.merging(result)
                build["at"] = .string(at)
                build["bundleDir"] = .string(bundle)
                build["pdfFonts"] = draft["lastBuild"]?["pdfFonts"].or(.emptyObject).merging(["code": fonts.summary]) ?? ["code": fonts.summary]
                let oldWarnings = draft["lastBuild"]?["warnings"].items.filter { !$0.jsString.contains("代码 PDF 字体不对") } ?? []
                build["warnings"] = .array(oldWarnings + result["warnings"].items)
                // 代码文档是软件自己换的，更新指纹，免得下次误以为是在软件外改的
                if build["bundleHashes"].isTruthy { build["bundleHashes"] = refreshBundleHashes(build, dir, draft["request"]?["softwareName"]?.jsString ?? "", files: ["\(codeName).docx", txtName]) }
                draft["lastBuild"] = build
                draft["codeTemplateUpdatedAt"] = .string(at)
                draft["warnings"] = .array(draft["warnings"].items.filter { warning in
                    let text = warning.jsString
                    return !text.contains("代码文档来自旧 skill 内置的固定正文") && !text.contains("代码 PDF 字体不对")
                } + result["warnings"].items.map { .string("构建：\($0.jsString)") })
                if draft["steps"]?["build"]?["status"]?.string == "done", let hash = self.stepInputHash("build", dir, draft, operationSettings) {
                    draft["steps"]?["build"]?["inputHash"] = .string(hash)
                    draft["steps"]?["build"]?["finishedAt"] = .string(at)
                }
                appendLog(&draft, "代码模板更新完成：PDF 正好 60 页，\(lines) 行（非空白 \(nonEmpty) 行）；旧材料已归档")
            }
            try transaction.markCommitted()
        } catch {
            do { try transaction.restore() }
            catch { throw StudioError("更新失败，恢复未完成；请重启软件自动恢复，备份在 \(archive)。\(messageOf(error))") }
            throw error
        }
        return result.merging(["archive": .string(archive)])
    }
}

/// 保留 TXT 的功能正文与环境字段，只同步当前代码的语言和真实源程序量。
func codeTemplateMetadata(_ original: String, lineCount: Int) throws -> String {
    var output = original
    for (label, value) in [("编程语言", "JAVA"), ("源程序量", "\(lineCount)行")] {
        let pattern = try NSRegularExpression(pattern: "(【\(label)】)(?:[ \\t]*\\r?\\n(?!【)[^\\r\\n]*|[^\\r\\n]*)")
        let range = NSRange(output.startIndex..., in: output)
        guard pattern.numberOfMatches(in: output, range: range) == 1 else { throw StudioError("TXT 缺少或重复【\(label)】字段，原材料未改动") }
        output = pattern.stringByReplacingMatches(in: output, range: range, withTemplate: "$1\(value)")
    }
    return output
}
