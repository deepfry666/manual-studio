import Foundation
@testable import StudioCore

/// 测试用的代码 Word 模板：结构和实际使用的模板一样（单节、每段一行、页眉是软件名、带自定义属性），
/// 代码是虚构的。3322 行，其中 3229 行非空；空白行有一半是纯空格，用来检查空格原样保留。
/// 用户自己的模板不放进仓库和安装包。
let TEST_TEMPLATE_HEADER = "示例游戏软件V1.0"

let testCodeTemplatePath: String = {
    let dir = try! FS.makeTempDirectory(prefix: "code-template-fixture-")
    let path = Path.join(dir, "示例代码模板.docx")
    try! FS.write(path, makeTestCodeTemplate())
    return path
}()

private let W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
private let R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

private func codeLine(_ index: Int, _ variant: Int) -> String {
    let module = index / 400
    switch index % 9 {
    case 0: return "package com.example.demo\(variant == 0 ? "" : "\(variant)").module\(module);"
    case 1: return "import com.example.demo.common.Result\(module);"
    case 2: return "public class DemoController\(index) {"
    case 3: return "    private final DemoService service\(index) = new DemoService();"
    case 4: return "    public Result query\(index)(String keyword, int page) {"
    case 5: return "        if (keyword == null) { return Result.fail(\"empty\"); }"
    case 6: return "        return service\(index - 3).list(keyword, page, 20);"
    case 7: return "    }"
    default: return "}"
    }
}

/// variant 不同，代码内容就不同（测试多个模板用）；lineCount 是段落数。
func makeTestCodeTemplate(variant: Int = 0, lineCount: Int = 3322) -> Data {
    let runProps = #"<w:rPr><w:rFonts w:ascii="新宋体" w:hAnsi="新宋体" w:eastAsia="新宋体" w:cs="新宋体"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr>"#
    let paraProps = #"<w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/><w:jc w:val="both"/></w:pPr>"#
    let blanks = Set((0..<93).map { 17 + 35 * $0 })
    var body = ""
    for index in 0..<lineCount {
        if blanks.contains(index) {
            body += index % 2 == 0
                ? "<w:p>\(paraProps)<w:r>\(runProps)<w:t xml:space=\"preserve\">    </w:t></w:r></w:p>"
                : "<w:p>\(paraProps)</w:p>"
        } else {
            body += "<w:p>\(paraProps)<w:r>\(runProps)<w:t xml:space=\"preserve\">\(xmlText(codeLine(index, variant)))</w:t></w:r></w:p>"
        }
    }
    let sect = #"<w:sectPr><w:headerReference r:id="rId5" w:type="default"/><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1200" w:bottom="1440" w:left="1200" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>"#
    let document = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n<w:document xmlns:w=\"\(W)\" xmlns:r=\"\(R)\"><w:body>\(body)\(sect)</w:body></w:document>"
    let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n<w:hdr xmlns:w=\"\(W)\" xmlns:r=\"\(R)\"><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/><w:jc w:val=\"left\"/></w:pPr><w:r>\(runProps.replacingOccurrences(of: "18", with: "22"))<w:t>\(TEST_TEMPLATE_HEADER)</w:t></w:r></w:p></w:hdr>"
    let files: [(String, String)] = [
        ("[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/><Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>"#),
        ("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="docProps/custom.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#),
        ("docProps/app.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Pages>60</Pages><Application>StudioCore tests</Application></Properties>"#),
        ("docProps/custom.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="Source"><vt:lpwstr>tests</vt:lpwstr></property></Properties>"#),
        ("word/_rels/document.xml.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/></Relationships>"#),
        ("word/styles.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults/></w:styles>"#),
        ("word/header1.xml", header),
        ("word/document.xml", document),
    ]
    var zip = ZipWriter()
    for (name, text) in files { zip.addFile(name, Data(text.utf8)) }
    return zip.finish()
}
