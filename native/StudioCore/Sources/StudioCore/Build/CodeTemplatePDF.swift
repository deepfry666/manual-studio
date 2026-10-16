import Foundation
import AppKit
import CoreText
import CoreGraphics

/// 代码PDF使用本机CoreText字体及固定60页打印布局，不再依赖LibreOffice的重新分页。
/// 每页在绘制前检查文字可见范围；放不下就拒绝，绝不裁掉正文或PDF末页。
func renderCodeTemplate(_ template: CodeWordTemplate, project: String, software: String, fontPlan: [String: FontPlanEntry]?) async throws -> PdfFontResult {
    try assertSafeSoftwareName(software)
    let width: CGFloat = 595.3, height: CGFloat = 841.89
    let bodyRect = CGRect(x: 60, y: 72, width: width - 120, height: height - 144)
    let headerRect = CGRect(x: 60, y: height - 58, width: width - 120, height: 30)
    // 页眉左边软件名，右上角页码（软著源程序材料的要求）；软件名不能伸进页码的位置
    let nameRect = CGRect(x: headerRect.minX, y: headerRect.minY, width: headerRect.width - 80, height: headerRect.height)
    // 模板原字体未安装时采用系统宋体，嵌入PDF，确保中文与英文都能打印。
    let original = DOC_FONTS["code"]!
    let families = installedFontFamilies()
    let preferred = fontPlan?["code"].flatMap { entry -> [String]? in
        if entry.mode == "original" { return original.families.filter { families.contains($0) } }
        return entry.substitute.flatMap { SUBSTITUTES[$0]?.names }
    } ?? original.families.filter { families.contains($0) }
    guard let baseFont = (preferred + ["Songti SC"]).compactMap({ NSFont(name: $0, size: 9) }).first else {
        throw StudioError("没有找到支持中文的代码打印字体")
    }
    let fontName = baseFont.familyName ?? baseFont.fontName

    func frame(_ text: String, size: CGFloat, rect: CGRect, alignment: NSTextAlignment = .left) throws -> CTFrame {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = size * 1.2
        paragraph.maximumLineHeight = size * 1.2
        let font = NSFont(name: baseFont.fontName, size: size)!
        let text = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.black, .ligature: 0])
        let setter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: text.length), CGPath(rect: rect, transform: nil), nil)
        for line in CTFrameGetLines(frame) as! [CTLine] {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                let utf16 = text.string as NSString
                for i in glyphs.indices where glyphs[i] == 0 && indices[i] < utf16.length {
                    let character = UnicodeScalar(utf16.character(at: indices[i]))
                    if character.map({ CharacterSet.whitespacesAndNewlines.contains($0) }) != true {
                        throw StudioError("代码打印字体缺少字符，未交付；请调整PDF字体")
                    }
                }
            }
        }
        return frame
    }
    let chunks = template.pageRanges.map { template.lines[$0].joined(separator: "\n") }
    var chosen: CGFloat?
    for size: CGFloat in [9, 8.5, 8] {
        var fits = true
        for text in chunks {
            let content = try frame(text, size: size, rect: bodyRect)
            if CTFrameGetVisibleStringRange(content).length != (text as NSString).length { fits = false; break }
        }
        if fits { chosen = size; break }
    }
    guard let size = chosen else { throw StudioError("完整代码无法以至少8磅字号排入60页；请调整代码模板，原交付包未改动") }
    let header = try frame(software, size: 11, rect: nameRect)
    guard CTFrameGetVisibleStringRange(header).length == (software as NSString).length else { throw StudioError("软件名过长，代码页眉放不下；原交付包未改动") }
    try template.write(project: project, software: software, printFont: fontName, printSize: Int(size * 2))
    let target = Path.join(project, software, "\(software)\(CODE_SUFFIX).pdf")
    let temp = target + ".\(UUID().uuidString).tmp"
    defer { FS.remove(temp) }
    var media = CGRect(x: 0, y: 0, width: width, height: height)
    guard let context = CGContext(URL(fileURLWithPath: temp) as CFURL, mediaBox: &media, nil) else { throw StudioError("无法创建代码PDF") }
    for (index, text) in chunks.enumerated() {
        context.beginPDFPage(nil)
        context.textMatrix = .identity
        CTFrameDraw(header, context)
        CTFrameDraw(try frame("第 \(index + 1) 页", size: 11, rect: headerRect, alignment: .right), context)
        CTFrameDraw(try frame(text, size: size, rect: bodyRect), context)
        context.endPDFPage()
    }
    context.closePDF()
    _ = try requireExactCodePdfPages(temp)
    FS.remove(target)
    try FS.move(temp, target)
    let fonts = try pdfFontNames(target)
    let found = fonts.contains(baseFont.fontName)
    guard found else { throw StudioError("代码PDF没有嵌入预期打印字体，未交付") }
    return PdfFontResult(pdfPath: target, ok: found, fonts: fonts, unexpected: [], expectedFound: found, intended: "\(fontName) \(size) 磅（60页打印布局）", mode: "native-print")
}
