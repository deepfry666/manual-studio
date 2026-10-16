import Foundation
import PDFKit
import Testing
@testable import StudioCore

private func writeTemplate(_ dir: String, _ name: String, variant: Int, lines: Int = 3322) throws -> String {
    let path = Path.join(dir, name)
    try FS.write(path, makeTestCodeTemplate(variant: variant, lineCount: lines))
    return path
}

@Suite("1.6.0：代码排版、模板库、已提交、内容规则", .serialized)
struct V160Tests {
    @Test("折行按新宋体等宽算：英文半格、中文一格，每行 107 个半格")
    func rows() {
        #expect(codeRows("").count == 1, "空行也算一行")
        #expect(codeRows("    ").count == 1, "纯空格算一行")
        #expect(codeRows(String(repeating: "a", count: 107)).count == 1)
        #expect(codeRows(String(repeating: "a", count: 108)).count == 2)
        #expect(codeRows(String(repeating: "中", count: 53)).count == 1, "53 个中文占 106 格")
        #expect(codeRows(String(repeating: "中", count: 54)).count == 2)
        #expect(codeRows(String(repeating: "a", count: 106) + "中").count == 2, "中文放不下最后一格就换行")
        #expect(codeRows(String(repeating: "a", count: 100) + String(repeating: " ", count: 30)).count == 1, "行尾空格不折行")
        #expect(codeRows(String(repeating: "x", count: 250)).joined() == String(repeating: "x", count: 250), "折行不丢字")
    }

    @Test("选行：正好 3000 行原样用，超出取前约 1500 + 后约 1500，不足拒绝")
    func select() {
        let exact = (0..<3000).map { "line \($0)" }
        #expect(selectCodeLines(exact) == exact)
        let long = (0..<3400).map { "line \($0)" }
        let chosen = selectCodeLines(long)!
        #expect(chosen.count == 3000)
        #expect(chosen.first == "line 0" && chosen.last == "line 3399")
        #expect(chosen[1499] == "line 1499" && chosen[1500] == "line 1900")
        // 中间有折成两行的长行：前后两段各自可能差一行，加起来正好 3000
        var mixed = (0..<3200).map { "line \($0)" }
        for index in stride(from: 1490, to: 1510, by: 2) { mixed[index] = String(repeating: "w", count: 150) }
        let picked = selectCodeLines(mixed)!
        #expect(picked.reduce(0) { $0 + codeRowCount($1) } == 3000)
        #expect(selectCodeLines((0..<2999).map { "line \($0)" }) == nil)
    }

    @Test("模板库：一次加多份、认出重复、不够行数说清楚；平均分配；用过的不能删；旧设置迁成模板 1", .timeLimit(.minutes(2)))
    func library() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        // 旧版本：设置里直接指向一份原始模板，已有项目锁定在它上面
        let legacy = try writeTemplate(ctx.root, "旧模板.docx", variant: 0)
        let legacyCopy = Path.join(ctx.dataDir, "code-templates", "\(sha256Hex(try FS.read(legacy))).docx")
        try FS.mkdirp(Path.dirname(legacyCopy))
        try FS.copy(legacy, legacyCopy)
        try await ctx.core.updateSettings(["codeSource": ["path": .string(legacyCopy), "extensions": [".java"]]])
        let old = try await ctx.create("旧项目 V1.0")
        try await ctx.core.projectStore.update(old) { state in
            state["request"]?["codeSource"] = ["path": .string(legacyCopy), "extensions": [".java"]]
            state["request"]?["codeSourceLocked"] = true
        }
        var library = try await ctx.core.codeTemplateLibrary()
        #expect(library["entries"].items.count == 1)
        #expect(library["entries"]?[0]?["label"]?.string == "模板 1")
        #expect(library["entries"]?[0]?["usage"]?.int == 1, "锁在原始模板上的旧项目算在模板 1 上")
        let t2 = try writeTemplate(ctx.root, "第二份.docx", variant: 2)
        let t3 = try writeTemplate(ctx.root, "第三份.docx", variant: 3, lines: 3000)
        let short = try writeTemplate(ctx.root, "太短.docx", variant: 4, lines: 2500)
        let results = try await ctx.core.addCodeTemplates([t2, t3, short, legacy, Path.join(ctx.root, "代码.txt")])
        #expect(results.map { $0["ok"].isTruthy } == [true, true, false, false, false], "\(results)")
        #expect(results[0]["cropped"].isTruthy && !results[1]["cropped"].isTruthy)
        #expect(results[2]["error"].text.contains("还差 500 行"))
        #expect(results[3]["error"].text.contains("模板 1"), "同一份文件认得出来")
        library = try await ctx.core.codeTemplateLibrary()
        #expect(library["entries"].items.map { $0["label"].text } == ["模板 1", "模板 2", "模板 3"])
        for entry in library["entries"].items {
            let template = try CodeWordTemplate(data: FS.read(entry["file"].text))
            #expect(template.rows.count == 3000, "库里存的都是裁好的 60 页")
        }
        // 平均分配：模板 1 已用 1 个，先补模板 2、3
        let preview = try await ctx.core.previewCodeTemplateAssignment(count: 7)
        #expect(preview == ["模板 2", "模板 3", "模板 1", "模板 2", "模板 3", "模板 1", "模板 2"])
        let list = (1...30).map { "分配测试\($0) V1.0" }.joined(separator: "\n")
        let made = try await ctx.core.createProjectsFromList(list, screenCount: 1, platform: "", wantDesign: false)
        #expect(made.created.count == 30)
        library = try await ctx.core.codeTemplateLibrary()
        let usage = library["entries"].items.map { $0["usage"]?.int ?? 0 }
        #expect(usage.reduce(0, +) == 31)
        #expect((usage.max() ?? 0) - (usage.min() ?? 0) <= 1, "三个模板用量差不超过 1：\(usage)")
        // 全部用同一个
        let id3 = library["entries"]?[2]?["id"]?.string ?? ""
        try await ctx.core.setCodeTemplateAssignment("fixed", fixedId: id3)
        let single = try await ctx.create("指定模板 V1.0")
        #expect(try ctx.core.projectStore.read(single)?["request"]?["codeSource"]?["templateId"]?.string == id3)
        // 新建时指定
        let id2 = library["entries"]?[1]?["id"]?.string ?? ""
        let chosen = try await ctx.create("手选模板 V1.0", extra: ["codeTemplateId": .string(id2)])
        #expect(try ctx.core.projectStore.read(chosen)?["request"]?["codeSource"]?["templateId"]?.string == id2)
        // 用过的不能删；停用后不再分到
        await #expect(throws: StudioError.self) { try await ctx.core.removeCodeTemplate(id2) }
        try await ctx.core.setCodeTemplateAssignment("balance")
        try await ctx.core.setCodeTemplateEnabled(id2, false)
        #expect(!(try await ctx.core.previewCodeTemplateAssignment(count: 6)).contains("模板 2"))
        let using2 = try await ctx.core.projectsUsingCodeTemplate(id2)
        #expect(using2.contains(chosen))
    }

    @Test("已提交：只读，运行、改设置、换模板都被拦下，批量更新代码材料跳过；取消后恢复", .timeLimit(.minutes(2)))
    func submitted() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        try await ctx.core.importCodeTemplate(testCodeTemplatePath)
        let name = "已提交项目 V1.0"
        let dir = try await fakeBuiltProject(ctx, name, ["\(name)指南.docx", "\(name)指南.txt", "\(name)\(CODE_SUFFIX).docx"])
        let result = try await ctx.core.setSubmitted([dir], true)
        #expect(result.changed == [dir])
        let list = try await ctx.core.listProjects()
        #expect(list.first { $0["dir"]?.string == dir }?["submitted"].isTruthy == true)
        await #expect(throws: StudioError.self) { try await ctx.core.pipeline.updateRequest(dir, ["notes": "改一下"]) }
        await #expect(throws: StudioError.self) { try await ctx.core.pipeline.addFeedback(dir, "按钮改成蓝色") }
        await #expect(throws: StudioError.self) { try await ctx.core.renameSoftware(dir, "新名字 V1.0") }
        #expect(await ctx.run(dir).status == "failed")
        let before = try FS.read(Path.join(dir, name, "\(name)指南.txt"))
        let batch = await ctx.core.applyCodeTemplates([dir], mode: "keep")
        #expect(batch["skipped"].items.first?.jsString.contains("已提交") == true)
        #expect(try FS.read(Path.join(dir, name, "\(name)指南.txt")) == before)
        _ = try await ctx.core.setSubmitted([dir], false)
        _ = try await ctx.core.pipeline.updateRequest(dir, ["notes": "改一下"])
        #expect(try ctx.core.projectStore.read(dir)?["request"]?["notes"]?.string == "改一下")
    }

    @Test("内容红线和写法检查")
    func policies() {
        #expect(redLineHits(["点击「在线申报」提交到税务局", "官方数据同步"]).sorted() == ["官方数据", "在线申报", "税务局"].sorted())
        #expect(redLineHits(["本月预算还剩 320 元，点击记一笔"]).isEmpty)
        #expect(redLineProblems("说明", ["缴纳罚款"]).count == 1)
        #expect(softwareNameRedLineHint("掌上政务通 V1.0") != nil)
        #expect(softwareNameRedLineHint("社保计算器 V1.0") == nil, "社保计算器这类个人工具不提醒，只按规则写")
        let verbose = String(repeating: "蓝色按钮在右上角，", count: 60) + "底部导航栏「我的」为蓝色选中态。两项之和与合计一致。"
        let problems = contentStyleProblems([.obj(["id": "screen-01", "title": "首页", "text": .string(verbose)]), .obj(["id": "screen-02", "title": "记一笔", "text": "填写金额和分类后点保存，回到首页能看到这一笔。"])])
        #expect(problems.count == 1)
        #expect(problems[0].contains("精简") && problems[0].contains("颜色") && problems[0].contains("导航栏") && problems[0].contains("自我核对"))
        #expect(RED_LINE_RULE.contains("不涉及政府职能"))
        #expect(CONTENT_STYLE_RULE.contains("300–400"))
    }

    @Test("报错里的临时路径换成诊断文件按钮")
    func diagnostics() {
        let message = "交付校验没有通过（正式交付包未改动）：\n- 缺少 TXT" + diagnosticsTag("/tmp/staging/x")
        let split = splitDiagnostics(message)
        #expect(split.text == "交付校验没有通过（正式交付包未改动）：\n- 缺少 TXT")
        #expect(split.path == "/tmp/staging/x")
        #expect(splitDiagnostics("普通报错").path == nil)
    }

    /// 用真实模板验收（可选）：MS_REAL_TEMPLATES_DIR 指向一个放 Word 模板的文件夹，MS_TEMPLATE_QA_DIR 放生成的 PDF。
    @Test("真实模板：每份都排成 60 页、每页 50 行", .enabled(if: ProcessInfo.processInfo.environment["MS_REAL_TEMPLATES_DIR"] != nil), .timeLimit(.minutes(5)))
    func realTemplates() async throws {
        let source = ProcessInfo.processInfo.environment["MS_REAL_TEMPLATES_DIR"]!
        let qa = ProcessInfo.processInfo.environment["MS_TEMPLATE_QA_DIR"]
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let files = (FS.list(source) ?? []).filter { [".doc", ".docx"].contains(Path.extname($0).lowercased()) }.sorted().map { Path.join(source, $0) }
        try #require(!files.isEmpty)
        let results = try await ctx.core.addCodeTemplates(files)
        for result in results { print("模板检查：", result.serialized()) }
        #expect(results.allSatisfy { $0["ok"].isTruthy })
        for (index, entry) in try await ctx.core.settingsStore.get().codeTemplates.entries.enumerated() {
            let template = try CodeWordTemplate(data: FS.read(codeTemplateFile(ctx.dataDir, entry.id)))
            #expect(template.rows.count == 3000)
            let name = "真实模板验收\(index + 1) V1.0"
            let project = Path.join(ctx.root, "qa-\(index)")
            try FS.mkdirp(Path.join(project, name))
            let rendered = try await renderCodeTemplate(template, project: project, software: name, fontPlan: nil)
            #expect(countPdfPages(rendered.pdfPath) == 60)
            let document = try #require(PDFDocument(url: URL(fileURLWithPath: rendered.pdfPath)))
            for page in [0, 29, 30, 59] {
                let first = template.rows[page * 50].jsTrimmed
                let last = template.rows[page * 50 + 49].jsTrimmed
                let text = document.page(at: page)?.string ?? ""
                if !first.isEmpty { #expect(text.contains(first.prefix(20)), "第 \(page + 1) 页从第 \(page * 50 + 1) 行开始") }
                if !last.isEmpty { #expect(text.contains(last.prefix(20)), "第 \(page + 1) 页以第 \(page * 50 + 50) 行结束") }
            }
            if let qa {
                try FS.copy(rendered.pdfPath, Path.join(qa, "\(entry.label).pdf"))
                try FS.copy(Path.join(project, name, "\(name)\(CODE_SUFFIX).docx"), Path.join(qa, "\(entry.label).docx"))
            }
        }
    }

    /// 界面自检用（可选）：MS_SEED_DATA_DIR 指向一个空的数据目录，放进 MS_REAL_TEMPLATES_DIR 里的模板和几个示例项目。
    @Test("界面自检数据", .enabled(if: ProcessInfo.processInfo.environment["MS_SEED_DATA_DIR"] != nil && ProcessInfo.processInfo.environment["MS_REAL_TEMPLATES_DIR"] != nil), .timeLimit(.minutes(5)))
    func seedSandbox() async throws {
        let env = ProcessInfo.processInfo.environment
        let dataDir = env["MS_SEED_DATA_DIR"]!
        let core = try await StudioCore(dataDir: dataDir, secrets: MemorySecrets(), http: MockNetwork())
        try await core.updateSettings(["workspaceDir": .string(Path.join(dataDir, "workspace"))])
        let source = env["MS_REAL_TEMPLATES_DIR"]!
        let files = (FS.list(source) ?? []).filter { [".doc", ".docx"].contains(Path.extname($0).lowercased()) }.sorted().map { Path.join(source, $0) }
        _ = try await core.addCodeTemplates(files)
        let made = try await core.createProjectsFromList("云伴日程 V1.0\n快记账本 V1.0\n掌上政务通 V1.0\n社保计算器 V1.0\n消消乐大师 V1.0\n口袋相册 V1.0", screenCount: 7, platform: "", wantDesign: false)
        #expect(made.created.count == 6)
        _ = try await core.setSubmitted([made.created[1]], true)
    }
}

@Suite("1.6.1：时间解析")
struct V161ParseTests {
    @Test("快速时间解析和系统解析结果一致")
    func fastISO() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for text in ["2026-10-16T06:26:35.359Z", "2000-02-29T23:59:59.999Z", "1999-12-31T00:00:00.000Z", "2026-03-01T12:00:00.001Z"] {
            #expect(fastParseISO(text) == formatter.date(from: text)!.timeIntervalSince1970 * 1000, "\(text)")
        }
        #expect(fastParseISO("2026-10-16T06:26:35Z") == ISO8601DateFormatter().date(from: "2026-10-16T06:26:35Z")!.timeIntervalSince1970 * 1000)
        #expect(fastParseISO("2026-10-16T14:26:35+08:00") == nil, "带时区的交给系统解析")
        #expect(parseISO("2026-10-16T14:26:35+08:00") == ISO8601DateFormatter().date(from: "2026-10-16T14:26:35+08:00")!.timeIntervalSince1970 * 1000)
        #expect(fastParseISO("2026-13-16T06:26:35.359Z") == nil)
        #expect(parseISO("不是时间") == nil)
    }
}
