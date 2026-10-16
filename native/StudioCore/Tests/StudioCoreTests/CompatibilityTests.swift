import Foundation
import Testing
@testable import StudioCore

/// 和定档的 Electron 版逐项比对：Fixtures/electron.json 由 native/scripts/make-fixtures.mjs 用 Electron 版代码生成。
let fixtures: JSON = {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/electron.json").path
    return try! JSON.parse(FS.readText(file))
}()

func strings(_ value: JSON?) -> [String] { value?.array?.map(\.jsString) ?? [] }

@Suite("和 Electron 版一致")
struct CompatibilityTests {
    @Test("JSON 序列化、键排序和哈希")
    func json() throws {
        for item in fixtures["json"].items {
            let value = try JSON.parse(item["input"]!.string!)
            #expect(value.serialized() == item["stringify"]!.string!)
            #expect(value.serialized(pretty: true) == item["pretty"]!.string!)
            #expect(value.stableStringify() == item["stable"]!.string!)
            #expect(hashObject(value) == item["hash"]!.string!)
        }
        for item in fixtures["numbers"].items {
            #expect(JSON.formatNumber(item["value"]!.number!) == item["text"]!.string!, "\(item)")
        }
        for item in fixtures["percentile"].items {
            let result = percentile(item["values"].items.compactMap(\.number), item["p"]!.number!)
            #expect(result == item["result"]?.number)
        }
    }

    @Test("品牌禁词")
    func brand() {
        for item in fixtures["brand"].items {
            let name = item["name"]!.string!
            #expect(forbiddenBrandTokens(name, ["额外词", " x ", "品牌"]) == strings(item["tokens"]))
            #expect(baseSoftwareName(name) == item["base"]!.string!)
            #expect(findBrandHits(["首页 测试记账本v1.0 标题", "ＡＩ口播", "UU游戏 辅助器"], forbiddenBrandTokens(name)) == strings(item["hits"]))
            #expect(textLength(" \(name)😀 ") == item["len"]!.int!)
        }
    }

    @Test("生图提示词")
    func prompts() {
        for item in fixtures["prompts"].items {
            let output = composeScreenPrompt(softwareName: item["softwareName"]!.string!, platform: item["platform"]!.string!, targetSize: item["targetSize"]!.string!, ui: item["ui"], screen: item["screen"]!)
            #expect(output == item["output"]!.string!)
        }
        for item in fixtures["ensureBan"].items {
            #expect(ensureBrandBan(item["input"]!.string!) == item["output"]!.string!)
        }
        for item in fixtures["normalizedUi"].items {
            #expect(normalizedUi(item["plan"]).stableStringify() == item["output"]!.stableStringify())
        }
        for item in fixtures["planRowHash"].items {
            #expect(planRowHash(item["screen"]!, item["ui"]!, item["platform"]!.string!, item["target"]!.string!) == item["hash"]!.string!)
        }
        for item in fixtures["promptIdentity"].items {
            #expect(promptIdentity(item["prompt"]!.string!, item["name"]!.string!) == item["hash"]!.string!)
        }
    }

    @Test("尺寸换算")
    func sizes() {
        let s = fixtures["sizes"]!
        for item in s["nearest"].items {
            let target = PixelSize(width: item["target"]!["width"]!.number!, height: item["target"]!["height"]!.number!)
            #expect(nearestRatio(target, strings(item["ratios"])) == item["result"]?.string)
        }
        for item in s["allowedRatios"].items { #expect(parseAllowedRatios(item["message"]!.string!) == strings(item["result"])) }
        for item in s["unsupported"].items { #expect(looksLikeUnsupportedPixelSize(item["message"]!.string!) == item["result"]!.bool!) }
        for item in s["pixelSizes"].items { #expect(parseAllowedPixelSizes(item["message"]!.string!) == strings(item["result"])) }
        for item in s["resolve"].items {
            var provider = ImageProvider(id: "p", name: "p")
            provider.sizeMode = item["provider"]!["sizeMode"]!.string!
            provider.pixelSize = item["provider"]?["pixelSize"]?.string ?? ""
            provider.ratios = strings(item["provider"]?["ratios"])
            let spec = resolveRequestSize(provider, "864x1824")
            #expect(spec.mode == item["result"]!["mode"]!.string!)
            #expect(spec.size == item["result"]!["size"]!.string!)
        }
        for item in s["fallback"].items {
            var provider = ImageProvider(id: "p", name: "p")
            provider.ratios = strings(item["provider"]?["ratios"])
            let error = ProviderError(item["message"]!.string!, kind: "size", allowedRatios: strings(item["allowedRatios"]))
            let result = sizeFallback(error, provider, "864x1824", item["current"]!.string!)
            if let expected = item["result"], !expected.isNull {
                #expect(result?.spec.mode == expected["spec"]!["mode"]!.string!)
                #expect(result?.spec.size == expected["spec"]!["size"]!.string!)
                #expect(result?.sizeMode == expected["patch"]!["sizeMode"]!.string!)
                #expect(result?.pixelSize == expected["patch"]?["pixelSize"]?.string)
                #expect(result?.ratios ?? [] == strings(expected["patch"]?["ratios"]))
            } else {
                #expect(result == nil)
            }
        }
    }

    @Test("接口适配：JSON 路径、模板、冷却时间、报错分类、去密钥")
    func adapter() {
        let sample = fixtures["sample"]!
        for item in fixtures["readPath"].items {
            let result = readPath(sample, item["expr"]!.string!)
            if item["result"]?.string == "__undefined__" {
                #expect(result == nil, "\(item["expr"]!)")
            } else {
                #expect(result == item["result"], "\(item["expr"]!)")
            }
        }
        let template = fixtures["template"]!
        for item in fixtures["fillTemplate"].items {
            var context: [String: JSON?] = [:]
            for (key, value) in item["context"].fields { context[key] = value }
            #expect(fillTemplate(template, context)?.stableStringify() == item["result"]!.stableStringify())
        }
        for item in fixtures["retryAfter"].items {
            #expect(parseRetryAfter(nil, item["message"]!.string!) == item["result"]?.number)
        }
        for item in fixtures["classify"].items {
            let result = classifyHttpError(item["status"]!.int!, item["message"]!.string!)
            #expect(result.kind == item["result"]!["kind"]!.string!, "\(item)")
            #expect(result.retryAfterSec == item["result"]?["retryAfterSec"]?.number)
            if let ratios = item["result"]?["allowedRatios"] { #expect(result.allowedRatios == strings(ratios)) }
        }
        for item in fixtures["redact"].items {
            #expect(redact(item["text"]!.string!, strings(item["secrets"])) == item["result"]!.string!)
        }
    }

    @Test("大模型输出解析")
    func extract() throws {
        for item in fixtures["extractJson"].items {
            if let error = item["error"]?.string {
                #expect(throws: (any Error).self) { try extractJson(item["text"]!.string!) }
                _ = error
            } else {
                #expect(try extractJson(item["text"]!.string!) == item["result"])
            }
        }
    }

    @Test("各步骤提示词和程序复核")
    func steps() {
        let s = fixtures["steps"]!
        for item in s["planUser"].items {
            let input = item["input"]!
            #expect(planUserPrompt(softwareName: input["softwareName"]!.string!, screenCount: input["screenCount"]?.int, emphasis: input["emphasis"].text, notes: input["notes"].text, platform: input["platform"]!.string!) == item["output"]!.string!)
        }
        for item in s["planCheck"].items {
            #expect(planCheck(item["plan"]!, softwareName: item["softwareName"]!.string!, screenCount: item["screenCount"]?.int) == strings(item["output"]))
        }
        for item in s["gateUser"].items {
            let input = item["input"]!
            let screen = input["screen"].flatMap { $0.isNull ? Optional<JSON>.none : $0 }
            #expect(gateUserPrompt(softwareName: input["softwareName"]!.string!, tokens: strings(input["tokens"]), screen: screen) == item["output"]!.string!)
        }
        for item in s["judgeGate"].items {
            let verdict = judgeGate(item["result"]!, strings(item["tokens"]))
            #expect(verdict.passed == item["output"]!["passed"]!.bool!)
            #expect(verdict.reasons == strings(item["output"]!["reasons"]))
            #expect(verdict.hits == strings(item["output"]!["hits"]))
        }
        for item in s["contentUser"].items {
            let input = item["input"]!
            var inventories: [String: String] = [:]
            for (key, value) in input["inventories"].fields { inventories[key] = value.string }
            var instructions: [String: String] = [:]
            for (key, value) in input["instructions"].fields { instructions[key] = value.string }
            var current: [String: String] = [:]
            for (key, value) in input["currentTexts"].fields { current[key] = value.string }
            let output = contentUserPrompt(softwareName: input["softwareName"]!.string!, profile: input["profile"].flatMap { $0.isNull ? Optional<JSON>.none : $0 }, screens: input["screens"].items, inventories: inventories, needOverview: input["needOverview"]!.bool!, existingOverview: input["existingOverview"].text, floor: input["floor"]!.int!, instructions: instructions, currentTexts: current)
            #expect(output == item["output"]!.string!)
        }
        for item in s["contentCheck"].items {
            #expect(contentCheck(item["result"]!, screens: item["screens"].items, needOverview: item["needOverview"]!.bool!, floor: item["floor"]!.int!) == strings(item["output"]))
        }
        for item in s["designUser"].items {
            let input = item["input"]!
            let output = designUserPrompt(softwareName: input["softwareName"]!.string!, profile: input["profile"].flatMap { $0.isNull ? Optional<JSON>.none : $0 }, features: input["features"].items, screens: input["screens"].items, instruction: input["instruction"]?.string, current: input["current"].text)
            #expect(output == item["output"]!.string!)
        }
        for item in s["designCheck"].items { #expect(designCheck(item["result"]!) == strings(item["output"])) }
        for item in s["feedbackUser"].items {
            let input = item["input"]!
            let screens = input["screens"].items.map { FeedbackScreen(figure: $0["figure"]!.string!, id: $0["id"]!.string!, title: $0["title"]!.string!, inventory: $0["inventory"].text, visual: $0["visual"].text, text: $0["text"].text) }
            #expect(feedbackUserPrompt(softwareName: input["softwareName"]!.string!, screens: screens, overview: input["overview"].text, hasDesign: input["hasDesign"]!.bool!, items: input["items"].items.map { $0["text"]!.string! }) == item["output"]!.string!)
        }
        for item in s["feedbackCheck"].items {
            #expect(feedbackCheck(item["result"]!, screenIds: strings(item["screenIds"]), itemCount: item["itemCount"]!.int!) == strings(item["output"]))
        }
        for item in s["promptEdit"].items {
            #expect(promptEditUserPrompt(prompt: item["input"]!["prompt"]!.string!, instruction: item["input"]!["instruction"]!.string!) == item["output"]!.string!)
        }
    }

    @Test("JSON Schema 校验的报错和 ajv 一致")
    func schema() {
        for item in fixtures["schema"].items {
            let errors = SchemaValidator.validate(item["value"]!, item["schema"]!)
            #expect(errors.isEmpty == item["ok"]!.bool!)
            #expect(SchemaValidator.describe(errors) == item["errors"]!.string!)
        }
    }

    @Test("小工具：用时、版本号、批量列表、代码来源锁定、项目编号")
    func helpers() throws {
        for item in fixtures["formatDuration"].items { #expect(formatDuration(item["ms"]!.number!) == item["text"]!.string!) }
        for item in fixtures["detectVersion"].items { #expect(detectVersion(item["name"]!.string!) == item["result"]?.string) }
        for item in fixtures["batchList"].items {
            let rows = parseBatchList(item["text"]!.string!)
            let expected = item["rows"].items
            #expect(rows.count == expected.count)
            for (row, want) in zip(rows, expected) {
                #expect(row.softwareName == want["softwareName"]!.string!)
                #expect(row.screenCount == want["screenCount"]?.int)
                #expect(row.emphasis == want["emphasis"]!.string!)
                #expect(row.notes == want["notes"]!.string!)
            }
        }
        for item in fixtures["projectKey"].items { #expect(projectKey(item["dir"]!.string!) == item["key"]!.string!) }
        for item in fixtures["codeSourceFor"].items {
            let settings = try item["settings"]!.merging(.obj(["codeSource": item["settings"]!["codeSource"]])).decode(Settings.self)
            let result = codeSourceFor(item["state"]!, settings)
            #expect(result.locked == item["result"]!["locked"]!.bool!)
            #expect((result.source ?? .null).stableStringify() == item["result"]!["source"]!.stableStringify())
        }
        let state = newState(.obj(["softwareName": "测试 V1.0", "screenCount": 5, "emphasis": "e", "wantDesign": 1, "extraBrandTokens": ["x"], "createdAt": "2026-01-01"]))
        #expect(state.serialized() == fixtures["newState"]!.serialized())
        let sorted = strings(fixtures["localeSort"]?["input"]).sorted(by: localeCompareEn)
        #expect(sorted == strings(fixtures["localeSort"]?["sorted"]))
        for item in fixtures["languageLabel"].items { #expect(languageLabelFor(strings(item["extensions"])) == item["label"]!.string!) }
        for item in fixtures["bundleFiles"].items {
            let files = expectedBundleFiles("名 V1.0", withCode: item["withCode"]!.bool!, withPdf: item["withPdf"]!.bool!)
            #expect(files.map(\.role) == item["files"].fields.keys)
            #expect(files.map(\.file) == item["files"].fields.values.map(\.jsString))
        }
    }

    @Test("设置：深合并、空值换回默认")
    func settings() throws {
        let settings = try fixtures["settings"]!["stored"]!.decode(Settings.self)
        let merged = fixtures["settings"]!["merged"]!
        let ours = try JSON.encode(settings)
        for key in ["image", "pipeline", "txtFields", "codeDefaults", "pdf", "export"] {
            #expect(ours[key]!.stableStringify() == merged[key]!.stableStringify(), "\(key)")
        }
        // 旧版本把代码文件类型放在 codeDefaults 里（Electron 版在 settingsStore.load 里迁移）
        #expect(settings.codeSource.extensions == [".kt"])
    }

    @Test("PDF 字体：替换表、方案、核对")
    func fonts() {
        for item in fixtures["fontRegistry"].items {
            let pairs = item["pairs"].items.map { FontPair(from: $0["from"]!.string!, to: $0["to"]!.string!) }
            #expect(fontRegistryXml(pairs) == item["xml"]!.string!)
        }
        for item in fixtures["fontPlan"].items {
            var pdf = PdfSettings()
            pdf.guide = item["pdf"]!["guide"]!.string!
            pdf.code = item["pdf"]!["code"]!.string!
            let plan = resolveFontPlan(pdf, families: Set(strings(item["families"])))
            for kind in DOC_FONT_ORDER {
                let want = item["plan"]![kind]!
                #expect(plan[kind]!.mode == want["mode"]!.string!)
                #expect(plan[kind]!.label == want["label"]!.string!)
                #expect(plan[kind]!.substitute == want["substitute"]?.string)
            }
        }
        for item in fixtures["fontAttempts"].items {
            let entry = item["entry"]!
            let attempts = substitutionAttempts(item["kind"]!.string!, FontPlanEntry(kind: item["kind"]!.string!, mode: entry["mode"]!.string!, substitute: entry["substitute"]?.string, label: ""))
            let expected = item["attempts"].items
            #expect(attempts.count == expected.count)
            for (attempt, want) in zip(attempts, expected) {
                #expect(attempt.name == want["name"]!.string!)
                #expect(attempt.expect == want["expect"]!.string!)
                #expect(attempt.alsoAllowed == want["alsoAllowed"]?.string)
                #expect(attempt.pairs.map { "\($0.from)>\($0.to)" } == want["pairs"].items.map { "\($0["from"]!.string!)>\($0["to"]!.string!)" })
            }
        }
        for item in fixtures["judgeFonts"].items {
            let key = item["key"]!.string!
            let kind = key == "courier" || key == "stsong" ? "code" : "guide"
            let attempt = substitutionAttempts(kind, FontPlanEntry(kind: kind, mode: "substitute", substitute: key, label: ""))[0]
            let verdict = judgePdfFonts(strings(item["fonts"]), attempt)
            #expect(verdict.ok == item["result"]!["ok"]!.bool!)
            #expect(verdict.unexpected == strings(item["result"]!["unexpected"]))
        }
    }

    @Test("代码来源：跳过二进制和排除目录，去掉 BOM，统一换行，按路径排序")
    func codeSource() throws {
        let root = try FS.makeTempDirectory(prefix: "code-")
        defer { FS.remove(root) }
        let code = fixtures["code"]!
        for (relative, text) in code["files"].fields { try FS.write(Path.join(root, relative), text.string!) }
        try FS.write(Path.join(root, code["binary"]!.string!), Data([1, 0, 2]))
        let result = try collectCodeSource(path: root, extensions: ["java"], excludeDirs: ["build"])
        let want = code["result"]!
        #expect(result.files == strings(want["files"]))
        #expect(result.lineCount == want["lineCount"]!.int!)
        #expect(result.nonEmptyLines == want["nonEmptyLines"]!.int!)
        #expect(result.body == want["body"]!.string!)
        #expect(result.sha256 == want["sha256"]!.string!)
        #expect(result.estimatedPages == want["estimatedPages"]!.int!)
        #expect(result.warnings.map { $0.replacingOccurrences(of: root, with: "<root>") } == strings(want["warnings"]))
    }

    @Test("历史格式的规划文件")
    func readPlanLegacy() throws {
        let dir = try FS.makeTempDirectory(prefix: "plan-")
        defer { FS.remove(dir) }
        try FS.write(Path.join(dir, "screen-plan.json"), #"{"flow":["首页",{"screenId":"screen-02","name":"列表"},{"purpose":"设置"}],"extra":1}"#)
        try FS.write(Path.join(dir, "ui-contract.json"), ##"{"visual":{"palette":{"primary":"#000"}}}"##)
        let plan = try readPlan(dir)
        #expect(plan?.stableStringify() == fixtures["readPlan"]!.stableStringify())
    }

    @Test("指南图片改为安全尺寸，其余Word XML保持一致，TXT省略运行环境")
    func docx() throws {
        let doc = fixtures["docx"]!
        let dir = try FS.makeTempDirectory(prefix: "docx-")
        defer { FS.remove(dir) }
        for (index, png) in doc["pngs"].items.enumerated() {
            try FS.write(Path.join(dir, "screens", "screen-0\(index + 1).png"), Data(base64Encoded: png.string!)!)
        }
        let software = doc["software"]!.string!
        let region = try createGuideDocx(project: dir, software: software, content: doc["content"]!)
        #expect(region.serialized() == doc["region"]!.serialized())
        try createCodeDocx(project: dir, software: software, body: doc["codeBody"]!.string!)
        try createGuideTxt(project: dir, software: software, overview: doc["content"]!["cover"]!["overview"]!.string!, fields: ["devOs": "macOS 26", "language": "Swift", "languageOverride": "true"], sourceLines: 123)
        #expect(try FS.readText(Path.join(dir, software, "\(software)指南.txt")) == doc["txt"]!.string!.components(separatedBy: "\r\n").filter { line in
            !["【运行的硬件环境】", "【该软件的运行平台/操作系统】", "【软件运行支撑环境/支持软件】"].contains(where: line.hasPrefix)
        }.joined(separator: "\r\n"))
        for (kind, file) in [("guide", "\(software)指南.docx"), ("code", "\(software)指南_代码-（JAVA）.docx")] {
            let zip = try ZipReader(try FS.read(Path.join(dir, software, file)))
            let expected = doc[kind]!
            #expect(zip.entries.map(\.name) == strings(expected["names"]), "\(kind) 条目顺序")
            for (name, xml) in expected.fields where name != "names" {
                let ours = String(decoding: try zip.read(name) ?? Data(), as: UTF8.self)
                if kind == "guide" && name == "word/document.xml" {
                    // 图片几何由 GuideLayoutTests 验证；其他文字、样式和部件继续逐字对照。
                    func withoutLayout(_ text: String) -> String {
                        let stripped = Rx.replace(#"<(wp:extent|a:ext) cx="[0-9]+" cy="[0-9]+"/>"#, in: text, with: "<image-extent/>")
                        return stripped.replacingAll(#"<w:tblLayout w:type="fixed"/>"#, with: "")
                    }
                    #expect(withoutLayout(ours) == withoutLayout(xml.string!))
                } else if kind == "code" && name == "word/document.xml" {
                    // 代码里的控制字符：Electron 版原样写进 XML（Word 打不开），这里去掉了
                    #expect(ours == xml.string!.replacingOccurrences(of: "\u{0001}", with: ""), "\(kind) \(name)")
                } else {
                    #expect(ours == xml.string!, "\(kind) \(name)")
                }
            }
        }
    }
}
