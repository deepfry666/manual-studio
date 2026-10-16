import Foundation

public let GUIDE_SUFFIX = "指南"
public let CODE_SUFFIX = "指南_代码-（JAVA）"

/// 交付包里应有的文件（顺序和 Electron 版一致：说明书 docx、txt、pdf，代码 docx、pdf）。
public func expectedBundleFiles(_ name: String, withCode: Bool, withPdf: Bool) -> [(role: String, file: String)] {
    var files = [("guideDocx", "\(name)\(GUIDE_SUFFIX).docx"), ("guideTxt", "\(name)\(GUIDE_SUFFIX).txt")]
    if withPdf { files.append(("guidePdf", "\(name)\(GUIDE_SUFFIX).pdf")) }
    if withCode {
        files.append(("codeDocx", "\(name)\(CODE_SUFFIX).docx"))
        if withPdf { files.append(("codePdf", "\(name)\(CODE_SUFFIX).pdf")) }
    }
    return files
}

struct DocxInspection {
    let xml: String
    let headerXml: String
    let mediaCount: Int
}

func inspectDocx(_ file: String) throws -> DocxInspection {
    let zip = try ZipReader(try FS.read(file))
    var xml: [String] = []
    var header: [String] = []
    for entry in zip.entries where entry.name.hasPrefix("word/") && entry.name.hasSuffix(".xml") {
        let text = String(decoding: try zip.read(entry), as: UTF8.self)
        xml.append(text)
        if entry.name.hasPrefix("word/header") { header.append(text) }
    }
    let mediaCount = zip.entries.filter { $0.name.hasPrefix("word/media/") && !$0.isDirectory }.count
    return DocxInspection(xml: xml.joined(separator: "\n"), headerXml: header.joined(separator: "\n"), mediaCount: mediaCount)
}

/// 交付校验（在 staging 里跑，通过后才替换正式交付包）。
public func validateDelivery(projectDir: String, bundleDir: String, softwareName: String, content: JSON, withCode: Bool, withPdf: Bool, extraBrandTokens: [String] = [], floor: Int = 300) -> (errors: [String], warnings: [String]) {
    var errors: [String] = []
    var warnings: [String] = []
    let screens = content["screens"].items

    // 交付包文件：必须恰好是这几个
    let expected = expectedBundleFiles(softwareName, withCode: withCode, withPdf: withPdf)
    let expectedFile = Dictionary(uniqueKeysWithValues: expected.map { ($0.role, $0.file) })
    var actual: [String] = []
    if let names = FS.list(bundleDir) {
        actual = names.filter { !$0.hasPrefix(".") }
    } else {
        errors.append("交付文件夹不存在")
    }
    let jsSort: (String, String) -> Bool = { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    let expectedNames = expected.map(\.file).sorted(by: jsSort)
    actual.sort(by: jsSort)
    if actual != expectedNames {
        errors.append("交付文件夹应恰好包含：\(expectedNames.joined(separator: "、"))；实际：\(actual.isEmpty ? "（空）" : actual.joined(separator: "、"))")
    }
    for name in expectedNames {
        if let size = FS.size(Path.join(bundleDir, name)) {
            if size == 0 { errors.append("\(name) 是空文件") }
        } else {
            errors.append("缺少 \(name)")
        }
    }

    // 截图：数量、能解码、不是空白、回执哈希一致
    let review = content["screenshotReview"]?["reviewedScreens"].items ?? []
    if content["screenshotReview"]?["status"]?.string != "passed" || review.count != screens.count {
        errors.append("截图审查回执缺失或不完整")
    }
    for (index, screen) in screens.enumerated() {
        let id = screenId(index)
        let imagePath = Path.join(projectDir, screen["image"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "screens/\(id).png")
        guard let data = try? FS.read(imagePath) else {
            errors.append("缺少截图 \(id)")
            continue
        }
        do {
            if try inspectPng(data).blank == true { errors.append("\(id) 是空白图") }
        } catch {
            errors.append("\(id) 无法解码：\(messageOf(error))")
        }
        let receipt = review.first { $0["screenId"]?.string == id }
        if receipt?["sha256"]?.string != sha256Hex(data) { errors.append("\(id) 的审查回执和当前截图不一致，需要重新验收") }
    }

    // 文案
    let tokens = forbiddenBrandTokens(softwareName, extraBrandTokens)
    if hasFigureReference(content["cover"]?["overview"]?.string) { errors.append("封面介绍里出现了「图N」") }
    for (index, screen) in screens.enumerated() {
        let n = index + 1
        if !screen["caption"].text.hasPrefix("图\(n)") { errors.append("第 \(n) 屏图注必须以「图\(n)」开头") }
        let length = textLength(screen["text"].text)
        if length < floor { errors.append("第 \(n) 屏说明只有 \(length) 个字符，低于 \(floor)") }
        if hasFigureReference(screen["text"]?.string) { errors.append("第 \(n) 屏说明里出现了「图N」") }
    }
    let captionHits = findBrandHits([jsJoin(screens.map { $0["title"] ?? .null }, "\n")], tokens.filter { $0 != softwareName })
    if !captionHits.isEmpty { warnings.append("界面标题里含有软件名片段：\(captionHits.joined(separator: "、"))") }

    // 指南 Word
    if let guide = expectedFile["guideDocx"] {
        do {
            let docx = try inspectDocx(Path.join(bundleDir, guide))
            if !docx.xml.contains(xmlText(softwareName)) { errors.append("指南 Word 里没有完整软件名") }
            if !docx.headerXml.contains(xmlText(softwareName)) { errors.append("指南 Word 页眉里没有完整软件名") }
            if docx.mediaCount != screens.count { errors.append("指南 Word 嵌入了 \(docx.mediaCount) 张图，应为 \(screens.count) 张") }
            if !screens.isEmpty {
                for n in 1...screens.count {
                    let count = Rx.count("图\(n)(?![0-9])[^<]{0,40}", docx.xml)
                    if count != 1 { errors.append("指南 Word 里「图\(n)」出现了 \(count) 次，应恰好 1 次") }
                }
            }
        } catch {
            errors.append("指南 Word 无法读取：\(messageOf(error))")
        }
    }

    // 代码 Word
    if let code = expectedFile["codeDocx"] {
        do {
            let docx = try inspectDocx(Path.join(bundleDir, code))
            if !docx.xml.contains(xmlText(softwareName)) { errors.append("代码 Word 里没有完整软件名") }
            // 旧模板约定代码页眉不带页码域；Word 代码模板模式由软件自己加右上角页码（带书签标记），只允许这一种
            if Rx.test("PAGE|instrText|fldChar", CodeWordTemplate.removePageNumber(docx.headerXml)) { errors.append("代码 Word 页眉不应包含页码域（模板约定）") }
        } catch {
            errors.append("代码 Word 无法读取：\(messageOf(error))")
        }
    }

    // TXT
    if let txtFile = expectedFile["guideTxt"], let txt = FS.readTextIfExists(Path.join(bundleDir, txtFile)) {
        if !txt.contains("【软件的主要功能】") { errors.append("TXT 缺少【软件的主要功能】") }
        let overview = content["cover"]?["overview"].text ?? ""
        let head = (Rx.split(#"\n+"#, overview.jsTrimmed).first ?? "").jsSlice(0, 20)
        if !head.isEmpty, !txt.contains(head) { errors.append("TXT 里的主要功能和封面介绍不一致") }
        if Rx.test(#"【源程序量】\r?\n"#, txt), withCode { errors.append("TXT 源程序量为空") }
    }

    // PDF：有效文件；指南页数检查「图注掉页」问题
    for role in ["guidePdf", "codePdf"] {
        guard let file = expectedFile[role], let data = try? FS.read(Path.join(bundleDir, file)) else { continue }
        if String(decoding: data.prefix(5), as: UTF8.self) != "%PDF-" { errors.append("\(file) 不是有效的 PDF") }
    }
    if let guidePdf = expectedFile["guidePdf"], let pages = countPdfPages(Path.join(bundleDir, guidePdf)) {
        let sections = content["design"]?["sections"].items ?? []
        let designPages = sections.isEmpty ? 0 : 1
        if pages > screens.count + 1 + designPages + (designPages > 0 ? sections.count : 0) {
            warnings.append("指南 PDF 有 \(pages) 页，比预期多，可能有截图块跨页，请打开 PDF 检查")
        }
    }
    return (errors, warnings)
}
