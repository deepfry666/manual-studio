import Foundation
import PDFKit
import Testing
@testable import StudioCore

@Suite("Word 代码模板", .serialized)
struct CodeTemplateTests {
    @Test("新模板保留正文、样式和部件，均匀分配成60页，更新页眉")
    func templateFidelity() throws {
        let original = try FS.read(CodeWordTemplate.bundledPath)
        let code = try collectCodeSource(path: CodeWordTemplate.bundledPath, extensions: [".java"])
        let template = try #require(code.wordTemplate)
        #expect(code.lineCount == 3322)
        #expect(code.nonEmptyLines == 3229)
        #expect(code.estimatedPages == 60)
        let dir = try FS.makeTempDirectory(prefix: "code-template-")
        defer { FS.remove(dir) }
        let name = "批量模板测试 V1.0"
        try template.write(project: dir, software: name)
        let target = Path.join(dir, name, "\(name)\(CODE_SUFFIX).docx")
        let result = try CodeWordTemplate(data: FS.read(target))
        #expect(result.lines == template.lines, "代码内容、顺序、空白行都必须不变")
        let before = try ZipReader(original)
        let after = try ZipReader(FS.read(target))
        #expect(before.entries.map(\.name) == after.entries.map(\.name))
        let editable = ["word/document.xml", "word/header1.xml", "docProps/app.xml", "docProps/custom.xml"]
        for entry in before.entries where !entry.isDirectory && !editable.contains(entry.name) {
            #expect(try before.read(entry) == after.read(entry.name), "保留部件 \(entry.name)")
        }
        let xml = String(decoding: try #require(try after.read("word/document.xml")), as: UTF8.self)
        let originalXml = String(decoding: try #require(try before.read("word/document.xml")), as: UTF8.self)
        #expect(Rx.count("> +</w:t>", xml) == Rx.count("> +</w:t>", originalXml), "空白段内的空格必须原样保留")
        #expect(Rx.count("<w:pageBreakBefore(?:\\s[^>]*)?/>", xml) == 59)
        let header = String(decoding: try #require(try after.read("word/header1.xml")), as: UTF8.self)
        #expect(header.contains(name))
        #expect(!header.contains("某项目"))
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
        #expect(try FS.read(CodeWordTemplate.bundledPath) == original)
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
        try await ctx.core.importCodeTemplate()
        let settings = try await ctx.core.settingsStore.get()
        let sourcePath = settings.codeSource.path
        #expect(Path.isInside(ctx.dataDir, sourcePath))
        #expect(try FS.read(sourcePath) == FS.read(CodeWordTemplate.bundledPath))
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
