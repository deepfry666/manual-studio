import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 代码 Word 模板。用户给的 Word 只取代码正文（每段一行，一字不改；制表符换成 4 个空格），
/// 按 CodeLayout 选成正好 60 页 × 50 行，再写成统一版式的「整理好的模板」。
/// 模板库里存的就是整理好的这份；出交付包时只换页眉里的软件名、加页码，正文和版式原样使用。
public struct CodeWordTemplate: Sendable {
    public static let targetPages = CodeLayout.pages
    /// 整理好的模板在自定义属性里带这个标记，读回时不再重新选行
    static let layoutMark = "ManualStudioCodeLayout"
    static let layoutValue = "60x50"

    /// 整理好的模板（docx 字节）
    public let data: Data
    /// 选进来的代码行（段落），印出来正好 3000 行
    public let lines: [String]
    /// 原模板印出来一共多少行；超过 3000 行的才会被裁
    public let sourceRows: Int
    public let sourceLineCount: Int
    public var cropped: Bool { sourceRows > CodeLayout.totalRows }
    public var plannedPages: Int { CodeLayout.pages }
    public var nonEmptyLines: Int { lines.filter { !$0.jsTrimmed.isEmpty }.count }
    /// 页面上的每一行（折行后），正好 3000 行
    public var rows: [String] { lines.flatMap(codeRows) }
    public var sha256: String { sha256Hex(data) }

    /// 读整理好的模板，或把用户给的原始 Word 整理成统一版式（只在内存里，不改原文件）。
    public init(data: Data) throws {
        guard data.count <= MAX_CODE_BYTES else { throw StudioError("Word 代码模板超过 30MB") }
        let zip = try ZipReader(data)
        guard let bodyData = try zip.read("word/document.xml") else { throw StudioError("Word 模板缺少正文") }
        let custom = try zip.read("docProps/custom.xml").map { String(decoding: $0, as: UTF8.self) } ?? ""
        let raw = try Self.readLines(bodyData)
        if custom.contains("name=\"\(Self.layoutMark)\"") {
            guard raw.reduce(0, { $0 + codeRowCount($1) }) == CodeLayout.totalRows else { throw StudioError("整理好的代码模板行数不对，请重新添加模板") }
            self.data = data
            self.lines = raw
            self.sourceRows = Int(Rx.match(#"name="ManualStudioSourceRows"[^>]*>\s*<vt:i4>([0-9]+)<"#, custom)?[1] ?? "") ?? CodeLayout.totalRows
            self.sourceLineCount = Int(Rx.match(#"name="ManualStudioSourceLines"[^>]*>\s*<vt:i4>([0-9]+)<"#, custom)?[1] ?? "") ?? raw.count
            return
        }
        let total = raw.reduce(0, { $0 + codeRowCount($1) })
        guard let selected = selectCodeLines(raw) else {
            if total < CodeLayout.totalRows {
                throw StudioError("这份代码印出来只有 \(total) 行，不够 60 页 × 50 行（3000 行），还差 \(CodeLayout.totalRows - total) 行")
            }
            throw StudioError("这份代码没法正好排成 60 页 × 50 行，请换一份模板")
        }
        self.lines = selected
        self.sourceRows = total
        self.sourceLineCount = raw.count
        self.data = Self.canonicalDocx(lines: selected, sourceRows: total, sourceLines: raw.count, sourceSha: sha256Hex(data))
    }

    /// 只认每段一行的纯代码正文；表格、图片、修订、段内换行这类排版没法逐行对应，直接拒绝。
    static func readLines(_ bodyData: Data) throws -> [String] {
        let document = try XMLDocument(data: bodyData, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        let bodies = try document.nodes(forXPath: "/*[local-name()='document']/*[local-name()='body']")
        guard let body = bodies.first as? XMLElement else { throw StudioError("Word 模板缺少正文") }
        let children = (body.children ?? []).compactMap { $0 as? XMLElement }
        guard children.allSatisfy({ ["p", "sectPr", "bookmarkStart", "bookmarkEnd"].contains($0.localName ?? "") }) else {
            throw StudioError("代码 Word 模板只能有代码正文，不支持表格、图片或文本框")
        }
        guard try body.nodes(forXPath: ".//*[local-name()='drawing' or local-name()='pict' or local-name()='del' or local-name()='ins' or local-name()='sdt' or local-name()='tbl' or local-name()='txbxContent']").isEmpty,
              try body.nodes(forXPath: ".//*[local-name()='br'][not(@*[local-name()='type']) or @*[local-name()='type']='textWrapping']").isEmpty
        else { throw StudioError("代码 Word 模板需为每段一行的纯代码正文；不支持表格、图片、修订或段内换行") }
        let paragraphs = children.filter { $0.localName == "p" }
        guard !paragraphs.isEmpty else { throw StudioError("Word 代码模板正文为空") }
        let reader = CodeTemplateLines()
        let parser = XMLParser(data: bodyData)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.lines.count == paragraphs.count else { throw StudioError("Word 模板正文无法完整读取") }
        let lines = reader.lines.map { line in
            String(line.replacingOccurrences(of: "\t", with: "    ").unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" })
        }
        guard lines.contains(where: { !$0.jsTrimmed.isEmpty }) else { throw StudioError("Word 代码模板正文为空") }
        return lines
    }

    // MARK: 整理好的模板

    private static let W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let font = "新宋体"
    static var runProps: String {
        #"<w:rPr><w:rFonts w:ascii="\#(font)" w:hAnsi="\#(font)" w:eastAsia="\#(font)" w:cs="\#(font)"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr>"#
    }
    /// 关孤行控制（一行代码折成两行时允许跨页）、允许西文在单词中间换行、关中英文自动空格和中文标点规则，
    /// Word 的折行和分页就和 CodeLayout 算的一致。
    static var paraProps: String {
        #"<w:pPr><w:widowControl w:val="0"/><w:wordWrap w:val="0"/><w:kinsoku w:val="0"/><w:overflowPunct w:val="0"/><w:autoSpaceDE w:val="0"/><w:autoSpaceDN w:val="0"/><w:adjustRightInd w:val="0"/><w:snapToGrid w:val="1"/><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:left="0" w:right="0" w:firstLine="0"/><w:jc w:val="left"/></w:pPr>"#
    }

    static func canonicalDocx(lines: [String], sourceRows: Int, sourceLines: Int, sourceSha: String) -> Data {
        let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        var body = ""
        body.reserveCapacity(lines.count * 160)
        for line in lines {
            if line.isEmpty { body += "<w:p>\(paraProps)</w:p>" }
            else { body += "<w:p>\(paraProps)<w:r>\(runProps)<w:t xml:space=\"preserve\">\(xmlText(line))</w:t></w:r></w:p>" }
        }
        let L = CodeLayout.self
        let sect = #"<w:sectPr><w:headerReference w:type="default" r:id="rIdHeader1"/><w:pgSz w:w="\#(L.pageWidthTwips)" w:h="\#(L.pageHeightTwips)"/><w:pgMar w:top="\#(L.marginTopTwips)" w:right="\#(L.marginRightTwips)" w:bottom="\#(L.marginBottomTwips)" w:left="\#(L.marginLeftTwips)" w:header="\#(L.headerTwips)" w:footer="\#(L.footerTwips)" w:gutter="0"/><w:cols w:space="425"/><w:docGrid w:type="lines" w:linePitch="\#(L.linePitchTwips)"/></w:sectPr>"#
        let document = head + "<w:document xmlns:w=\"\(W)\" xmlns:r=\"\(R)\"><w:body>\(body)\(sect)</w:body></w:document>"
        let headerRun = runProps.replacingOccurrences(of: "\"18\"", with: "\"22\"")
        let header = head + "<w:hdr xmlns:w=\"\(W)\" xmlns:r=\"\(R)\"><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/><w:jc w:val=\"left\"/></w:pPr><w:r>\(headerRun)<w:t>软件名称</w:t></w:r></w:p></w:hdr>"
        let styles = head + "<w:styles xmlns:w=\"\(W)\"><w:docDefaults><w:rPrDefault>\(runProps)</w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style></w:styles>"
        let settings = head + "<w:settings xmlns:w=\"\(W)\"><w:defaultTabStop w:val=\"420\"/><w:characterSpacingControl w:val=\"doNotCompress\"/><w:compat><w:spaceForUL/><w:balanceSingleByteDoubleByteWidth/><w:doNotLeaveBackslashAlone/><w:ulTrailSpace/><w:doNotExpandShiftReturn/><w:adjustLineHeightInTable/><w:useFELayout/></w:compat></w:settings>"
        func property(_ pid: Int, _ name: String, _ value: String) -> String {
            "<property fmtid=\"{D5CDD505-2E9C-101B-9397-08002B2CF9AE}\" pid=\"\(pid)\" name=\"\(name)\">\(value)</property>"
        }
        let custom = head + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/custom-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
            + property(2, layoutMark, "<vt:lpwstr>\(layoutValue)</vt:lpwstr>")
            + property(3, "ManualStudioSourceRows", "<vt:i4>\(sourceRows)</vt:i4>")
            + property(4, "ManualStudioSourceLines", "<vt:i4>\(sourceLines)</vt:i4>")
            + property(5, "ManualStudioSourceSha256", "<vt:lpwstr>\(sourceSha)</vt:lpwstr>")
            + "</Properties>"
        let app = head + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"><Application>ManualStudio</Application></Properties>"
        let types = head + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/><Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/><Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/></Types>"#
        let rootRels = head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="docProps/custom.xml"/></Relationships>"#
        let docRels = head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rIdSettings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/><Relationship Id="rIdHeader1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/></Relationships>"#
        // 固定时间戳：同一份模板每次整理出一模一样的文件，模板库靠指纹认出同一份
        var zip = ZipWriter(date: Date(timeIntervalSince1970: 1_767_225_600))
        for (name, text) in [("[Content_Types].xml", types), ("_rels/.rels", rootRels), ("docProps/app.xml", app), ("docProps/custom.xml", custom),
                             ("word/_rels/document.xml.rels", docRels), ("word/styles.xml", styles), ("word/settings.xml", settings),
                             ("word/header1.xml", header), ("word/document.xml", document)] {
            zip.addFile(name, Data(text.utf8))
        }
        return zip.finish()
    }

    // MARK: 页眉页码
    // 软著源程序材料要在页眉写软件名和版本号，右上角标页码。页码用 Word 的 PAGE 域，
    // 前后用书签包住，再次生成或读回时能原样去掉，不会叠加。

    private static let pageMarkStart = #"<w:bookmarkStart w:id="90201" w:name="_ManualStudioPageNo"/>"#
    private static let pageMarkEnd = #"<w:bookmarkEnd w:id="90201"/>"#
    private static let pageTabs = #"<w:tabs><w:tab w:val="right" w:pos="[0-9]+"/></w:tabs>"#

    /// 正文宽度（页宽减左右页边距，单位 twip），页码靠这个位置的右对齐制表位放到右上角。
    static func textWidthTwips(_ document: String) -> Int {
        let width = Rx.match(#"<w:pgSz\b[^>]*\bw:w="([0-9]+)""#, document)?[1].flatMap { Int($0) } ?? 11906
        let margin = Rx.match(#"<w:pgMar\b[^>]*>"#, document)?[0] ?? ""
        let left = Rx.match(#"\bw:left="([0-9]+)""#, margin)?[1].flatMap { Int($0) } ?? 1200
        let right = Rx.match(#"\bw:right="([0-9]+)""#, margin)?[1].flatMap { Int($0) } ?? 1200
        return max(1000, width - left - right)
    }

    static func removePageNumber(_ header: String) -> String {
        var text = Rx.replace(NSRegularExpression.escapedPattern(for: pageMarkStart) + #"[\s\S]*?"# + NSRegularExpression.escapedPattern(for: pageMarkEnd), in: header, with: "")
        text = Rx.replace(pageTabs, in: text, with: "")
        return text
    }

    /// 在第一个有文字的页眉段落末尾加「第 N 页」，字体字号沿用软件名那一段。
    static func addPageNumber(_ header: String, tabPosition: Int) -> String {
        let ns = header as NSString
        guard let regex = try? NSRegularExpression(pattern: #"<w:p(?:\s[^>]*)?>[\s\S]*?</w:p>"#),
              let match = regex.matches(in: header, range: NSRange(location: 0, length: ns.length)).first(where: { ns.substring(with: $0.range).contains("<w:t") })
        else { return header }
        var paragraph = ns.substring(with: match.range)
        let runProps = Rx.match(#"<w:rPr>[\s\S]*?</w:rPr>"#, paragraph)?[0] ?? ""
        let tabs = #"<w:tabs><w:tab w:val="right" w:pos="\#(tabPosition)"/></w:tabs>"#
        if Rx.test(#"<w:pPr\s*/>"#, paragraph) {
            paragraph = Rx.replaceFirst(#"<w:pPr\s*/>"#, in: paragraph, with: "<w:pPr>\(tabs)</w:pPr>")
        } else if Rx.test(#"<w:pPr(?:\s[^>]*)?>"#, paragraph) {
            paragraph = Rx.replaceFirst(#"(<w:pPr(?:\s[^>]*)?>)"#, in: paragraph, with: "$1\(tabs)")
        } else {
            paragraph = Rx.replaceFirst(#"(<w:p(?:\s[^>]*)?>)"#, in: paragraph, with: "$1<w:pPr>\(tabs)</w:pPr>")
        }
        func run(_ inner: String) -> String { "<w:r>\(runProps)\(inner)</w:r>" }
        let field = pageMarkStart
            + run(#"<w:tab/><w:t xml:space="preserve">第 </w:t>"#)
            + run(#"<w:fldChar w:fldCharType="begin"/>"#)
            + run(#"<w:instrText xml:space="preserve"> PAGE </w:instrText>"#)
            + run(#"<w:fldChar w:fldCharType="separate"/>"#)
            + run("<w:t>1</w:t>")
            + run(#"<w:fldChar w:fldCharType="end"/>"#)
            + run(#"<w:t xml:space="preserve"> 页</w:t>"#)
            + pageMarkEnd
        paragraph = paragraph.replacingOccurrences(of: "</w:p>", with: field + "</w:p>", options: .backwards, range: paragraph.range(of: "</w:p>", options: .backwards))
        return ns.replacingCharacters(in: match.range, with: paragraph)
    }

    /// 写交付用的代码 Word：正文和版式原样，页眉换成软件名并加页码，记下「正好 60 页」供重新导出时核对。
    public func write(project: String, software: String) throws {
        try assertSafeSoftwareName(software)
        let zip = try ZipReader(data)
        let tabPosition = Self.textWidthTwips(String(decoding: try zip.read("word/document.xml") ?? Data(), as: UTF8.self))
        var output = ZipWriter()
        for entry in zip.entries {
            if entry.isDirectory { output.addDirectory(entry.name); continue }
            var bytes = try zip.read(entry)
            if entry.name.hasPrefix("word/header") && entry.name.hasSuffix(".xml") {
                let header = try Self.parse(Data(Self.removePageNumber(String(decoding: bytes, as: UTF8.self)).utf8))
                let texts = try header.nodes(forXPath: "//*[local-name()='t']")
                for (index, text) in texts.enumerated() { text.stringValue = index == 0 ? software : "" }
                bytes = Data(Self.addPageNumber(String(decoding: header.xmlData(options: [.nodePreserveAll]), as: UTF8.self), tabPosition: tabPosition).utf8)
            } else if entry.name == "docProps/custom.xml" {
                let custom = try Self.parse(bytes)
                guard let root = custom.rootElement() else { throw StudioError("Word 自定义属性损坏") }
                for node in try custom.nodes(forXPath: "//*[local-name()='property'][@name='ManualStudioCodeMinimumPages' or @name='ManualStudioCodeExactPages']") { node.detach() }
                let maxId = (root.children ?? []).compactMap { ($0 as? XMLElement)?.attribute(forName: "pid")?.stringValue }.compactMap(Int.init).max() ?? 1
                let prop = XMLElement(name: "property")
                prop.addAttribute(XMLNode.attribute(withName: "fmtid", stringValue: "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}") as! XMLNode)
                prop.addAttribute(XMLNode.attribute(withName: "pid", stringValue: String(maxId + 1)) as! XMLNode)
                prop.addAttribute(XMLNode.attribute(withName: "name", stringValue: "ManualStudioCodeExactPages") as! XMLNode)
                let value = XMLElement(name: "vt:i4", stringValue: String(Self.targetPages))
                value.addNamespace(XMLNode.namespace(withName: "vt", stringValue: "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes") as! XMLNode)
                prop.addChild(value)
                root.addChild(prop)
                bytes = custom.xmlData(options: [.nodePreserveAll])
            }
            output.addFile(entry.name, bytes)
        }
        try FS.write(Path.join(project, software, "\(software)\(CODE_SUFFIX).docx"), output.finish())
    }

    private static func parse(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
    }
}

private final class CodeTemplateLines: NSObject, XMLParserDelegate {
    var lines: [String] = []
    private var inBody = false
    private var inParagraph = false
    private var inText = false
    private var line = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "body" { inBody = true }
        if inBody && elementName == "p" { inParagraph = true; line = "" }
        if inParagraph && elementName == "t" { inText = true }
        if inParagraph && elementName == "tab" && !inTabs { line += "\t" }
        if elementName == "tabs" { inTabs = true }
    }
    private var inTabs = false
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { line += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = false }
        if elementName == "tabs" { inTabs = false }
        if inBody && elementName == "p" { lines.append(line); inParagraph = false }
        if elementName == "body" { inBody = false }
    }
}

/// 带分页验收标记的 Word，在首次导出和重新导出时都必须核对实际 PDF。
func codeMinimumPages(_ docxPath: String) throws -> Int? {
    let zip = try ZipReader(try FS.read(docxPath))
    guard let data = try zip.read("docProps/custom.xml") else { return nil }
    let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    let nodes = try doc.nodes(forXPath: "//*[local-name()='property'][@name='ManualStudioCodeMinimumPages']/*")
    return nodes.first?.stringValue.flatMap(Int.init)
}

func requireCodePdfPages(_ path: String, minimum: Int) throws -> Int {
    guard let pages = countPdfPages(path) else { throw StudioError("无法读取代码 PDF 页数，未交付") }
    guard pages >= minimum else { throw StudioError("代码 PDF 只有 \(pages) 页，少于 \(minimum) 页，正式交付包未改动") }
    return pages
}

func codeExactPages(_ docxPath: String) throws -> Int? {
    let zip = try ZipReader(try FS.read(docxPath))
    guard let data = try zip.read("docProps/custom.xml") else { return nil }
    let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    let nodes = try doc.nodes(forXPath: "//*[local-name()='property'][@name='ManualStudioCodeExactPages']/*")
    return nodes.first?.stringValue.flatMap(Int.init)
}

func requireExactCodePdfPages(_ path: String, pages expected: Int = 60) throws -> Int {
    guard let pages = countPdfPages(path) else { throw StudioError("无法读取代码 PDF 页数，未交付") }
    guard pages == expected else { throw StudioError("代码 PDF 为 \(pages) 页，要求正好 \(expected) 页，正式交付包未改动") }
    return pages
}
