import Foundation
import AppKit
import CoreText
import CoreGraphics

/// 代码 PDF：按 CodeLayout 自己排，每页正好 50 行、共 60 页，折行位置和 Word 一致。
/// 每个字符画在固定的格子里：英文半格、中文一格（和新宋体一样）。本机装了新宋体就全用新宋体；
/// 没装时中文用替代宋体，英文用 Courier New（等宽，缩到正好半格）。缺字就拒绝交付，绝不漏字。
func renderCodeTemplate(_ template: CodeWordTemplate, project: String, software: String, fontPlan: [String: FontPlanEntry]?) async throws -> PdfFontResult {
    try assertSafeSoftwareName(software)
    let L = CodeLayout.self
    let twip: CGFloat = 1.0 / 20
    let width = CGFloat(L.pageWidthTwips) * twip, height = CGFloat(L.pageHeightTwips) * twip
    let left = CGFloat(L.marginLeftTwips) * twip
    let textWidth = CGFloat(L.textWidthTwips) * twip
    let top = height - CGFloat(L.marginTopTwips) * twip
    let rowHeight = CGFloat(L.linePitchTwips) * twip
    let size = CGFloat(L.fontSize)
    let cell = size / 2
    let rows = template.rows
    guard rows.count == L.totalRows else { throw StudioError("代码模板印出来是 \(rows.count) 行，不是 \(L.totalRows) 行；原交付包未改动") }

    // 中文字体：本机有新宋体用新宋体，否则用设置里选的替代字体（默认华文宋体）
    let original = DOC_FONTS["code"]!
    let families = installedFontFamilies()
    let preferred = fontPlan?["code"].flatMap { entry -> [String]? in
        if entry.mode == "original" { return original.families.filter { families.contains($0) } }
        return entry.substitute.flatMap { SUBSTITUTES[$0]?.names }
    } ?? original.families.filter { families.contains($0) }
    guard let cjk = (preferred + ["STSong", "Songti SC"]).compactMap({ NSFont(name: $0, size: size) }).first else {
        throw StudioError("没有找到支持中文的代码打印字体")
    }
    let cjkIsOriginal = original.families.contains(cjk.familyName ?? "") || cjk.fontName == "NSimSun"
    // 英文字体：新宋体本身英文就是半格；替代字体英文宽窄不一，改用等宽的 Courier New，缩到正好半格
    let latin: NSFont = {
        if cjkIsOriginal { return cjk }
        for name in ["Courier New", "Menlo", "Courier"] {
            if let probe = NSFont(name: name, size: 10) {
                let advance = NSAttributedString(string: "M", attributes: [.font: probe]).size().width / 10
                if advance > 0, let font = NSFont(name: name, size: cell / advance) { return font }
            }
        }
        return cjk
    }()
    let cjkFont = cjk as CTFont, latinFont = latin as CTFont
    let ascent = CTFontGetAscent(cjkFont), descent = CTFontGetDescent(cjkFont)

    /// 一行排成一条文字：每个字符用能显示它的字体，再用字距把它撑到正好占自己的格子（英文半格、中文一格）。
    /// 用文字而不是直接画字形，PDF 里的代码能选中、能搜索。
    var usedLatin = false
    func layout(_ row: String) throws -> CTLine {
        let text = NSMutableAttributedString()
        for character in row {
            let cells = codeCellWidth(character)
            let units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let isSpace = character == " " || character == "\u{3000}"
            let candidates = cells == 1 && character.isASCII ? [latinFont, cjkFont] : [cjkFont, latinFont]
            guard let font = candidates.first(where: { CTFontGetGlyphsForCharacters($0, units, &glyphs, units.count) && glyphs[0] != 0 }) ?? (isSpace ? latinFont : nil) else {
                throw StudioError("代码打印字体缺少字符「\(character)」，未交付；请在设置里换一个代码 PDF 字体")
            }
            if font === latinFont, latinFont !== cjkFont, !isSpace { usedLatin = true }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, [glyphs[0]], &advance, 1)
            let slot = CGFloat(cells) * cell
            text.append(NSAttributedString(string: String(character), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTKernAttributeName as String): slot - advance.width,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
                NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
            ]))
        }
        return CTLineCreateWithAttributedString(text)
    }
    let pages = try stride(from: 0, to: rows.count, by: L.rowsPerPage).map { start in
        try rows[start..<(start + L.rowsPerPage)].map(layout)
    }

    func frame(_ text: String, size: CGFloat, rect: CGRect, alignment: NSTextAlignment = .left) -> CTFrame {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        let font = NSFont(name: cjk.fontName, size: size)!
        let text = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.black, .ligature: 0])
        let setter = CTFramesetterCreateWithAttributedString(text)
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: text.length), CGPath(rect: rect, transform: nil), nil)
    }
    // 页眉：左边软件名，右上角页码（软著源程序材料的要求）；软件名不能伸进页码的位置
    let headerTop = height - CGFloat(L.headerTwips) * twip
    let headerRect = CGRect(x: left, y: headerTop - 16, width: textWidth, height: 16)
    let nameRect = CGRect(x: headerRect.minX, y: headerRect.minY, width: headerRect.width - 80, height: headerRect.height)
    let header = frame(software, size: 11, rect: nameRect)
    guard CTFrameGetVisibleStringRange(header).length == (software as NSString).length else { throw StudioError("软件名过长，代码页眉放不下；原交付包未改动") }

    try template.write(project: project, software: software)
    let target = Path.join(project, software, "\(software)\(CODE_SUFFIX).pdf")
    let temp = target + ".\(UUID().uuidString).tmp"
    defer { FS.remove(temp) }
    var media = CGRect(x: 0, y: 0, width: width, height: height)
    guard let context = CGContext(URL(fileURLWithPath: temp) as CFURL, mediaBox: &media, nil) else { throw StudioError("无法创建代码PDF") }
    context.setFillColor(NSColor.black.cgColor)
    for (index, page) in pages.enumerated() {
        context.beginPDFPage(nil)
        context.textMatrix = .identity
        CTFrameDraw(header, context)
        CTFrameDraw(frame("第 \(index + 1) 页", size: 11, rect: headerRect, alignment: .right), context)
        for (rowIndex, line) in page.enumerated() {
            let rowTop = top - CGFloat(rowIndex) * rowHeight
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: left, y: rowTop - (rowHeight - ascent - descent) / 2 - ascent)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    _ = try requireExactCodePdfPages(temp)
    FS.remove(target)
    try FS.move(temp, target)
    let fonts = try pdfFontNames(target)
    let usesLatin = usedLatin
    let found = fonts.contains(cjk.fontName) && (!usesLatin || fonts.contains(latin.fontName))
    guard found else { throw StudioError("代码PDF没有嵌入预期打印字体，未交付") }
    let fontLabel = usesLatin ? "\(cjk.familyName ?? cjk.fontName) + \(latin.familyName ?? latin.fontName)" : (cjk.familyName ?? cjk.fontName)
    return PdfFontResult(pdfPath: target, ok: found, fonts: fonts, unexpected: [], expectedFound: found, intended: "\(fontLabel) 9 磅（60 页 × 每页 50 行）", mode: "native-print")
}
