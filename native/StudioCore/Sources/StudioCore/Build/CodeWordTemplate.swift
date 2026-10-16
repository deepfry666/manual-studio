import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Word 模板直接复制，正文和样式保留；按源代码段落分页，不补空白、不重复代码。
public struct CodeWordTemplate: Sendable {
    public static let targetPages = 60
    public static let minimumNonEmptyLines = 3001
    public static let minimumPages = 60
    public let data: Data
    public let lines: [String]
    public var plannedPages: Int { Self.targetPages }
    public var nonEmptyLines: Int { lines.filter { !$0.jsTrimmed.isEmpty }.count }
    public var pageRanges: [Range<Int>] {
        (0..<Self.targetPages).map { page in
            (page * lines.count / Self.targetPages)..<((page + 1) * lines.count / Self.targetPages)
        }
    }
    public var sha256: String { sha256Hex(data) }

    public static var bundledPath: String {
        Bundle.module.url(forResource: "CodeTemplate", withExtension: "docx")!.path
    }

    public init(data: Data) throws {
        guard data.count <= MAX_CODE_BYTES else { throw StudioError("Word 代码模板超过 30MB") }
        let zip = try ZipReader(data)
        guard zip.entries.contains(where: { $0.name == "docProps/custom.xml" }) else {
            throw StudioError("Word 代码模板缺少自定义属性，请使用内置新模板")
        }
        guard let bodyData = try zip.read("word/document.xml") else { throw StudioError("Word 模板缺少正文") }
        let document = try Self.parse(bodyData)
        let bodies = try document.nodes(forXPath: "/*[local-name()='document']/*[local-name()='body']")
        guard let body = bodies.first as? XMLElement else { throw StudioError("Word 模板缺少正文") }
        let children = (body.children ?? []).compactMap { $0 as? XMLElement }
        guard children.allSatisfy({ ["p", "sectPr"].contains($0.localName ?? "") }),
              children.filter({ $0.localName == "sectPr" }).count == 1,
              try body.nodes(forXPath: ".//*[local-name()='sectPr']").count == 1,
              try body.nodes(forXPath: ".//*[local-name()='drawing' or local-name()='pict' or local-name()='del' or local-name()='ins' or local-name()='br' or local-name()='sdt' or local-name()='fldChar' or local-name()='instrText']").isEmpty
        else { throw StudioError("代码 Word 模板需为单节、每段一行的纯代码正文；不支持表格、图片、修订或段内换行") }
        let paragraphs = children.filter { $0.localName == "p" }
        guard !paragraphs.isEmpty else { throw StudioError("Word 代码模板正文为空") }
        self.data = data
        let reader = CodeTemplateLines()
        let parser = XMLParser(data: bodyData)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.lines.count == paragraphs.count else { throw StudioError("Word 模板正文无法完整读取") }
        self.lines = reader.lines
        guard lines.contains(where: { !$0.jsTrimmed.isEmpty }) else { throw StudioError("Word 代码模板正文为空") }
        guard nonEmptyLines >= Self.minimumNonEmptyLines else {
            throw StudioError("Word 代码模板只有 \(nonEmptyLines) 行非空代码，需要超过 3,000 行；请选择完整模板")
        }
        for range in pageRanges {
            guard lines[range].contains(where: { !$0.jsTrimmed.isEmpty }) else {
                throw StudioError("Word 代码模板包含整页空白段落，请选择完整代码模板")
            }
        }
        let headers = zip.entries.filter { $0.name.hasPrefix("word/header") && $0.name.hasSuffix(".xml") }
        guard !headers.isEmpty else { throw StudioError("Word 代码模板需要软件名页眉") }
        for entry in headers {
            let header = try Self.parse(Data(Self.removePageNumber(String(decoding: try zip.read(entry), as: UTF8.self)).utf8))
            guard try header.nodes(forXPath: "//*[local-name()='fldChar' or local-name()='instrText' or local-name()='drawing' or local-name()='pict']").isEmpty,
                  try header.nodes(forXPath: "//*[local-name()='t']").contains(where: { !($0.stringValue ?? "").jsTrimmed.isEmpty })
            else { throw StudioError("Word 代码模板页眉需为纯文本软件名") }
        }
    }

    private static func parse(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
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

    public func write(project: String, software: String, printFont: String? = nil, printSize: Int? = nil) throws {
        try assertSafeSoftwareName(software)
        let zip = try ZipReader(data)
        let tabPosition = Self.textWidthTwips(String(decoding: try zip.read("word/document.xml") ?? Data(), as: UTF8.self))
        var output = ZipWriter()
        for entry in zip.entries {
            if entry.isDirectory { output.addDirectory(entry.name); continue }
            var bytes = try zip.read(entry)
            if entry.name == "word/document.xml" {
                // 只改分页属性，避免 XML DOM 重新序列化吞掉源代码的纯空格。
                let original = String(decoding: bytes, as: UTF8.self)
                let pattern = try NSRegularExpression(pattern: #"<w:p(?:\s[^>]*)?>[\s\S]*?</w:p>"#)
                let matches = pattern.matches(in: original, range: NSRange(original.startIndex..., in: original))
                guard matches.count == lines.count else { throw StudioError("Word 模板段落结构不支持固定分页") }
                let patched = NSMutableString(string: original)
                for (index, match) in matches.enumerated().reversed() {
                    var paragraph = (original as NSString).substring(with: match.range)
                    paragraph = Rx.replace(#"<w:pageBreakBefore\b[^>]*(?:/>|>\s*</w:pageBreakBefore>)"#, in: paragraph, with: "")
                    if index > 0 && pageRanges.dropFirst().contains(where: { $0.lowerBound == index }) {
                        if Rx.test(#"<w:pPr\s*/>"#, paragraph) {
                            paragraph = Rx.replaceFirst(#"<w:pPr\s*/>"#, in: paragraph, with: "<w:pPr><w:pageBreakBefore/></w:pPr>")
                        } else if Rx.test(#"<w:pPr(?:\s[^>]*)?>"#, paragraph) {
                            paragraph = Rx.replaceFirst(#"(<w:pPr(?:\s[^>]*)?>)"#, in: paragraph, with: "$1<w:pageBreakBefore/>")
                        } else {
                            paragraph = Rx.replaceFirst(#"(<w:p(?:\s[^>]*)?>)"#, in: paragraph, with: "$1<w:pPr><w:pageBreakBefore/></w:pPr>")
                        }
                    }
                    if let printSize {
                        paragraph = Rx.replace(#"<w:sz w:val="[0-9]+"\s*/>"#, in: paragraph, with: "<w:sz w:val=\"\(printSize)\"/>")
                        paragraph = Rx.replace(#"<w:szCs w:val="[0-9]+"\s*/>"#, in: paragraph, with: "<w:szCs w:val=\"\(printSize)\"/>")
                    }
                    if let printFont {
                        paragraph = Rx.replace(#"<w:rFonts\b[^>]*/>"#, in: paragraph, with: "<w:rFonts w:ascii=\"\(xmlText(printFont))\" w:hAnsi=\"\(xmlText(printFont))\" w:eastAsia=\"\(xmlText(printFont))\" w:cs=\"\(xmlText(printFont))\"/>")
                    }
                    patched.replaceCharacters(in: match.range, with: paragraph)
                }
                bytes = Data((patched as String).utf8)
            } else if entry.name.hasPrefix("word/header") && entry.name.hasSuffix(".xml") {
                let header = try Self.parse(Data(Self.removePageNumber(String(decoding: bytes, as: UTF8.self)).utf8))
                let texts = try header.nodes(forXPath: "//*[local-name()='t']")
                for (index, text) in texts.enumerated() { text.stringValue = index == 0 ? software : "" }
                bytes = Data(Self.addPageNumber(String(decoding: header.xmlData(options: [.nodePreserveAll]), as: UTF8.self), tabPosition: tabPosition).utf8)
            } else if entry.name == "docProps/app.xml" {
                let app = try Self.parse(bytes)
                // 缓存页数不能作为验收依据，实际页数写进构建记录。
                for node in try app.nodes(forXPath: "//*[local-name()='Pages']") { node.detach() }
                bytes = app.xmlData(options: [.nodePreserveAll])
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
        // 本机内置模板有自定义属性部件；其他模板需同样有该部件，便于重新导出时保留页数验收。
        guard zip.entries.contains(where: { $0.name == "docProps/custom.xml" }) else {
            throw StudioError("Word 代码模板缺少自定义属性，请使用内置新模板")
        }
        try FS.write(Path.join(project, software, "\(software)\(CODE_SUFFIX).docx"), output.finish())
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
        if inParagraph && elementName == "tab" { line += "\t" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { line += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = false }
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
