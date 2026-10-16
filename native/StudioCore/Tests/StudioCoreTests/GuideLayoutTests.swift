import Foundation
import Testing
@testable import StudioCore

private func drawingExtents(_ file: String) throws -> [(Double, Double)] {
    let zip = try ZipReader(FS.read(file))
    let xml = String(decoding: try #require(try zip.read("word/document.xml")), as: UTF8.self)
    return Rx.matches(#"<wp:extent cx="([0-9]+)" cy="([0-9]+)""#, xml).map { (Double($0[1]!)!, Double($0[2]!)!) }
}

/// 使用已保存的旧版对照文件，确保回归测试确实能捕获原来的 240pt 超宽问题。
private func writeLegacyGuide(_ dir: String) throws -> (String, JSON) {
    let fixture = fixtures["docx"]!
    let name = fixture["software"]!.string!
    var zip = ZipWriter()
    for entry in fixture["guide"]!["names"].items.map(\.jsString) {
        if let xml = fixture["guide"]?[entry]?.string { zip.addFile(entry, xml) }
        else if entry.hasSuffix("/") { zip.addDirectory(entry) }
        else if entry.hasPrefix("word/media/") {
            let media = fixture["guide"]!["names"].items.map(\.jsString).filter { $0.hasPrefix("word/media/") && !$0.hasSuffix("/") }
            let index = media.firstIndex(of: entry)!
            zip.addFile(entry, Data(base64Encoded: fixture["pngs"]!.items[index].string!)!)
        }
    }
    try FS.write(Path.join(dir, name, "\(name)指南.docx"), zip.finish())
    for (index, png) in fixture["pngs"].items.enumerated() {
        try FS.write(Path.join(dir, "screens", "screen-0\(index+1).png"), Data(base64Encoded: png.string!)!)
    }
    try FS.writeJSONAtomic(Path.join(dir, "content.json"), fixture["content"]!)
    return (name, fixture["content"]!)
}

@Suite("指南截图完整排版", .serialized)
struct GuideLayoutTests {
    @Test("普通、超长、横向图片均在栏内和页面高度内，保留原图比例及字节")
    func fittedDrawings() throws {
        let root = try FS.makeTempDirectory(prefix: "guide-fit-")
        defer { FS.remove(root) }
        let fixture = fixtures["docx"]!
        let name = fixture["software"]!.string!
        for (width, height) in [(432, 912), (216, 1400), (640, 360)] {
            let image = makePng(width, height)
            var content = fixture["content"]!
            content["screenshotCount"] = 1
            content["screens"] = .array([content["screens"]!.items[0]])
            try FS.write(Path.join(root, content["screens"]!.items[0]["image"]!.string!), image)
            try createGuideDocx(project: root, software: name, content: content)
            let file = Path.join(root, name, "\(name)指南.docx")
            let extents = try drawingExtents(file)
            let extent = try #require(extents.first)
            // 来自 A4 17cm 可用宽、48% 左栏、两侧各0.16cm内边距；不是被测尺寸函数算期望。
            #expect(extent.0 / 12700 <= 222.25)
            #expect(extent.1 / 12700 < 690, "预留图注和段落空间")
            #expect(abs(extent.1 / extent.0 - Double(height) / Double(width)) < 0.0001)
            let zip = try ZipReader(FS.read(file))
            let media = try #require(zip.entries.first { $0.name.hasPrefix("word/media/") && !$0.isDirectory })
            #expect(try zip.read(media) == image, "只调整排版尺寸，不能裁切或重绘源截图")
        }
    }

    @Test("已有超宽Word重新导出时重排指南；原图、正文、TXT保持，旧Word归档", .timeLimit(.minutes(2)))
    func repairLegacyExport() async throws {
        guard await findLibreOffice() != nil else { return }
        let root = try FS.makeTempDirectory(prefix: "guide-legacy-fit-")
        defer { FS.remove(root) }
        let (name, _) = try writeLegacyGuide(root)
        let docx = Path.join(root, name, "\(name)指南.docx")
        let old = try FS.read(docx)
        #expect(try drawingExtents(docx).first!.0 / 12700 == 240)
        let textFile = Path.join(root, name, "\(name)指南.txt")
        try FS.write(textFile, "保留原TXT")
        let contentBefore = try FS.read(Path.join(root, "content.json"))
        let imageBefore = try FS.read(Path.join(root, "screens/screen-01.png"))
        _ = try await reexportBundlePdfs(projectDir: root, softwareName: name, stagingRoot: Path.join(root, "staging"), fontPlan: resolveFontPlan(PdfSettings()), onLog: { _ in })
        #expect(try drawingExtents(docx).allSatisfy { $0.0 / 12700 <= 222.25 })
        #expect(try FS.read(Path.join(root, "content.json")) == contentBefore)
        #expect(try FS.read(Path.join(root, "screens/screen-01.png")) == imageBefore)
        #expect(try FS.readText(textFile) == "保留原TXT")
        let archived = (FS.list(Path.join(root, "archive")) ?? []).flatMap { folder in (FS.list(Path.join(root, "archive", folder)) ?? []).map { Path.join(root, "archive", folder, $0) } }
        #expect(archived.contains { (try? FS.read($0)) == old })
        let repaired = try FS.read(docx)
        _ = try await reexportBundlePdfs(projectDir: root, softwareName: name, stagingRoot: Path.join(root, "staging"), fontPlan: resolveFontPlan(PdfSettings()), onLog: { _ in })
        #expect(try FS.read(docx) == repaired, "新布局无需再重写Word")
    }
    @Test("重排后遇到后续代码Word损坏时不替换任何旧材料", .timeLimit(.minutes(2)))
    func failedConversionKeepsBundle() async throws {
        guard await findLibreOffice() != nil else { return }
        let root = try FS.makeTempDirectory(prefix: "guide-fit-failure-")
        defer { FS.remove(root) }
        let (name, _) = try writeLegacyGuide(root)
        let docx = Path.join(root, name, "\(name)指南.docx")
        let old = try FS.read(docx)
        let pdf = Path.join(root, name, "\(name)指南.pdf")
        try FS.write(pdf, "old-pdf-sentinel")
        try FS.write(Path.join(root, name, "\(name)指南_代码-（JAVA）.docx"), "damaged-word")
        do {
            _ = try await reexportBundlePdfs(projectDir: root, softwareName: name, stagingRoot: Path.join(root, "staging"), fontPlan: resolveFontPlan(PdfSettings()), onLog: { _ in })
            Issue.record("后续转换失败不应返回成功")
        } catch {}
        #expect(try FS.read(docx) == old)
        #expect(try FS.readText(pdf) == "old-pdf-sentinel")
        FS.remove(Path.join(root, "content.json"))
        do {
            _ = try await reexportBundlePdfs(projectDir: root, softwareName: name, stagingRoot: Path.join(root, "staging"), fontPlan: resolveFontPlan(PdfSettings()), guideOnly: true, onLog: { _ in })
            Issue.record("缺内容时不能静默继续输出遮挡的PDF")
        } catch { #expect(messageOf(error).contains("content.json")) }
        #expect(try FS.read(docx) == old)
    }

    @Test("按需复现真实指南并生成只读副本用于PDF视觉验收", .timeLimit(.minutes(2)))
    func inspectRealGuideCopy() async throws {
        guard let source = ProcessInfo.processInfo.environment["MS_GUIDE_REVIEW_PROJECT"],
              let target = ProcessInfo.processInfo.environment["MS_GUIDE_REVIEW_OUTPUT"] else { return }
        let content = try #require(try FS.readJSON(projectPaths(source).content))
        let name = content["softwareName"].text
        try FS.mkdirp(target)
        for file in ["content.json", "screens", name] {
            try FS.copy(Path.join(source, file), Path.join(target, file))
        }
        let originalContent = try FS.read(projectPaths(target).content)
        let result = try await reexportBundlePdfs(projectDir: target, softwareName: name, stagingRoot: Path.join(target, "staging"), fontPlan: resolveFontPlan(PdfSettings()), guideOnly: true, onLog: { print($0) })
        #expect(result["guideLayoutRepaired"] == true)
        #expect(try FS.read(projectPaths(target).content) == originalContent)
    }

    @Test("Word与源正文或截图不一致时拒绝重排，保护手工修改")
    func mismatchedSourcesKeepWord() async throws {
        guard await findLibreOffice() != nil else { return }
        let root = try FS.makeTempDirectory(prefix: "guide-fit-source-")
        defer { FS.remove(root) }
        let (name, content) = try writeLegacyGuide(root)
        let docx = Path.join(root, name, "\(name)指南.docx")
        let old = try FS.read(docx)
        var changed = content
        changed["cover"]?["overview"] = "这是一段与旧Word不同的功能介绍，用户手动调整后尚未同步。"
        try FS.writeJSONAtomic(Path.join(root, "content.json"), changed)
        do {
            _ = try await reexportBundlePdfs(projectDir: root, softwareName: name, stagingRoot: Path.join(root, "staging"), fontPlan: resolveFontPlan(PdfSettings()), onLog: { _ in })
            Issue.record("源正文不一致必须保留旧Word")
        } catch { #expect(messageOf(error).contains("不一致")) }
        #expect(try FS.read(docx) == old)
        try FS.writeJSONAtomic(Path.join(root, "content.json"), content)
        try FS.write(Path.join(root, "screens/screen-01.png"), makePng())
        do {
            _ = try await reexportBundlePdfs(projectDir: root, softwareName: name, stagingRoot: Path.join(root, "staging"), fontPlan: resolveFontPlan(PdfSettings()), onLog: { _ in })
            Issue.record("源截图不一致必须保留旧Word")
        } catch { #expect(messageOf(error).contains("不一致")) }
        #expect(try FS.read(docx) == old)
    }

}
