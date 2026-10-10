import Foundation
import CoreText

/// PDF 字体。模板（不改）里说明书用「微软雅黑」，代码文档用「新宋体」。
/// 这两个字体 macOS 没有自带，LibreOffice 找不到时会随便抓一个中文字体顶上（实测有圆体、娃娃体、魏碑……每次都不一样）。
/// 这里的做法：本机装了原版字体就用原版；没装就强制换成一个固定的系统字体，保证每次转出来一样，转完再核对 PDF 里实际用的字体。
public struct DocFont: Sendable {
    public let label: String
    public let original: String
    public let replace: [String]
    public let families: [String]
    public let expect: String
}

public let DOC_FONT_ORDER = ["guide", "code"]
public let DOC_FONTS: [String: DocFont] = [
    "guide": DocFont(label: "说明书", original: "微软雅黑", replace: ["Microsoft YaHei", "微软雅黑"], families: ["Microsoft YaHei", "微软雅黑"], expect: "^MicrosoftYaHei"),
    "code": DocFont(label: "代码文档", original: "新宋体", replace: ["新宋体", "NSimSun"], families: ["NSimSun", "新宋体"], expect: "^NSimSun$"),
]

/// names：LibreOffice 里能认出的名字（系统语言是中文时要用中文名），按顺序尝试。
public struct SubstituteFont: Sendable {
    public let label: String
    public let names: [String]
    public let expect: String
    public let alsoAllowed: String?
}

public let SUBSTITUTES: [String: SubstituteFont] = [
    "pingfang": SubstituteFont(label: "苹方（推荐）", names: ["苹方-简", "PingFang SC"], expect: "^PingFangSC-", alsoAllowed: nil),
    "heiti": SubstituteFont(label: "黑体-简", names: ["黑体-简", "Heiti SC"], expect: "^STHeitiSC-", alsoAllowed: nil),
    "stsong": SubstituteFont(label: "华文宋体（推荐，最接近新宋体）", names: ["华文宋体", "STSong"], expect: "^STSong$", alsoAllowed: nil),
    "songti": SubstituteFont(label: "宋体-简", names: ["宋体-简", "Songti SC"], expect: "^STSongti-SC-", alsoAllowed: nil),
    "courier": SubstituteFont(label: "Courier New（等宽，中文用苹方）", names: ["Courier New"], expect: "^CourierNew", alsoAllowed: "^PingFangSC-"),
]

public let DEFAULT_PDF_FONTS = ["guide": "pingfang", "code": "stsong"]
public let SUBSTITUTE_CHOICES = ["guide": ["pingfang", "heiti"], "code": ["stsong", "songti", "courier"]]

private let familiesCache = Locked<(at: Double, set: Set<String>)?>(nil)

/// 本机已安装的字体族名（英文名和中文名都收进来）。
public func installedFontFamilies(refresh: Bool = false) -> Set<String> {
    if !refresh, let cached = familiesCache.current, nowMs() - cached.at < 60_000 { return cached.set }
    var set = Set<String>()
    let collection = CTFontCollectionCreateFromAvailableFonts(nil)
    if let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] {
        for descriptor in descriptors {
            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String { set.insert(family) }
            var language: Unmanaged<CFString>?
            if let localized = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontFamilyNameAttribute, &language) as? String { set.insert(localized) }
        }
    }
    if let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] { set.formUnion(names) }
    familiesCache.withLock { $0 = (nowMs(), set) }
    return set
}

public struct FontPlanEntry: Sendable, Hashable {
    public let kind: String
    public let mode: String
    public let substitute: String?
    public let label: String
}

/// 每种文档这次用什么字体：原版（已安装）或替代字体。
public func resolveFontPlan(_ pdf: PdfSettings, families: Set<String>? = nil) -> [String: FontPlanEntry] {
    let installed = families ?? installedFontFamilies()
    var plan: [String: FontPlanEntry] = [:]
    for kind in DOC_FONT_ORDER {
        let doc = DOC_FONTS[kind]!
        let hasOriginal = doc.families.contains { installed.contains($0) }
        let chosen = pdf[kind]
        let key = SUBSTITUTES[chosen] != nil && SUBSTITUTE_CHOICES[kind]!.contains(chosen) ? chosen : DEFAULT_PDF_FONTS[kind]!
        plan[kind] = hasOriginal
            ? FontPlanEntry(kind: kind, mode: "original", substitute: nil, label: doc.original)
            : FontPlanEntry(kind: kind, mode: "substitute", substitute: key, label: Rx.replace("（.*$", in: SUBSTITUTES[key]!.label, with: ""))
    }
    return plan
}

public struct FontPair: Sendable, Hashable {
    public let from: String
    public let to: String
}

/// LibreOffice 配置里的「替换表」：只在这次转换用的临时配置目录里生效，不影响你平时用的 LibreOffice。
public func fontRegistryXml(_ pairs: [FontPair]) -> String {
    func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    let nodes = pairs.enumerated().map { index, pair in
        "<item oor:path=\"/org.openoffice.Office.Common/Font/Substitution/FontPairs\"><node oor:name=\"_\(index)\" oor:op=\"replace\">" +
            "<prop oor:name=\"Always\" oor:op=\"fuse\"><value>true</value></prop>" +
            "<prop oor:name=\"OnScreenOnly\" oor:op=\"fuse\"><value>false</value></prop>" +
            "<prop oor:name=\"ReplaceFont\" oor:op=\"fuse\"><value>\(escape(pair.from))</value></prop>" +
            "<prop oor:name=\"SubstituteFont\" oor:op=\"fuse\"><value>\(escape(pair.to))</value></prop>" +
            "</node></item>"
    }
    return ([
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<oor:items xmlns:oor=\"http://openoffice.org/2001/registry\" xmlns:xs=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">",
        pairs.isEmpty ? "" : "<item oor:path=\"/org.openoffice.Office.Common/Font/Substitution\"><prop oor:name=\"Replacement\" oor:op=\"fuse\"><value>true</value></prop></item>",
    ] + nodes + ["</oor:items>", ""]).joined(separator: "\n")
}

public struct FontAttempt: Sendable, Hashable {
    public let pairs: [FontPair]
    public let expect: String
    public let alsoAllowed: String?
    public let name: String
    public let key: String?
}

private let workingNames = Locked<[String: String]>([:])

public func rememberWorkingName(_ key: String?, _ name: String) {
    guard let key else { return }
    workingNames.withLock { $0[key] = name }
}

/// 这份文档要尝试的替换方案（原版字体已安装时只有一个「不替换」方案）。
public func substitutionAttempts(_ kind: String, _ entry: FontPlanEntry?) -> [FontAttempt] {
    let doc = DOC_FONTS[kind]!
    guard let entry, entry.mode != "original", let key = entry.substitute, let substitute = SUBSTITUTES[key] else {
        return [FontAttempt(pairs: [], expect: doc.expect, alsoAllowed: nil, name: doc.original, key: nil)]
    }
    let remembered = workingNames.current[key]
    let names = remembered.map { [$0] + substitute.names.filter { name in name != remembered } } ?? substitute.names
    return names.map { name in
        FontAttempt(pairs: doc.replace.map { FontPair(from: $0, to: name) }, expect: substitute.expect, alsoAllowed: substitute.alsoAllowed, name: name, key: key)
    }
}

/// PDF 里实际嵌入的字体名（去掉 ABCDEF+ 子集前缀）。
public func pdfFontNames(_ pdfPath: String) throws -> [String] {
    let data = try FS.read(pdfPath)
    let text = String(data: data, encoding: .isoLatin1) ?? ""
    var names = Set<String>()
    for match in Rx.matches(#"/BaseFont\s*/([A-Za-z0-9+#_.-]+)"#, text) {
        if let name = match[1] { names.insert(Rx.replaceFirst("^[A-Z]{6}\\+", in: name, with: "")) }
    }
    return names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
}

public struct FontVerdict: Sendable, Hashable {
    public let ok: Bool
    public let fonts: [String]
    public let unexpected: [String]
    public let expectedFound: Bool
}

/// 替代字体里没有的个别符号（✓ − ℃ ⚠ ‑ 等），LibreOffice 会从 macOS 自带的这些字体里补字，每次都一样，不算字体不对：
/// 系统符号字体，以及和苹方同为无衬线、字形接近的冬青黑体（Hiragino Sans / 角ゴシック）、苹方繁体、Helvetica、Arial Unicode。
/// 正文没换成目标字体时（预期字体根本没出现，或混进魏碑、圆体、Liberation 这类）仍然算不对。
/// （Electron 版没有放行，正文里有这类符号时第一个方案被判失败，换到认不出的英文名后反而乱抓字体。）
public let SYMBOL_FALLBACK_FONTS = "^(LucidaGrande|AppleSymbols|ZapfDingbats|STIX|Symbol|AppleColorEmoji|Menlo|HiraginoSans-|HiraKaku|PingFang(TC|HK|MO)-|Helvetica|ArialUnicodeMS)"

/// 核对：必须用到预期字体；除了它（和允许的补字字体）以外不能出现别的字体。
public func judgePdfFonts(_ fonts: [String], _ attempt: FontAttempt) -> FontVerdict {
    let expected = fonts.filter { Rx.test(attempt.expect, $0) }
    let unexpected = fonts.filter { font in
        !Rx.test(attempt.expect, font) && !(attempt.alsoAllowed.map { Rx.test($0, font) } ?? false) && !(attempt.key != nil && Rx.test(SYMBOL_FALLBACK_FONTS, font))
    }
    return FontVerdict(ok: !expected.isEmpty && unexpected.isEmpty, fonts: fonts, unexpected: unexpected, expectedFound: !expected.isEmpty)
}

public func userFontsDir() -> String { Path.join(NSHomeDirectory(), "Library", "Fonts") }

/// 把用户选的字体文件装到「当前用户」的字体文件夹（不需要管理员权限）。
public func installFontFiles(_ files: [String], targetDir: String = userFontsDir()) -> JSON {
    try? FS.mkdirp(targetDir)
    var installed: [String] = []
    var skipped: [String] = []
    for file in files {
        let name = Path.basename(file)
        guard Rx.test("\\.(ttf|ttc|otf)$", name, "i") else {
            skipped.append("\(name)：不是字体文件（只支持 .ttf / .ttc / .otf）")
            continue
        }
        let target = Path.join(targetDir, name)
        do {
            try FS.copy(file, target)
            installed.append(name)
        } catch {
            skipped.append("\(name)：\(messageOf(error))")
        }
    }
    familiesCache.withLock { $0 = nil }
    return .obj(["installed": JSON(installed), "skipped": JSON(skipped), "targetDir": .string(targetDir)])
}
