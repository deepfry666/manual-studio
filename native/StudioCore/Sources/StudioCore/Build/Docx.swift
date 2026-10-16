import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 排版常量 —— 全部来自旧 skill 的 references/word-format.md（lib/guide-constants.js），不改。
enum GuideConstants {
    static let GUIDE_SUFFIX = "指南"
    static let CODE_SUFFIX = "指南_代码-（JAVA）"
    static let FONT_CJK = "Microsoft YaHei"
    static let COLOR_BODY = "1F2933"
    static let COLOR_TITLE = "111827"
    static let COLOR_META = "4B5563"
    static let COLOR_CAPTION = "6B7280"
    static let COLOR_TABLE_BORDER = "D1D5DB"
    static let SIZE_BODY = 22
    static let SIZE_COVER_TITLE = 44
    static let SIZE_COVER_META = 22
    static let SIZE_HEADER = 18
    static let SIZE_FEATURE_TITLE = 28
    static let SIZE_CAPTION = 18
    static let LINE_BODY = 300
    static let LINE_OVERVIEW = 312
    static let AFTER_BODY = 120
    static let AFTER_FEATURE_TITLE = 160
    static let BEFORE_CAPTION = 80
    static let AFTER_CAPTION = 0
    static let CM = 567.0
    static let PAGE_WIDTH = Int(jsRound(21.0 * CM))
    static let PAGE_HEIGHT = Int(jsRound(29.7 * CM))
    static let MARGIN_TOP = Int(jsRound(2.2 * CM))
    static let MARGIN_BOTTOM = Int(jsRound(2.0 * CM))
    static let MARGIN_LEFT = Int(jsRound(2.0 * CM))
    static let MARGIN_RIGHT = Int(jsRound(2.0 * CM))
    static let MARGIN_HEADER = 720
    static let MARGIN_FOOTER = 720
    static let USABLE_WIDTH = PAGE_WIDTH - MARGIN_LEFT - MARGIN_RIGHT
    static let COL_IMAGE_WIDTH = Int(jsRound(Double(USABLE_WIDTH) * 0.48))
    static let COL_TEXT_WIDTH = USABLE_WIDTH - COL_IMAGE_WIDTH
    static let TABLE_BORDER_SIZE = 4
    static let CELL_MARGIN_TB = Int(jsRound(0.12 * CM))
    static let CELL_MARGIN_LR = Int(jsRound(0.16 * CM))
    static let IMAGE_WIDTH_PX = 320
    static let DEFAULT_FEATURE_TIER = 300
    static let FEATURE_TEXT_FLOOR = 300
}

/// XML 文本转义（和 docx 库一致：& < > " ' 都转义；去掉 XML 不允许的控制字符）。
func xmlText(_ value: String) -> String {
    var output = ""
    output.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
        switch scalar {
        case "&": output += "&amp;"
        case "<": output += "&lt;"
        case ">": output += "&gt;"
        case "\"": output += "&quot;"
        case "'": output += "&apos;"
        default:
            let v = scalar.value
            if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D { continue }
            if v == 0xFFFE || v == 0xFFFF { continue }
            output.unicodeScalars.append(scalar)
        }
    }
    return output
}

/// 读取 PNG / JPEG 的像素尺寸（lib/image-size.js）。
func readImageSize(_ data: Data, _ path: String) throws -> (width: Int, height: Int, type: String) {
    let bytes = [UInt8](data)
    func u16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
    func u32(_ offset: Int) -> Int { u16(offset) << 16 | u16(offset + 2) }
    if bytes.count >= 24, Data(bytes[0..<8]) == PNG_SIGNATURE {
        return (u32(16), u32(20), "png")
    }
    if bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 {
        var offset = 2
        while offset + 8 < bytes.count {
            if bytes[offset] != 0xff {
                offset += 1
                continue
            }
            let marker = bytes[offset + 1]
            let isSOF = (0xc0...0xc3).contains(marker) || (0xc5...0xc7).contains(marker) || (0xc9...0xcb).contains(marker) || (0xcd...0xcf).contains(marker)
            if isSOF { return (u16(offset + 7), u16(offset + 5), "jpg") }
            offset += 2 + u16(offset + 2)
        }
    }
    throw StudioError("无法解析图片尺寸（仅支持 PNG/JPEG）: \(path)")
}

// MARK: - XML 片段

private func rFonts(_ font: String) -> String {
    let f = xmlText(font)
    return "<w:rFonts w:ascii=\"\(f)\" w:cs=\"\(f)\" w:eastAsia=\"\(f)\" w:hAnsi=\"\(f)\"/>"
}

/// 指南里的文字（create-guide-docx.js 的 run()）。
private func guideRun(_ text: String, size: Int = GuideConstants.SIZE_BODY, color: String = GuideConstants.COLOR_BODY, bold: Bool = false) -> String {
    let weight = bold ? "<w:b/><w:bCs/>" : "<w:b w:val=\"false\"/><w:bCs w:val=\"false\"/>"
    return "<w:r><w:rPr>\(rFonts(GuideConstants.FONT_CJK))\(weight)<w:color w:val=\"\(color)\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr><w:t xml:space=\"preserve\">\(xmlText(text))</w:t></w:r>"
}

private func paragraph(_ properties: String, _ runs: String = "") -> String {
    "<w:p><w:pPr>\(properties)</w:pPr>\(runs)</w:p>"
}

private func spacing(after: Int, before: Int, line: Int? = nil) -> String {
    "<w:spacing w:after=\"\(after)\" w:before=\"\(before)\"\(line.map { " w:line=\"\($0)\"" } ?? "")/>"
}

private func jc(_ value: String) -> String { "<w:jc w:val=\"\(value)\"/>" }

private func border(_ name: String, _ value: String, _ color: String, _ size: Int) -> String {
    "<w:\(name) w:val=\"\(value)\" w:color=\"\(color)\" w:sz=\"\(size)\"/>"
}

private func splitParagraphs(_ text: String) -> [String] {
    Rx.split(#"\n+"#, text.replacingOccurrences(of: "\r\n", with: "\n")).map(\.jsTrimmed).filter { !$0.isEmpty }
}

private func coreXml(_ date: Date) -> String {
    let stamp = isoString(date)
    return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>Un-named</dc:creator><cp:lastModifiedBy>Un-named</cp:lastModifiedBy><cp:revision>1</cp:revision><dcterms:created xsi:type="dcterms:W3CDTF">"# + stamp + #"</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">"# + stamp + #"</dcterms:modified></cp:coreProperties>"#
}

private func documentRels(images: [String], fontTableId: Int) -> String {
    let base = [
        ("rId1", "styles", "styles.xml"), ("rId2", "numbering", "numbering.xml"), ("rId3", "footnotes", "footnotes.xml"),
        ("rId4", "endnotes", "endnotes.xml"), ("rId5", "settings", "settings.xml"), ("rId6", "header", "header1.xml"), ("rId7", "theme", "theme/theme1.xml"),
    ]
    var rels = base.map { "<Relationship Id=\"\($0.0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\($0.1)\" Target=\"\($0.2)\"/>" }
    for (index, name) in images.enumerated() {
        rels.append("<Relationship Id=\"rId\(8 + index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>")
    }
    rels.append("<Relationship Id=\"rId\(fontTableId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable\" Target=\"fontTable.xml\"/>")
    return #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + rels.joined() + "</Relationships>"
}

private func sectionProperties(width: Int, height: Int, top: Int, right: Int, bottom: Int, left: Int) -> String {
    "<w:sectPr><w:headerReference w:type=\"default\" r:id=\"rId6\"/><w:pgSz w:w=\"\(width)\" w:h=\"\(height)\" w:orient=\"portrait\"/><w:pgMar w:top=\"\(top)\" w:right=\"\(right)\" w:bottom=\"\(bottom)\" w:left=\"\(left)\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/><w:pgNumType/><w:docGrid w:linePitch=\"360\"/></w:sectPr>"
}

/// 按 docx 库的文件顺序打包。
private func packDocx(documentXml: String, stylesDefaults: String, headerBody: String, media: [(name: String, data: Data)]) -> Data {
    let now = Date()
    var zip = ZipWriter(date: now)
    let fontTableId = 8 + media.count
    zip.addDirectory("word/")
    zip.addDirectory("word/_rels/")
    zip.addFile("word/_rels/document.xml.rels", documentRels(images: media.map(\.name), fontTableId: fontTableId))
    zip.addFile("word/document.xml", documentXml)
    zip.addFile("word/styles.xml", DocxParts.stylesHead + stylesDefaults + DocxParts.stylesTail)
    zip.addDirectory("docProps/")
    zip.addFile("docProps/core.xml", coreXml(now))
    zip.addFile("word/numbering.xml", DocxParts.numberingXml)
    zip.addDirectory("_rels/")
    zip.addFile("_rels/.rels", DocxParts.rootRels)
    zip.addFile("word/_rels/header1.xml.rels", DocxParts.emptyRels)
    zip.addFile("word/header1.xml", DocxParts.headerHead + headerBody + "</w:hdr>")
    zip.addFile("docProps/custom.xml", DocxParts.customXml)
    zip.addFile("docProps/app.xml", DocxParts.appXml)
    zip.addFile("word/footnotes.xml", DocxParts.footnotesXml)
    zip.addFile("word/_rels/footnotes.xml.rels", DocxParts.emptyRels)
    zip.addFile("word/endnotes.xml", DocxParts.endnotesXml)
    zip.addFile("word/_rels/endnotes.xml.rels", DocxParts.emptyRels)
    zip.addFile("word/settings.xml", DocxParts.settingsXml)
    zip.addFile("word/fontTable.xml", DocxParts.fontTableXml)
    zip.addFile("word/_rels/fontTable.xml.rels", DocxParts.emptyRels)
    zip.addDirectory("word/theme/")
    zip.addFile("word/theme/theme1.xml", DocxParts.themeXml)
    zip.addFile("[Content_Types].xml", DocxParts.contentTypes)
    if !media.isEmpty {
        zip.addDirectory("word/media/")
        for item in media { zip.addFile("word/media/\(item.name)", item.data) }
    }
    return zip.finish()
}

// MARK: - 指南 Word（create-guide-docx.js）

/// 入口校验 content.json（模板的硬约束），返回规范化后的设计说明。
func validateGuideContent(_ content: JSON, _ software: String) throws -> JSON? {
    var errors: [String] = []
    guard content.isObject else { throw StudioError("content.json 不是合法对象") }
    if let name = content["softwareName"]?.string, !name.isEmpty, name != software {
        errors.append("content.softwareName(\(name)) 与 --software(\(software)) 不一致")
    }
    let cover = content["cover"].or(.emptyObject)
    if cover["overview"]?.string?.jsTrimmed.isEmpty ?? true {
        errors.append("cover.overview 缺失或为空（AI 必填的封面介绍）")
    }
    if content.serialized().contains("适用版本"), content["versionPolicy"]?.string != "separate-metadata" {
        errors.append("versionPolicy 非 separate-metadata 时，内容中不得出现“适用版本”")
    }
    let screens = content["screens"].items
    if screens.isEmpty { errors.append("screens 至少需要 1 屏") }
    if let count = content["screenshotCount"]?.number, count.rounded() == count, Int(count) != screens.count {
        errors.append("screenshotCount(\(Int(count))) 与 screens 数量(\(screens.count)) 不一致")
    }
    var seenCaptions = Set<String>()
    for (index, screen) in screens.enumerated() {
        let n = index + 1
        let place = screenId(index)
        guard screen.isObject else {
            errors.append("\(place) 不是对象")
            continue
        }
        if screen["title"]?.string?.jsTrimmed.isEmpty ?? true { errors.append("\(place).title 缺失") }
        if screen["text"]?.string?.jsTrimmed.isEmpty ?? true { errors.append("\(place).text 缺失") }
        if screen["image"]?.string?.jsTrimmed.isEmpty ?? true { errors.append("\(place).image 路径缺失") }
        // 图注：必须恰好以“图N ”开头，且全局唯一
        let caption = screen["caption"]?.string?.jsTrimmed ?? ""
        if !caption.hasPrefix("图\(n)") { errors.append("\(place).caption 必须以“图\(n)”开头，实际：\(caption.isEmpty ? "<空>" : caption)") }
        if seenCaptions.contains(caption) { errors.append("图注重复：\(caption)") }
        seenCaptions.insert(caption)
        // 右栏文字不得含“图N ”，否则 validator 的 /图N[^<]{0,40}/ 会匹配两次
        let text = screen["text"]?.jsString ?? "undefined"
        for k in 1...max(1, screens.count) where Rx.test("图\(k)(?![0-9])", text) {
            errors.append("\(place).text 含“图\(k)”字样，会与图注重复触发校验失败；请改写右栏文字")
            break
        }
        let chars = textLength(screen["text"].text)
        if chars < GuideConstants.FEATURE_TEXT_FLOOR {
            errors.append("\(place).text 仅 \(chars) 个字符，低于固定 300 字符地板 \(GuideConstants.FEATURE_TEXT_FLOOR)")
        }
    }
    var design: JSON?
    if let raw = content["design"], !raw.isNull {
        if !raw.isObject || raw["sections"]?.array?.isEmpty ?? true {
            errors.append("design 必须包含非空 sections 数组")
        } else {
            var sections: [JSON] = []
            for (index, section) in raw["sections"].items.enumerated() {
                let place = "design.sections[\(index)]"
                let title = section["title"]?.string?.jsTrimmed ?? ""
                let text = section["text"]?.string?.jsTrimmed ?? ""
                if title.isEmpty { errors.append("\(place).title 缺失") }
                if text.isEmpty { errors.append("\(place).text 缺失") }
                if Rx.test("图[0-9]+(?![0-9])", "\(title)\n\(text)") { errors.append("\(place) 不得使用“图N”字样，以免与截图图注冲突") }
                sections.append(.obj(["title": .string(title), "text": .string(text)]))
            }
            design = .obj(["sections": .array(sections)])
        }
    }
    errors.append(contentsOf: platformProblems(software, "指南正文、标题或设计说明", guideVisibleTexts(content)))
    if !errors.isEmpty { throw StudioError("content.json 校验失败：\n- " + errors.joined(separator: "\n- ")) }
    return design
}

/// Word 图形尺寸使用 EMU；从栏内宽和整页可用高度反推上限，给图注与段落留空间。
func guideImageBounds(caption: String) -> (width: Double, height: Double) {
    let C = GuideConstants.self
    let width = Double(C.COL_IMAGE_WIDTH - 2 * C.CELL_MARGIN_LR) * 635 - 2 * 12700
    let captionFont = Double(C.SIZE_CAPTION) / 2
    let lines = max(1, ceil(Double(caption.jsLength) * captionFont / (width / 12700)))
    let reserved = lines * captionFont * 1.5 + Double(C.BEFORE_CAPTION + C.AFTER_CAPTION) / 20 + 28
    let height = Double(C.PAGE_HEIGHT - C.MARGIN_TOP - C.MARGIN_BOTTOM - 2 * C.CELL_MARGIN_TB) * 635 - reserved * 12700
    return (width, max(12700, height))
}

func guideImageExtent(width: Int, height: Int, caption: String) -> (cx: Int, cy: Int) {
    let bounds = guideImageBounds(caption: caption)
    let originalWidth = Double(width) * 9525
    let originalHeight = Double(height) * 9525
    let scale = min(1, bounds.width / originalWidth, bounds.height / originalHeight)
    return (max(1, Int((originalWidth * scale).rounded(.down))), max(1, Int((originalHeight * scale).rounded(.down))))
}

/// 旧版把截图统一设为 240pt；重新导出前检测这种越过栏宽/页高的布局。
func guideNeedsImageFitRepair(_ file: String) throws -> Bool {
    let zip = try ZipReader(FS.read(file))
    guard let data = try zip.read("word/document.xml") else { throw StudioError("指南 Word 缺少正文") }
    let xml = String(decoding: data, as: UTF8.self)
    let bounds = guideImageBounds(caption: "")
    return Rx.matches(#"<wp:extent\s+cx="([0-9]+)"\s+cy="([0-9]+)""#, xml).contains { groups in
        let width = Double(groups[1] ?? "") ?? 0
        let height = Double(groups[2] ?? "") ?? 0
        return width > bounds.width + 1 || height > bounds.height + 1
    }
}

/// 重排只允许改变布局：正文文字和图片内容/顺序必须与现有 Word 一致。
func guideContentIdentity(_ file: String) throws -> String {
    let zip = try ZipReader(FS.read(file))
    guard let body = try zip.read("word/document.xml"), let relationships = try zip.read("word/_rels/document.xml.rels") else { throw StudioError("指南 Word 部件不完整") }
    let document = try XMLDocument(data: body)
    let rels = try XMLDocument(data: relationships)
    let text = try document.nodes(forXPath: "//*[local-name()='t']").map { $0.stringValue ?? "" }.joined()
    var targets: [String: String] = [:]
    for node in try rels.nodes(forXPath: "//*[local-name()='Relationship']") {
        guard let element = node as? XMLElement, let id = element.attribute(forName: "Id")?.stringValue, let target = element.attribute(forName: "Target")?.stringValue else { continue }
        targets[id] = target
    }
    let ordered = try document.nodes(forXPath: "//*[local-name()='blip']/@*[local-name()='embed']").map { node -> JSON in
        guard let id = node.stringValue, let target = targets[id], let image = try zip.read("word/" + target) else { throw StudioError("指南 Word 图片引用不完整") }
        return .string(sha256Hex(image))
    }
    let allMedia = try zip.entries.filter { $0.name.hasPrefix("word/media/") && !$0.isDirectory }.map { sha256Hex(try zip.read($0)) }.sorted()
    return hashObject(.obj(["text": .string(text), "orderedImages": .array(ordered), "allMedia": JSON(allMedia)]))
}

/// 生成指南 Word：{project}/{software}/{software}指南.docx。返回 region 片段。
@discardableResult
public func createGuideDocx(project: String, software: String, content: JSON) throws -> JSON {
    let C = GuideConstants.self
    let design = try validateGuideContent(content, software)
    var body = ""
    // 封面标题：{软件名} 用户手册
    body += paragraph(spacing(after: 240, before: 480) + jc("center"), guideRun("\(software) 用户手册", size: C.SIZE_COVER_TITLE, color: C.COLOR_TITLE, bold: true))
    let date = content["compileDate"].truthyValue?.jsString ?? content["createdAtCn"].truthyValue?.jsString ?? chineseDate()
    body += paragraph(spacing(after: 80, before: 0) + jc("center"), guideRun("编制时间：\(date)", size: C.SIZE_COVER_META, color: C.COLOR_META))
    if content["versionPolicy"]?.string == "separate-metadata", let version = content["applicableVersion"].truthyValue {
        body += paragraph(spacing(after: 80, before: 0) + jc("center"), guideRun("适用版本：\(version.jsString)", size: C.SIZE_COVER_META, color: C.COLOR_META))
    }
    for (index, text) in splitParagraphs(content["cover"]?["overview"]?.jsString ?? "").enumerated() {
        body += paragraph(spacing(after: C.AFTER_BODY, before: index == 0 ? 240 : 0, line: C.LINE_OVERVIEW) + jc("both"), guideRun(text))
    }

    var region = JSONObject()
    var media: [(name: String, data: Data)] = []
    var imageCounter = 0
    let cellMargins = "<w:tcMar><w:top w:type=\"dxa\" w:w=\"\(C.CELL_MARGIN_TB)\"/><w:left w:type=\"dxa\" w:w=\"\(C.CELL_MARGIN_LR)\"/><w:bottom w:type=\"dxa\" w:w=\"\(C.CELL_MARGIN_TB)\"/><w:right w:type=\"dxa\" w:w=\"\(C.CELL_MARGIN_LR)\"/></w:tcMar>"
    let tableBorders = ["top", "left", "bottom", "right", "insideH", "insideV"].map { border($0, "single", C.COLOR_TABLE_BORDER, C.TABLE_BORDER_SIZE) }.joined()
    for (index, screen) in content["screens"].items.enumerated() {
        let n = index + 1
        let id = screenId(index)
        let imageRel = screen["image"]?.string ?? ""
        let imageAbs = Path.isAbsolute(imageRel) ? imageRel : Path.join(project, imageRel)
        guard FS.exists(imageAbs) else { throw StudioError("\(id) 截图不存在：\(imageAbs)") }
        let data = try FS.read(imageAbs)
        let size = try readImageSize(data, imageAbs)
        let caption = screen["caption"]?.string?.jsTrimmed ?? ""
        let extent = guideImageExtent(width: size.width, height: size.height, caption: caption)
        let name = "\(sha1Hex(data)).\(size.type)"
        var mediaIndex = media.firstIndex { $0.name == name }
        if mediaIndex == nil {
            media.append((name, data))
            mediaIndex = media.count - 1
        }
        imageCounter += 1
        let cx = extent.cx
        let cy = extent.cy
        let drawing = "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:effectExtent t=\"0\" r=\"0\" b=\"0\" l=\"0\"/><wp:docPr id=\"\(imageCounter)\" name=\"\" descr=\"\" title=\"\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:nvPicPr><pic:cNvPr id=\"0\" name=\"\" descr=\"\"/><pic:cNvPicPr><a:picLocks noChangeAspect=\"1\" noChangeArrowheads=\"1\"/></pic:cNvPicPr></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"rId\(8 + mediaIndex!)\" cstate=\"none\"/><a:srcRect/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr bwMode=\"auto\"><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        let title = screen["title"]?.string?.jsTrimmed ?? ""
        let leftCell = "<w:tc><w:tcPr><w:tcW w:type=\"dxa\" w:w=\"\(C.COL_IMAGE_WIDTH)\"/>\(cellMargins)<w:vAlign w:val=\"center\"/></w:tcPr>"
            + paragraph(spacing(after: 0, before: 0) + jc("center"), drawing)
            + paragraph(spacing(after: C.AFTER_CAPTION, before: C.BEFORE_CAPTION) + jc("center"), guideRun(caption, size: C.SIZE_CAPTION, color: C.COLOR_CAPTION))
            + "</w:tc>"
        var rightCell = "<w:tc><w:tcPr><w:tcW w:type=\"dxa\" w:w=\"\(C.COL_TEXT_WIDTH)\"/>\(cellMargins)<w:vAlign w:val=\"top\"/></w:tcPr>"
            + paragraph(spacing(after: C.AFTER_FEATURE_TITLE, before: 0) + jc("left"), guideRun(title, size: C.SIZE_FEATURE_TITLE, color: C.COLOR_TITLE, bold: true))
        for text in splitParagraphs(screen["text"]?.jsString ?? "") {
            rightCell += paragraph(spacing(after: C.AFTER_BODY, before: 0, line: C.LINE_BODY) + jc("both"), guideRun(text))
        }
        rightCell += "</w:tc>"
        // 第 2 屏起，节前插分页符，保证每屏独占一页且尾部不留空白
        body += paragraph((n > 1 ? "<w:pageBreakBefore/>" : "") + spacing(after: 0, before: 0))
        // 软件指南生成器补丁：整行不跨页，防止「图N」图注单独掉到下一页。
        body += "<w:tbl><w:tblPr><w:tblW w:type=\"dxa\" w:w=\"\(C.USABLE_WIDTH)\"/><w:tblLayout w:type=\"fixed\"/><w:tblBorders>\(tableBorders)</w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w=\"\(C.COL_IMAGE_WIDTH)\"/><w:gridCol w:w=\"\(C.COL_TEXT_WIDTH)\"/></w:tblGrid><w:tr><w:trPr><w:cantSplit/></w:trPr>\(leftCell)\(rightCell)</w:tr></w:tbl>"
        region[id] = .obj([
            "label": .string(title),
            "caption": .string(caption),
            "image": screen["image"] ?? .null,
            "image_size": screen["image_size"].truthyValue ?? .string("\(size.width)x\(size.height)"),
            "text_anchor": screen["text_anchor"].truthyValue ?? .string(title),
            "summary": screen["summary"].truthyValue ?? .string(caption),
        ])
    }
    for (index, section) in (design?["sections"].items ?? []).enumerated() {
        let id = "design.section-\(String(index + 1).padStart(2))"
        let title = section["title"]?.string ?? ""
        let text = section["text"]?.string ?? ""
        body += paragraph((index == 0 ? "<w:pageBreakBefore/>" : "") + spacing(after: C.AFTER_FEATURE_TITLE, before: 0) + jc("left"), guideRun(title, size: C.SIZE_FEATURE_TITLE, color: C.COLOR_TITLE, bold: true))
        for paragraphText in splitParagraphs(text) {
            body += paragraph(spacing(after: C.AFTER_BODY, before: 0, line: C.LINE_BODY) + jc("both"), guideRun(paragraphText))
        }
        region[id] = .obj(["label": .string(title), "summary": .string(text.jsSlice(0, 80))])
    }
    body += sectionProperties(width: C.PAGE_WIDTH, height: C.PAGE_HEIGHT, top: C.MARGIN_TOP, right: C.MARGIN_RIGHT, bottom: C.MARGIN_BOTTOM, left: C.MARGIN_LEFT)

    // 页眉：左软件名，右「第 X 页」页码域（两格无边框表格）
    let noBorder = ["top", "left", "bottom", "right"].map { border($0, "none", "FFFFFF", 0) }.joined()
    let headerTableBorders = ["top", "left", "bottom", "right", "insideH", "insideV"].map { border($0, "none", "FFFFFF", 0) }.joined()
    let half = Int(jsRound(Double(C.USABLE_WIDTH) / 2))
    let headerRunProps = "<w:rPr>\(rFonts(C.FONT_CJK))<w:color w:val=\"\(C.COLOR_META)\"/><w:sz w:val=\"\(C.SIZE_HEADER)\"/><w:szCs w:val=\"\(C.SIZE_HEADER)\"/></w:rPr>"
    let pageField = "<w:r>\(headerRunProps)<w:fldChar w:fldCharType=\"begin\"/><w:instrText xml:space=\"preserve\">PAGE</w:instrText><w:fldChar w:fldCharType=\"separate\"/><w:fldChar w:fldCharType=\"end\"/></w:r>"
    let header = "<w:tbl><w:tblPr><w:tblW w:type=\"dxa\" w:w=\"\(C.USABLE_WIDTH)\"/><w:tblBorders>\(headerTableBorders)</w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w=\"\(half)\"/><w:gridCol w:w=\"\(half)\"/></w:tblGrid><w:tr>"
        + "<w:tc><w:tcPr><w:tcW w:type=\"dxa\" w:w=\"\(half)\"/><w:tcBorders>\(noBorder)</w:tcBorders></w:tcPr>" + paragraph(spacing(after: 0, before: 0) + jc("left"), guideRun(software, size: C.SIZE_HEADER, color: C.COLOR_META)) + "</w:tc>"
        + "<w:tc><w:tcPr><w:tcW w:type=\"dxa\" w:w=\"\(half)\"/><w:tcBorders>\(noBorder)</w:tcBorders></w:tcPr>" + paragraph(spacing(after: 0, before: 0) + jc("right"), guideRun("第 ", size: C.SIZE_HEADER, color: C.COLOR_META) + pageField + guideRun(" 页", size: C.SIZE_HEADER, color: C.COLOR_META)) + "</w:tc>"
        + "</w:tr></w:tbl>"

    let defaults = "<w:docDefaults><w:rPrDefault><w:rPr>\(rFonts(C.FONT_CJK))<w:color w:val=\"\(C.COLOR_BODY)\"/><w:sz w:val=\"\(C.SIZE_BODY)\"/><w:szCs w:val=\"\(C.SIZE_BODY)\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"\(C.AFTER_BODY)\" w:line=\"\(C.LINE_BODY)\"/><w:jc w:val=\"both\"/></w:pPr></w:pPrDefault></w:docDefaults>"
    let documentXml = DocxParts.documentHead + "<w:body>" + body + "</w:body></w:document>"
    let deliveryDir = Path.join(project, software)
    try FS.mkdirp(deliveryDir)
    try FS.write(Path.join(deliveryDir, "\(software)\(C.GUIDE_SUFFIX).docx"), packDocx(documentXml: documentXml, stylesDefaults: defaults, headerBody: header, media: media))
    return .object(region)
}

// MARK: - 代码 Word（create-code-docx.js）

/// 代码正文只来自项目指定的代码来源，不内置任何代码。
public func createCodeDocx(project: String, software: String, body: String) throws {
    let font = "新宋体"
    let normalized = Rx.replaceFirst("^\u{FEFF}", in: body, with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    let runProps = "<w:rPr>\(rFonts(font))<w:sz w:val=\"18\"/><w:szCs w:val=\"18\"/></w:rPr>"
    let paragraphProps = "<w:pPr><w:spacing w:after=\"0\" w:before=\"0\" w:line=\"240\"/><w:ind w:left=\"0\" w:right=\"0\" w:firstLine=\"0\"/><w:jc w:val=\"both\"/></w:pPr>"
    var xml = ""
    xml.reserveCapacity(lines.count * 360)
    for line in lines {
        xml += "<w:p>\(paragraphProps)<w:r>\(runProps)<w:t xml:space=\"preserve\">\(xmlText(line.isEmpty ? " " : line))</w:t></w:r></w:p>"
    }
    xml += sectionProperties(width: 11906, height: 16838, top: 1440, right: 1200, bottom: 1440, left: 1200)
    let header = "<w:p><w:pPr><w:spacing w:after=\"0\" w:before=\"0\"/><w:jc w:val=\"left\"/></w:pPr><w:r><w:rPr>\(rFonts(font))<w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/></w:rPr><w:t xml:space=\"preserve\">\(xmlText(software))</w:t></w:r></w:p>"
    let defaults = "<w:docDefaults><w:rPrDefault><w:rPr>\(rFonts(font))<w:sz w:val=\"18\"/><w:szCs w:val=\"18\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"0\" w:before=\"0\" w:line=\"240\"/><w:jc w:val=\"both\"/></w:pPr></w:pPrDefault></w:docDefaults>"
    let documentXml = DocxParts.documentHead + "<w:body>" + xml + "</w:body></w:document>"
    let deliveryDir = Path.join(project, software)
    try FS.mkdirp(deliveryDir)
    try FS.write(Path.join(deliveryDir, "\(software)\(GuideConstants.CODE_SUFFIX).docx"), packDocx(documentXml: documentXml, stylesDefaults: defaults, headerBody: header, media: []))
}

// MARK: - TXT（create-guide-txt.js）

let TXT_DEFAULT_FIELDS = DEFAULT_TXT_FIELDS

/// 环境字段可配置（默认值与原模板一致），源程序量按代码来源实际行数填写。
public func createGuideTxt(project: String, software: String, overview: String, fields: [String: String], sourceLines: Int) throws {
    var f = TXT_DEFAULT_FIELDS
    for (key, value) in fields { f[key] = value }
    let template = [
        "【开发的硬件环境】\(f["devHardware"] ?? "")",
        "【开发该软件的操作系统】\(f["devOs"] ?? "")",
        "【软件开发环境/开发工具】\(f["devTools"] ?? "")",
        "【编程语言】\(f["language"] ?? "")",
        "【源程序量】\(sourceLines > 0 ? "\(sourceLines)行" : "")",
        "【软件的主要功能】",
    ].joined(separator: "\r\n")
    let formatted = Rx.split(#"\n+"#, overview.replacingOccurrences(of: "\r\n", with: "\n")).map(\.jsTrimmed).filter { !$0.isEmpty }.joined(separator: "\r\n")
    let deliveryDir = Path.join(project, software)
    try FS.mkdirp(deliveryDir)
    try FS.write(Path.join(deliveryDir, "\(software)\(GuideConstants.GUIDE_SUFFIX).txt"), "\(template)\r\n\(formatted)\r\n")
}
