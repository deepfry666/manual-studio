import Foundation

public func assertSafeSoftwareName(_ name: String) throws {
    if name.jsTrimmed.isEmpty { throw StudioError("软件名为空") }
    if Rx.test("[/\\\\:\u{0000}]", name) || name == "." || name == ".." || name.hasPrefix(".") {
        throw StudioError("软件名不能包含 / \\ : 或以点开头：\(name)")
    }
}

/// 字体核对结果 → 给人看的提醒（核对通过返回 nil）。
public func pdfFontWarning(_ kind: String, _ result: PdfFontResult?) -> String? {
    guard let result, !result.ok else { return nil }
    let doc = DOC_FONTS[kind]!
    return "\(doc.label) PDF 字体不对：应为「\(result.intended)」，实际用了 \(result.fonts.isEmpty ? "（未识别）" : result.fonts.joined(separator: "、"))"
}

func summarizeFonts(_ fonts: [(String, PdfFontResult)]) -> JSON {
    var object = JSONObject()
    for (kind, result) in fonts { object[kind] = result.summary }
    return .object(object)
}

func buildManifest(softwareName: String, content: JSON, withPdf: Bool, withCode: Bool, code: CodeCollection?, codeSource: JSON?, provenance: JSON?) -> JSON {
    var artifacts = JSONObject()
    for (role, file) in expectedBundleFiles(softwareName, withCode: withCode, withPdf: withPdf) { artifacts[role] = .string("\(softwareName)/\(file)") }
    var manifest = JSONObject()
    manifest["softwareName"] = .string(softwareName)
    manifest["versionPolicy"] = content["versionPolicy"].or("in-name")
    manifest["screenshotCount"] = .number(Double(content["screens"].items.count))
    manifest["imageRoute"] = content["imageRoute"].or("image-gateway")
    manifest["pdfMode"] = .string(withPdf ? "complete" : "complete-no-pdf")
    manifest["codeDocument"] = .string(withCode ? "from-code-source" : "not-generated")
    manifest["createdAt"] = content["createdAt"].or(.string(isoNow().jsSlice(0, 10)))
    manifest["builtAt"] = .string(isoNow())
    manifest["builtBy"] = "软件指南生成器"
    manifest["artifacts"] = .object(artifacts)
    if let reason = content["screenCountReason"].truthyValue { manifest["screenCountReason"] = reason }
    if let tier = content["featureTier"].truthyValue { manifest["featureTier"] = tier }
    if let review = content["screenshotReview"].truthyValue { manifest["screenshotReview"] = review }
    if withCode, let code {
        manifest["codeSource"] = .obj(["path": codeSource?["path"], "extensions": JSON(code.extensions), "fileCount": .number(Double(code.fileCount)), "lineCount": .number(Double(code.lineCount))])
    }
    if let provenance { manifest["provenance"] = provenance }
    return .object(manifest)
}

func buildRegionIndex(softwareName: String, content: JSON, regionFill: JSON, withPdf: Bool, withCode: Bool, code: CodeCollection?) -> JSON {
    let date = content["compileDate"].or(content["createdAt"].or("")).jsString
    var regions = JSONObject()
    regions["document.meta"] = .obj(["label": "文档元信息", "softwareName": .string(softwareName), "version": .string(content["versionPolicy"]?.string == "none" ? "" : softwareName), "compileDate": .string(date), "summary": "软件名、版本、编制日期与输出路径"])
    regions["header.default"] = .obj(["label": "页眉", "summary": "左侧软件名，右侧页码域"])
    regions["cover.title"] = .obj(["label": "封面标题", "summary": .string("\(softwareName) 用户手册")])
    regions["cover.metadata"] = .obj(["label": "封面元信息", "summary": .string("编制时间：\(date)")])
    regions["cover.overview"] = .obj(["label": "封面软件介绍", "summary": .string(templateText(content["cover"]?["overview"]).jsSlice(0, 40))])
    for (key, value) in regionFill.fields { regions[key] = value }
    regions["artifact.txt.main-function"] = .obj(["label": "TXT 主要功能段", "summary": "取自 cover.overview，插入【软件的主要功能】之后"])
    if withCode, let code { regions["artifact.docx.code"] = .obj(["label": "代码 Word", "summary": .string("代码来源 \(code.fileCount) 个文件，共 \(code.lineCount) 行")]) }
    if withPdf {
        regions["artifact.pdf.guide"] = .obj(["label": "指南 PDF", "summary": "由指南 Word 导出"])
        if withCode { regions["artifact.pdf.code"] = .obj(["label": "代码 PDF", "summary": "由代码 Word 导出"]) }
    }
    return .obj(["softwareName": .string(softwareName), "regions": .object(regions)])
}

func pruneBundleArchives(_ archiveRoot: String, _ softwareName: String, keep: Int = 3) {
    guard let entries = FS.list(archiveRoot) else { return }
    let bundles = entries.filter { $0.hasPrefix("\(softwareName)-交付-") }.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.reversed()
    for name in bundles.dropFirst(keep) { FS.remove(Path.join(archiveRoot, name)) }
}

public struct BuildInput: Sendable {
    public var projectDir: String
    public var softwareName: String
    public var content: JSON
    public var codeSource: JSON?
    public var txtFields: [String: String]
    public var languageOverride: Bool
    public var excludeDirs: [String]
    public var floor: Int
    public var extraBrandTokens: [String]
    public var stagingRoot: String
    public var provenance: JSON?
    public var fontPlan: [String: FontPlanEntry]?
}

/// S8 构建：先在 staging 生成并校验，全部通过后才替换正式交付包（旧的先归档）。
public func buildBundle(_ input: BuildInput, onLog: @Sendable (String) async -> Void) async throws -> JSON {
    let softwareName = input.softwareName
    try assertSafeSoftwareName(softwareName)
    let paths = projectPaths(input.projectDir)
    let stamp = timestampSlug()
    let staging = Path.join(input.stagingRoot, "\(Path.basename(input.projectDir))-\(stamp)")
    let stagingBundle = Path.join(staging, softwareName)
    try FS.mkdirp(Path.join(staging, "tmp"))
    try FS.mkdirp(Path.join(staging, "screens"))
    for screen in input.content["screens"].items {
        let image = screen["image"]?.string ?? ""
        try FS.copy(Path.join(input.projectDir, image), Path.join(staging, image))
    }
    try FS.writeJSONAtomic(Path.join(staging, "content.json"), input.content)

    await onLog("生成指南 Word")
    let regionFill = try createGuideDocx(project: staging, software: softwareName, content: input.content)

    let soffice = await findLibreOffice()
    let withPdf = soffice != nil
    var pdfFonts: [(String, PdfFontResult)] = []
    if withPdf {
        await onLog("导出指南 PDF（字体：\(input.fontPlan?["guide"]?.label ?? "微软雅黑")）")
        pdfFonts.append(("guide", try await convertToPdfChecked(Path.join(stagingBundle, "\(softwareName)指南.docx"), outDir: stagingBundle, kind: "guide", fontPlan: input.fontPlan)))
    } else {
        await onLog("没有找到 LibreOffice，本次不生成 PDF")
    }

    var code: CodeCollection?
    if let source = input.codeSource, let sourcePath = source["path"]?.string, !sourcePath.isEmpty {
        await onLog("读取代码来源")
        let collected = try collectCodeSource(path: sourcePath, extensions: source["extensions"]?.stringArray ?? [], excludeDirs: input.excludeDirs)
        code = collected
        try FS.write(Path.join(staging, "tmp", "code-body.txt"), collected.body)
        await onLog("生成代码 Word（\(collected.fileCount) 个文件，\(collected.lineCount) 行）")
        try createCodeDocx(project: staging, software: softwareName, body: collected.body)
        if withPdf {
            await onLog("导出代码 PDF（字体：\(input.fontPlan?["code"]?.label ?? "新宋体")）")
            pdfFonts.append(("code", try await convertToPdfChecked(Path.join(stagingBundle, "\(softwareName)指南_代码-（JAVA）.docx"), outDir: stagingBundle, kind: "code", fontPlan: input.fontPlan)))
        }
    }

    await onLog("生成 TXT")
    var fields = input.txtFields
    if let code, !input.languageOverride {
        let label = languageLabelFor(code.extensions)
        if !label.isEmpty { fields["language"] = label == "Java" ? "JAVA" : label }
    }
    try createGuideTxt(project: staging, software: softwareName, overview: input.content["cover"]?["overview"]?.jsString ?? "", fields: fields, sourceLines: code?.lineCount ?? 0)

    await onLog("校验交付包")
    let withCode = code != nil
    var (errors, warnings) = validateDelivery(projectDir: staging, bundleDir: stagingBundle, softwareName: softwareName, content: input.content, withCode: withCode, withPdf: withPdf, extraBrandTokens: input.extraBrandTokens, floor: input.floor)
    warnings.append(contentsOf: code?.warnings ?? [])
    for (kind, result) in pdfFonts { if let warning = pdfFontWarning(kind, result) { warnings.append(warning) } }
    if !errors.isEmpty {
        throw StudioError("交付校验没有通过（正式交付包未改动，诊断文件在 \(staging)）：\n- \(errors.joined(separator: "\n- "))")
    }

    var manifest = buildManifest(softwareName: softwareName, content: input.content, withPdf: withPdf, withCode: withCode, code: code, codeSource: input.codeSource, provenance: input.provenance)
    if withPdf { manifest["pdfFonts"] = summarizeFonts(pdfFonts) }
    let regionIndex = buildRegionIndex(softwareName: softwareName, content: input.content, regionFill: regionFill, withPdf: withPdf, withCode: withCode, code: code)

    await onLog("替换正式交付包")
    let finalBundle = paths.bundle(softwareName)
    if FS.exists(finalBundle) {
        try FS.mkdirp(paths.archive)
        try FS.move(finalBundle, Path.join(paths.archive, "\(softwareName)-交付-\(stamp)"))
        pruneBundleArchives(paths.archive, softwareName)
    }
    try FS.move(stagingBundle, finalBundle)
    try FS.writeJSONAtomic(paths.content, input.content)
    try FS.writeJSONAtomic(paths.manifest, manifest)
    try FS.writeJSONAtomic(paths.regionIndex, regionIndex)
    FS.remove(staging)

    let pdfPages = withPdf ? countPdfPages(Path.join(finalBundle, "\(softwareName)指南.pdf")) : nil
    return .obj([
        "bundleDir": .string(finalBundle),
        "files": JSON(expectedBundleFiles(softwareName, withCode: withCode, withPdf: withPdf).map(\.file)),
        "withPdf": .bool(withPdf),
        "withCode": .bool(withCode),
        "code": code.map { .obj(["fileCount": .number(Double($0.fileCount)), "lineCount": .number(Double($0.lineCount)), "estimatedPages": .number(Double($0.estimatedPages))]) } ?? .null,
        "pdfPages": JSON.orNull(pdfPages),
        "pdfFonts": summarizeFonts(pdfFonts),
        "codeSha256": JSON.orNull(code?.sha256),
        "warnings": JSON(warnings),
    ])
}

/// 只重新导出交付包里的 PDF（修正字体用），Word 和 TXT 不动。
/// 新 PDF 先转到临时目录，核对后再替换；旧 PDF 移到项目的 archive 文件夹。
public func reexportBundlePdfs(projectDir: String, softwareName: String, stagingRoot: String, fontPlan: [String: FontPlanEntry], onLog: @Sendable (String) async -> Void) async throws -> JSON {
    let paths = projectPaths(projectDir)
    let bundle = paths.bundle(softwareName)
    guard FS.exists(bundle) else { throw StudioError("还没有交付包") }
    guard await findLibreOffice() != nil else { throw StudioError("没有找到 LibreOffice") }
    let docs = [("guide", "\(softwareName)指南.docx"), ("code", "\(softwareName)指南_代码-（JAVA）.docx")]
    let stamp = timestampSlug()
    let staging = Path.join(stagingRoot, "\(Path.basename(projectDir))-pdf-\(stamp)")
    try FS.mkdirp(staging)
    defer { FS.remove(staging) }
    var results: [(String, PdfFontResult)] = []
    var warnings: [String] = []
    for (kind, docx) in docs {
        let source = Path.join(bundle, docx)
        guard FS.exists(source) else { continue }
        await onLog("重新导出 \(Rx.replace("\\.docx$", in: docx, with: ".pdf"))")
        let result = try await convertToPdfChecked(source, outDir: staging, kind: kind, fontPlan: fontPlan)
        results.append((kind, result))
        if let warning = pdfFontWarning(kind, result) { warnings.append(warning) }
    }
    if results.isEmpty { throw StudioError("交付包里没有 Word 文档") }
    let archiveDir = Path.join(paths.archive, "\(softwareName)-PDF-\(stamp)")
    for (_, result) in results {
        let name = Path.basename(result.pdfPath)
        let target = Path.join(bundle, name)
        if FS.exists(target) {
            try FS.mkdirp(archiveDir)
            try FS.move(target, Path.join(archiveDir, name))
        }
        try FileManager.default.copyItem(atPath: result.pdfPath, toPath: target)
    }
    return .obj(["files": JSON(results.map { Path.basename($0.1.pdfPath) }), "pdfFonts": summarizeFonts(results), "warnings": JSON(warnings)])
}
