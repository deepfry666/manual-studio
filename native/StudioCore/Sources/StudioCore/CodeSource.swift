import Foundation

let MAX_CODE_FILES = 5000
let MAX_CODE_BYTES = 30 * 1024 * 1024

public struct CodeCollection: Sendable {
    public let root: String
    public let extensions: [String]
    public let files: [String]
    public var fileCount: Int { files.count }
    public let lineCount: Int
    public let nonEmptyLines: Int
    public let bytes: Int
    public let body: String
    /// 代码正文指纹：写进生成记录，可以核对交付包里的代码文档用的是哪一版代码
    public let sha256: String
    public let warnings: [String]
    /// 现有代码文档格式（新宋体 9pt、A4）实测每页约 45 行，只作页数估算
    public var estimatedPages: Int { Int((Double(lineCount) / 45).rounded(.up)) }
}

/// 和 JS 的 `a.localeCompare(b, "en")` 一样的排序。
func localeCompareEn(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [], range: nil, locale: Locale(identifier: "en")) == .orderedAscending
}

/// 读取代码来源，按相对路径排序后原样拼接。
/// 不改写、不替换、不生成任何代码；只统一换行符，并跳过二进制文件。
public func collectCodeSource(path sourcePath: String, extensions sourceExtensions: [String], excludeDirs: [String] = []) throws -> CodeCollection {
    let root = Path.resolve(sourcePath)
    let extensions = (sourceExtensions.isEmpty ? [".java"] : sourceExtensions).map { ($0.hasPrefix(".") ? $0 : ".\($0)").lowercased() }
    let exclude = Set(excludeDirs)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else { throw StudioError("代码来源不存在：\(root)") }
    let rootIsFile = !isDirectory.boolValue
    var files: [String] = []
    var warnings: [String] = []
    if rootIsFile {
        files.append(root)
    } else {
        func walk(_ dir: String) throws {
            let names = (FS.list(dir) ?? []).sorted(by: localeCompareEn)
            for name in names {
                if name.hasPrefix(".") { continue }
                let full = Path.join(dir, name)
                let type = (try? FileManager.default.attributesOfItem(atPath: full)[.type] as? FileAttributeType) ?? nil
                if type == .typeDirectory {
                    if !exclude.contains(name) { try walk(full) }
                } else if type == .typeRegular, extensions.contains(Path.extname(name).lowercased()) {
                    files.append(full)
                    if files.count > MAX_CODE_FILES { throw StudioError("代码文件超过 \(MAX_CODE_FILES) 个，请缩小代码来源范围") }
                }
            }
        }
        try walk(root)
    }
    if files.isEmpty { throw StudioError("代码来源里没有找到 \(extensions.joined(separator: "、")) 文件") }

    var parts: [String] = []
    var included: [String] = []
    var bytes = 0
    for file in files {
        let data = try FS.read(file)
        if data.contains(0) {
            warnings.append("跳过二进制文件：\(Path.relative(rootIsFile ? Path.dirname(root) : root, file))")
            continue
        }
        bytes += data.count
        if bytes > MAX_CODE_BYTES { throw StudioError("代码总量超过 30MB，请缩小代码来源范围") }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = Rx.replace(#"\r\n?"#, in: text, with: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        parts.append(text)
        included.append(rootIsFile ? Path.basename(file) : Path.relative(root, file))
    }
    let body = Rx.replace(#"\n+$"#, in: parts.joined(), with: "\n")
    let trimmedBody = body.hasSuffix("\n") ? String(body.dropLast()) : body
    let lines = trimmedBody.components(separatedBy: "\n")
    return CodeCollection(
        root: root,
        extensions: extensions,
        files: included,
        lineCount: lines.count,
        nonEmptyLines: lines.filter { !$0.jsTrimmed.isEmpty }.count,
        bytes: bytes,
        body: body,
        sha256: sha256Hex(body),
        warnings: warnings
    )
}

public func languageLabelFor(_ extensions: [String]) -> String {
    let map = [".java": "JAVA", ".kt": "Kotlin", ".swift": "Swift", ".m": "Objective-C", ".dart": "Dart", ".js": "JavaScript", ".ts": "TypeScript", ".tsx": "TypeScript", ".py": "Python", ".go": "Go", ".cs": "C#", ".cpp": "C++", ".c": "C", ".php": "PHP", ".vue": "Vue"]
    return uniqued(extensions.compactMap { map[$0.lowercased()] }).joined(separator: "、")
}
