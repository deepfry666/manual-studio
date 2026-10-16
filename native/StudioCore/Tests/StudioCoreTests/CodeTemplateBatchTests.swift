import Foundation
import Testing
@testable import StudioCore

@Suite("历史项目批量代码模板", .serialized)
struct CodeTemplateBatchTests {
    @Test("TXT 只同步语言和源程序量，保留功能与环境文案")
    func txtMetadata() throws {
        let original = "【开发环境】自定义环境\r\n【编程语言】Swift\r\n【源程序量】27行\r\n【软件的主要功能】\r\n我的功能正文\r\n"
        #expect(try codeTemplateMetadata(original, lineCount: 3322) == "【开发环境】自定义环境\r\n【编程语言】JAVA\r\n【源程序量】3322行\r\n【软件的主要功能】\r\n我的功能正文\r\n")
        let multiline = "【编程语言】\nSwift\n【源程序量】\n27行\n【软件的主要功能】\n保留正文\n"
        #expect(try codeTemplateMetadata(multiline, lineCount: 3322) == "【编程语言】JAVA\n【源程序量】3322行\n【软件的主要功能】\n保留正文\n")
        #expect(throws: StudioError.self) { try codeTemplateMetadata("【编程语言】Swift", lineCount: 3322) }
    }

    @Test("真实转换批量更新只读历史包，单项失败继续、无 AI、保存恢复与归档", .timeLimit(.minutes(4)))
    func batchExistingProjects() async throws {
        let uiRoot = ProcessInfo.processInfo.environment["MS_CODE_TEMPLATE_UI_DIR"]
        let root = try uiRoot ?? FS.makeTempDirectory(prefix: "code-batch-qa-")
        try FS.mkdirp(root)
        defer { if uiRoot == nil { FS.remove(root) } }
        let network = MockNetwork() // 没有任何联网处理器；调用网络会报错。
        let dataDir = Path.join(root, "data")
        let core = try await StudioCore(dataDir: dataDir, secrets: MemorySecrets(), http: network)
        try await core.importCodeTemplate()
        let names = ["历史批量甲 V1.0", "损坏TXT V1.0", "历史批量乙 V1.0"]
        var dirs: [String] = []
        var kept: [(String, Data)] = []
        for name in names {
            let dir = Path.join(root, name)
            dirs.append(dir)
            let paths = projectPaths(dir)
            let bundle = paths.bundle(name)
            try FS.mkdirp(bundle)
            let txt = name.hasPrefix("损坏") ? "错误TXT" : "【开发环境】保留环境\r\n【编程语言】Swift\r\n【源程序量】100行\r\n【软件的主要功能】\r\n保留自定义功能\r\n"
            try FS.write(Path.join(bundle, "\(name)指南.txt"), txt)
            for suffix in ["指南.docx", "指南.pdf", "\(CODE_SUFFIX).docx", "\(CODE_SUFFIX).pdf"] {
                try FS.write(Path.join(bundle, "\(name)\(suffix)"), "旧材料：\(suffix)")
            }
            try FS.write(Path.join(paths.screens, "screen-01.png"), makePng())
            try FS.writeJSONAtomic(paths.content, ["softwareName": .string(name), "custom": "keep"])
            var state = newState(["softwareName": .string(name), "origin": "imported"])
            state["status"] = "readonly"
            state["readOnly"] = true
            state["steps"]?["build"] = ["status": "done", "inputHash": "old"]
            state["warnings"] = ["这个历史项目的代码文档来自旧 skill 内置的固定正文，不是这个软件的代码。", "指南提醒"]
            state["lastBuild"] = ["at": "old", "pdfPages": 3, "pdfFonts": ["guide": ["ok": true, "intended": "guide-original"]], "warnings": ["原指南提醒"]]
            try await core.projectStore.write(dir, state)
            try FS.writeJSONAtomic(paths.manifest, ["softwareName": .string(name), "custom": "keep", "pdfFonts": ["guide": ["ok": true]]])
            try FS.writeJSONAtomic(recordPath(dir), ["screens": ["screen-01": ["source": "imported"]], "llm": ["legacy": "keep"], "history": []])
            for file in [Path.join(bundle, "\(name)指南.docx"), Path.join(bundle, "\(name)指南.pdf"), paths.content, Path.join(paths.screens, "screen-01.png")] {
                kept.append((file, try FS.read(file)))
            }
        }
        try FS.writeJSONAtomic(Path.join(dataDir, "projects-index.json"), ["projects": .array(dirs.map { ["dir": .string($0), "origin": "imported", "addedAt": .string(isoNow())] })])
        let badBundle = projectPaths(dirs[1]).bundle(names[1])
        let badFiles = try (FS.list(badBundle) ?? []).map { name -> (String, Data) in let file = Path.join(badBundle, name); return (file, try FS.read(file)) }
        let result = await core.applyCurrentCodeTemplate(dirs + [dirs[0]])
        #expect(result["done"].items.count == 2, "\(result.serialized())")
        #expect(result["failed"].items.count == 1, "\(result.serialized())")
        #expect(result["skipped"].items.isEmpty)
        for (file, bytes) in kept { #expect(try FS.read(file) == bytes, "保持 \(Path.basename(file)) 原字节") }
        for (file, bytes) in badFiles { #expect(try FS.read(file) == bytes, "失败项目不得改变 \(Path.basename(file))") }
        for index in [0, 2] {
            let dir = dirs[index]
            let name = names[index]
            let paths = projectPaths(dir)
            let bundle = paths.bundle(name)
            #expect(countPdfPages(Path.join(bundle, "\(name)\(CODE_SUFFIX).pdf")) == 60)
            let code = try CodeWordTemplate(data: FS.read(Path.join(bundle, "\(name)\(CODE_SUFFIX).docx")))
            #expect(code.lines.count == 3322)
            #expect(code.lines.filter { !$0.jsTrimmed.isEmpty }.count == 3229)
            #expect(try FS.readText(Path.join(bundle, "\(name)指南.txt")).contains("【源程序量】3322行"))
            let state = try #require(try core.projectStore.read(dir))
            #expect(state["status"]?.string == "readonly")
            #expect(state["lastBuild"]?["pdfPages"]?.int == 3)
            #expect(state["lastBuild"]?["codePdfPages"]?.int == 60)
            #expect(state["lastBuild"]?["pdfFonts"]?["guide"]?["intended"]?.string == "guide-original")
            #expect(state["request"]?["codeSourceLocked"]?.bool == true)
            #expect(state["warnings"].items.contains("指南提醒"))
            #expect(!state["warnings"].items.contains { $0.jsString.contains("旧 skill") })
            #expect(state["steps"]?["build"]?["inputHash"]?.string == core.pipeline.stepInputHash("build", dir, state, try await core.settingsStore.get()))
            let manifest = try readJSONFile(paths.manifest)
            #expect(manifest["custom"] == "keep")
            #expect(manifest["codePagination"]?["targetPages"]?.int == 60)
            #expect(manifest["codeSource"]?["nonEmptyLines"]?.int == 3229)
            let record = try readJSONFile(recordPath(dir))
            #expect(record["llm"]?["legacy"] == "keep")
            #expect(record["screens"]?["screen-01"]?["source"] == "imported")
            #expect(record["history"].items.last?["event"]?.string == "code-template-updated")
            let archive = try #require(result["done"].items.first { $0["dir"]?.string == dir }?["archive"]?.string)
            #expect(try FS.readText(Path.join(archive, "\(name)\(CODE_SUFFIX).docx")) == "旧材料：\(CODE_SUFFIX).docx")
            let restored = try #require(try ProjectStore(dataDir: dataDir).read(dir))
            #expect(restored["request"]?["codeSource"] == state["request"]?["codeSource"])
            #expect(core.pipeline.isRunning(dir) == false)
            if let qa = ProcessInfo.processInfo.environment["MS_TEMPLATE_QA_DIR"] {
                try FS.copy(Path.join(bundle, "\(name)\(CODE_SUFFIX).docx"), Path.join(qa, "\(name).docx"))
                try FS.copy(Path.join(bundle, "\(name)\(CODE_SUFFIX).pdf"), Path.join(qa, "\(name).pdf"))
            }
        }
        #expect(!FS.exists(Path.join(dataDir, "llm-calls.jsonl")))
        #expect(!FS.exists(Path.join(dataDir, "image-calls.jsonl")))
    }

    @Test("运行与排队项目跳过，非 Word 设置拒绝批量修改")
    func skipBusyAndInvalidTemplate() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let dir = try await ctx.create("排队旧项目 V1.0")
        try await ctx.core.importCodeTemplate()
        await ctx.core.batch.pause()
        await ctx.core.batch.enqueue([dir])
        let before = try #require(try ctx.core.projectStore.read(dir))
        let result = await ctx.core.applyCurrentCodeTemplate([dir])
        #expect(result["skipped"].items.count == 1)
        #expect(result["done"].items.isEmpty)
        #expect(try ctx.core.projectStore.read(dir) == before)
        await ctx.core.batchRemoveProjects([dir])
        let handle = Pipeline.RunHandle(cancellable: false)
        handle.task = Task { RunResult(status: "done") }
        ctx.core.pipeline.running.withLock { $0[dir] = handle }
        let active = await ctx.core.applyCurrentCodeTemplate([dir])
        #expect(active["skipped"].items.count == 1)
        #expect(try ctx.core.projectStore.read(dir) == before)
        ctx.core.pipeline.running.withLock { $0[dir] = nil }
        let source = Path.join(ctx.root, "code.java")
        try FS.write(source, "class A {}")
        try await ctx.core.updateSettings(["codeSource": ["path": .string(source), "extensions": [".java"]]])
        let rejected = await ctx.core.applyCurrentCodeTemplate([dir])
        #expect(rejected["failed"].items.count == 1)
        #expect(try ctx.core.projectStore.read(dir) == before)
    }

    @Test("代码放不进60页时拒绝交付，旧文件和来源锁定保持不变")
    func rejectsOverflowWithoutMutation() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let name = "分页溢出旧项目 V1.0"
        let dir = try await fakeBuiltProject(ctx, name, ["\(name)指南.docx", "\(name)指南.txt", "\(name)\(CODE_SUFFIX).docx", "\(name)\(CODE_SUFFIX).pdf"])
        let bundle = projectPaths(dir).bundle(name)
        try FS.write(Path.join(bundle, "\(name)指南.txt"), "【编程语言】JAVA\n【源程序量】2000行\n【软件的主要功能】\n保留原文\n")
        let source = try ZipReader(FS.read(CodeWordTemplate.bundledPath))
        var modified = ZipWriter()
        for entry in source.entries {
            if entry.isDirectory { modified.addDirectory(entry.name); continue }
            var bytes = try source.read(entry)
            if entry.name == "word/document.xml" {
                var xml = String(decoding: bytes, as: UTF8.self)
                let pattern = try NSRegularExpression(pattern: "<w:t(?:\\s[^>]*)?>")
                let range = try #require(pattern.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml))?.range)
                let index = try #require(Range(range, in: xml)).upperBound
                xml.insert(contentsOf: String(repeating: "超长代码", count: 4000), at: index)
                bytes = Data(xml.utf8)
            }
            modified.addFile(entry.name, bytes)
        }
        let template = Path.join(ctx.root, "overflow.docx")
        try FS.write(template, modified.finish())
        try await ctx.core.importCodeTemplate(template)
        let before = try #require(try ctx.core.projectStore.read(dir))
        let originals = try (FS.list(bundle) ?? []).map { file -> (String, Data) in let path = Path.join(bundle, file); return (path, try FS.read(path)) }
        let result = await ctx.core.applyCurrentCodeTemplate([dir])
        #expect(result["done"].items.isEmpty)
        #expect(result["failed"].items.count == 1)
        #expect(result["failed"].items[0].jsString.contains("60页"))
        for (path, bytes) in originals { #expect(try FS.read(path) == bytes) }
        #expect(try ctx.core.projectStore.read(dir)?["request"] == before["request"])
        #expect(try ctx.core.projectStore.read(dir)?["lastBuild"] == before["lastBuild"])
        #expect(!ctx.core.pipeline.isRunning(dir))
        #expect(ctx.relay.submits.isEmpty)
    }


    @Test("中断后的事务启动恢复原材料、来源锁定与元数据，已提交事务只清日志")
    func restartTransactionRecovery() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let name = "恢复旧项目 V1.0"
        let dir = try await fakeBuiltProject(ctx, name, ["\(name)指南.docx", "\(name)指南.txt", "\(name)\(CODE_SUFFIX).docx"])
        let paths = projectPaths(dir)
        let bundle = paths.bundle(name)
        try FS.writeJSONAtomic(paths.manifest, ["codeSource": ["path": "old-template.docx"], "custom": "keep"])
        try FS.writeJSONAtomic(recordPath(dir), ["history": [["event": "old-build"]]])
        try await ctx.core.projectStore.update(dir) { state in
            state["request"]?["codeSource"] = ["path": "old-template.docx", "extensions": [".java"]]
            state["request"]?["codeSourceLocked"] = true
        }
        let targets = [Path.join(bundle, "\(name)\(CODE_SUFFIX).docx"), Path.join(bundle, "\(name)\(CODE_SUFFIX).pdf"), Path.join(bundle, "\(name)指南.txt"), paths.manifest, recordPath(dir), paths.regionIndex, ctx.core.projectStore.stateFile(dir)]
        let originals = try targets.map { path -> (String, Data?) in (path, FS.exists(path) ? try FS.read(path) : nil) }
        let transaction = try CodeTemplateTransaction(dataDir: ctx.dataDir, projectDir: dir, software: name, originals: originals)
        // 模拟进程在文件已部分替换、状态已写入、commit 标记之前退出。
        for target in targets { try FS.writeAtomic(target, "未完成的新材料") }
        let recoveryCore = try await StudioCore(dataDir: ctx.dataDir, secrets: MemorySecrets(), http: MockNetwork())
        let blocked = await recoveryCore.applyCurrentCodeTemplate([dir])
        #expect(blocked["failed"].items.first?.jsString.contains("尚未恢复") == true)
        let diagnostics = try await recoveryCore.recoverCodeTemplateTransactions()
        #expect(diagnostics.count == 1)
        for (target, bytes) in originals {
            if let bytes { #expect(try FS.read(target) == bytes) }
            else { #expect(!FS.exists(target), "原来不存在的文件应清理") }
        }
        #expect(!FS.exists(transaction.directory))
        #expect(try recoveryCore.projectStore.read(dir)?["request"]?["codeSource"]?["path"]?.string == "old-template.docx")
        #expect(try await recoveryCore.recoverCodeTemplateTransactions().isEmpty)
        // 已成功提交但清理日志前退出：新材料不回退。
        let committed = try CodeTemplateTransaction(dataDir: ctx.dataDir, projectDir: dir, software: name, originals: originals)
        var marker = committed.journal
        marker["status"] = "committed"
        try FS.writeJSONAtomic(Path.join(committed.directory, "journal.json"), marker)
        try FS.writeAtomic(targets[0], "已完成的新代码")
        #expect(try await recoveryCore.recoverCodeTemplateTransactions().isEmpty)
        #expect(try FS.readText(targets[0]) == "已完成的新代码")
        #expect(!FS.exists(committed.directory))
    }

}
