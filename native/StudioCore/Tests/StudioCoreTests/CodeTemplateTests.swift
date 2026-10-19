import Foundation
import PDFKit
import Testing
@testable import StudioCore

@Suite("Word 代码模板", .serialized)
struct CodeTemplateTests {
    @Test("模板整理成 60 页 × 每页 50 行：前 1500 + 后 1500 行，代码一字不改，只换页眉")
    func templateFidelity() throws {
        let original = try FS.read(testCodeTemplatePath)
        let code = try collectCodeSource(path: testCodeTemplatePath, extensions: [".java"])
        let template = try #require(code.wordTemplate)
        #expect(code.estimatedPages == 60)
        #expect(template.sourceRows == 3322)
        #expect(template.cropped)
        #expect(template.rows.count == 3000)
        let raw = try CodeWordTemplate.readLines(try #require(try ZipReader(original).read("word/document.xml")))
        #expect(template.lines == Array(raw.prefix(1500)) + Array(raw.suffix(1500)), "前后各 1500 行，顺序、空白都不变")
        let dir = try FS.makeTempDirectory(prefix: "code-template-")
        defer { FS.remove(dir) }
        let name = "批量模板测试 V1.0"
        try template.write(project: dir, software: name)
        let target = Path.join(dir, name, "\(name)\(CODE_SUFFIX).docx")
        let result = try CodeWordTemplate(data: FS.read(target))
        #expect(result.lines == template.lines, "交付的代码 Word 读回来正文不变")
        #expect(result.sourceRows == 3322, "读回整理好的模板不再重新裁剪")
        let after = try ZipReader(FS.read(target))
        let xml = String(decoding: try #require(try after.read("word/document.xml")), as: UTF8.self)
        #expect(Rx.count("> +</w:t>", xml) == template.lines.filter { !$0.isEmpty && $0.jsTrimmed.isEmpty }.count, "纯空格的行原样保留")
        #expect(xml.contains(#"<w:docGrid w:type="lines" w:linePitch="283"/>"#), "每页 50 行的行网格")
        #expect(Rx.count(#"<w:widowControl w:val="0"/>"#, xml) == template.lines.count, "关掉孤行控制，长行可以跨页")
        #expect(Rx.count("<w:pageBreakBefore", xml) == 0, "不靠分页符，按行网格自然分页")
        let header = String(decoding: try #require(try after.read("word/header1.xml")), as: UTF8.self)
        #expect(header.contains(name))
        #expect(!header.contains(TEST_TEMPLATE_HEADER))
        #expect(header.contains(" PAGE "), "页眉右上角要有页码域")
        #expect(Rx.count("_ManualStudioPageNo", header) == 1)
        // 已生成的代码 Word 能再当模板读回，再次生成不会叠加第二个页码
        let again = try FS.makeTempDirectory(prefix: "code-template-again-")
        defer { FS.remove(again) }
        try result.write(project: again, software: name)
        let rewritten = try ZipReader(FS.read(Path.join(again, name, "\(name)\(CODE_SUFFIX).docx")))
        let header2 = String(decoding: try #require(try rewritten.read("word/header1.xml")), as: UTF8.self)
        #expect(Rx.count("_ManualStudioPageNo", header2) == 1)
        #expect(Rx.count("<w:tabs>", header2) == 1)
        #expect(try codeExactPages(target) == 60)
        #expect(try FS.read(testCodeTemplatePath) == original)
        // 整理是确定的：同一份模板两次整理出完全一样的文件（模板库靠指纹认出同一份）
        #expect(try CodeWordTemplate(data: original).data == template.data)
    }

    @Test("不足页数的PDF拒绝交付，损坏Word不会被当作源码")
    func rejectsBadInputs() throws {
        let root = try FS.makeTempDirectory(prefix: "code-template-failure-")
        defer { FS.remove(root) }
        let pdf = Path.join(root, "short.pdf")
        try FS.write(pdf, "%PDF-1.4\n1 0 obj << /Type /Page >> endobj\n")
        #expect(throws: StudioError.self) { try requireExactCodePdfPages(pdf) }
        try FS.write(pdf, "%PDF-1.4\n" + String(repeating: "1 0 obj << /Type /Page >> endobj\n", count: 61))
        #expect(throws: StudioError.self) { try requireExactCodePdfPages(pdf) }
        try FS.write(Path.join(root, "broken.docx"), "invalid ZIP")
        #expect(throws: StudioError.self) { try collectCodeSource(path: Path.join(root, "broken.docx"), extensions: []) }
    }

    @Test("批量真实构建、PDF页数验收、模板持久化及锁定恢复", .timeLimit(.minutes(3)))
    func batchBuild() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        try await ctx.core.importCodeTemplate(testCodeTemplatePath)
        let settings = try await ctx.core.settingsStore.get()
        let sourcePath = settings.codeSource.path
        #expect(Path.isInside(ctx.dataDir, sourcePath))
        #expect(try CodeWordTemplate(data: FS.read(sourcePath)).lines == CodeWordTemplate(data: FS.read(testCodeTemplatePath)).lines, "模板库里存的是整理好的那份")
        let restored = try await SettingsStore(dataDir: ctx.dataDir).get()
        #expect(restored.codeSource.path == sourcePath)
        let a = try await ctx.create("模板批量甲 V1.0", screenCount: 1)
        let b = try await ctx.create("模板批量乙 V1.0", screenCount: 1)
        try #require(await findLibreOffice() != nil, "此验收需要真实LibreOffice")
        await ctx.core.batch.enqueue([a, b])
        let deadline = Date().addingTimeInterval(140)
        while Date() < deadline {
            let items = ctx.core.batch.list().items
            if items.count == 2 && items.allSatisfy({ ["done", "failed", "needs-attention"].contains($0["status"]?.string ?? "") }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ctx.core.batch.list().items.allSatisfy { $0["status"]?.string == "done" }, "\(ctx.core.batch.list().items)")
        for (dir, name) in [(a, "模板批量甲 V1.0"), (b, "模板批量乙 V1.0")] {
            let project = try await ctx.project(dir)
            let pdf = Path.join(dir, name, "\(name)\(CODE_SUFFIX).pdf")
            let pages = try #require(countPdfPages(pdf))
            #expect(pages == 60)
            let document = try #require(PDFDocument(url: URL(fileURLWithPath: pdf)))
            #expect(document.page(at: 0)?.string?.contains("第 1 页") == true, "代码 PDF 页眉要有页码")
            #expect(document.page(at: 59)?.string?.contains("第 60 页") == true)
            #expect(document.page(at: 0)?.string?.contains(name) == true)
            let template = try CodeWordTemplate(data: FS.read(sourcePath))
            #expect(document.page(at: 0)?.string?.contains(template.rows[0].jsTrimmed) == true, "第 1 页从第 1 行开始")
            #expect(document.page(at: 59)?.string?.contains(template.rows[2999].jsTrimmed) == true, "第 60 页以第 3000 行结束")
            #expect(document.page(at: 1)?.string?.contains(template.rows[50].jsTrimmed) == true, "每页正好 50 行")
            #expect(project["state"]?["lastBuild"]?["codePdfPages"]?.int == pages)
            let manifest = try readJSONFile(projectPaths(dir).manifest)
            #expect(manifest["codePagination"]?["pdfPages"]?.int == pages)
            let target = Path.join(dir, name, "\(name)\(CODE_SUFFIX).docx")
            #expect(try CodeWordTemplate(data: FS.read(target)).lines == CodeWordTemplate(data: FS.read(sourcePath)).lines)
            if let qa = ProcessInfo.processInfo.environment["MS_TEMPLATE_QA_DIR"] {
                try FS.copy(target, Path.join(qa, "\(name).docx"))
                try FS.copy(pdf, Path.join(qa, "\(name).pdf"))
            }
        }
        _ = try await ctx.core.projectStore.update(a) { state in state["lastBuild"]?["codePdfPages"] = 999 }
        let reexport = try await ctx.core.pipeline.reexportPdfs(a)
        #expect((reexport["codePdfPages"]?.int ?? 0) == 60)
        #expect(try ctx.core.projectStore.read(a)?["lastBuild"]?["codePdfPages"] == reexport["codePdfPages"])
        #expect(try readJSONFile(projectPaths(a).manifest)["codePagination"]?["pdfPages"] == reexport["codePdfPages"])
        // 总设置更换后，已有项目继续指向不可变模板；主动切换才改变锁定来源。
        let other = Path.join(ctx.root, "new.java")
        try FS.write(other, "class Changed {}")
        try await ctx.core.updateSettings(["codeSource": ["path": .string(other), "extensions": [".java"]]])
        let aState = try #require(try ctx.core.projectStore.read(a))
        #expect(codeSourceFor(aState, try await ctx.core.settingsStore.get()).source?["path"]?.string == sourcePath)
        try await ctx.core.pipeline.useGlobalCodeSource(a)
        #expect(try ctx.core.projectStore.read(a)?["request"]?["codeSource"]?["path"]?.string == other)
    }
}
