import Foundation

// MARK: - 改错了能回去
//
// 文字：保存、AI 重写之前的旧文字记进 content-history.json，每处最多留 30 份。
//       连续打字（自动保存）时同一处 3 分钟内只记一份，免得历史里全是半句话。
// 截图：重新生成、换备选图时旧图本来就归档在 archive/screens-*/，这里列出来，可以换回。
// 交付包：每次软件自己写完交付包，记下 Word / TXT 的指纹；下次更新前发现文件被改过
//        （比如在 WPS 里手改），先停下来问，不悄悄覆盖。

public let CONTENT_HISTORY_FILE = "content-history.json"
private let HISTORY_KEEP = 30
private let HISTORY_COALESCE_MS: Double = 3 * 60 * 1000

public struct ContentVersion: Sendable {
    /// overview，或 screen-XX
    public let target: String
    public let title: String?
    public let text: String
    /// 记下的原因：保存前 / AI 重写前
    public let source: String
    public init(target: String, title: String? = nil, text: String, source: String) {
        self.target = target
        self.title = title
        self.text = text
        self.source = source
    }
}

/// 记下旧文字。coalesce：自动保存时，同一处最近 3 分钟内已经记过就不再记。
func recordContentHistory(_ dir: String, _ versions: [ContentVersion], coalesce: Bool = false) {
    let file = Path.join(dir, CONTENT_HISTORY_FILE)
    var all = (FS.readJSONQuiet(file)?["versions"].items) ?? []
    let now = nowMs()
    for version in versions where !version.text.jsTrimmed.isEmpty {
        let previous = all.last { $0["target"]?.string == version.target }
        if previous?["text"]?.string == version.text { continue }
        if coalesce, let at = previous?["atMs"]?.number, now - at < HISTORY_COALESCE_MS, previous?["source"]?.string == version.source { continue }
        all.append(.obj([
            "target": .string(version.target), "title": JSON.maybe(version.title), "text": .string(version.text),
            "source": .string(version.source), "at": .string(isoNow()), "atMs": .number(now),
        ]))
    }
    // 每处只留最近 30 份
    var kept: [JSON] = []
    var counts: [String: Int] = [:]
    for entry in all.reversed() {
        let target = entry["target"].text
        counts[target, default: 0] += 1
        if counts[target]! <= HISTORY_KEEP { kept.append(entry) }
    }
    try? FS.writeJSONAtomic(file, .obj(["versions": .array(kept.reversed())]))
}

/// 某一处（或全部）的历史文字，新的在前
public func contentHistory(_ dir: String, target: String? = nil) -> [JSON] {
    let all = FS.readJSONQuiet(Path.join(dir, CONTENT_HISTORY_FILE))?["versions"].items ?? []
    return all.filter { target == nil || $0["target"]?.string == target }.reversed()
}

/// 这一屏以前用过的截图（重新生成、换备选图时归档的旧图），新的在前
public func screenHistory(_ dir: String, _ id: String) -> [JSON] {
    let archive = projectPaths(dir).archive
    var items: [(folder: String, file: String)] = []
    for folder in FS.list(archive) ?? [] where folder.hasPrefix("screens-") {
        for file in FS.list(Path.join(archive, folder)) ?? [] where file == "\(id).png" || Rx.test("^\(NSRegularExpression.escapedPattern(for: id))-[0-9]+\\.png$", file) {
            items.append((folder, file))
        }
    }
    items.sort { a, b in a.folder == b.folder ? localeCompareEn(b.file, a.file) : localeCompareEn(b.folder, a.folder) }
    return items.map { item in
        .obj(["file": .string(Path.join(archive, item.folder, item.file)), "at": JSON.maybe(archiveFolderDate(item.folder))])
    }
}

/// screens-2026-10-16T03-16-44-480Z（或截到分钟）→ ISO 时间
func archiveFolderDate(_ folder: String) -> String? {
    guard let groups = Rx.match(#"^screens-([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2})-([0-9]{2})"#, folder) else { return nil }
    return "\(groups[1] ?? "")T\(groups[2] ?? ""):\(groups[3] ?? ""):00Z"
}

/// 交付包里会被手改的文件（Word、TXT）的指纹
func bundleHashes(_ dir: String, _ softwareName: String) -> JSON {
    let bundle = projectPaths(dir).bundle(softwareName)
    var hashes = JSONObject()
    for file in (FS.list(bundle) ?? []).sorted() where file.hasSuffix(".docx") || file.hasSuffix(".txt") {
        if let sha = try? sha256File(Path.join(bundle, file)) { hashes[file] = .string(sha) }
    }
    return .object(hashes)
}

/// 软件自己改写了交付包里的某几个文件后，只更新这几个文件的指纹（其他文件如果被手改过，仍然能发现）
func refreshBundleHashes(_ lastBuild: JSON, _ dir: String, _ softwareName: String, files: [String]) -> JSON {
    var hashes = lastBuild["bundleHashes"]?.fields ?? JSONObject()
    let bundle = projectPaths(dir).bundle(softwareName)
    for file in files {
        if let sha = try? sha256File(Path.join(bundle, file)) { hashes[file] = .string(sha) }
    }
    return .object(hashes)
}

/// 上次软件生成交付包后，又在软件外被改过的文件名。
/// 有指纹时逐个比对；1.4.9 之前生成、没有指纹的，只看指南 Word 的修改时间是否晚于上次生成 2 分钟以上
/// （代码文档和 TXT 会被「批量应用代码模板」改写，旧项目不按时间判断，免得误报）。
public func externallyEditedFiles(_ dir: String, _ state: JSON) -> [String] {
    let name = state["request"]?["softwareName"]?.jsString ?? ""
    let bundle = projectPaths(dir).bundle(name)
    guard FS.exists(bundle) else { return [] }
    if let hashes = state["lastBuild"]?["bundleHashes"]?.fields, !hashes.isEmpty {
        return hashes.keys.sorted().filter { file in
            let path = Path.join(bundle, file)
            guard FS.exists(path), let sha = try? sha256File(path) else { return false }
            return sha != hashes[file]?.string
        }
    }
    guard let at = state["lastBuild"]?["at"]?.string, let built = ISO8601DateFormatter.withFraction.date(from: at) ?? ISO8601DateFormatter().date(from: at) else { return [] }
    let guide = "\(name)指南.docx"
    guard let mtime = FS.mtimeMs(Path.join(bundle, guide)) else { return [] }
    return mtime > built.timeIntervalSince1970 * 1000 + 120_000 ? [guide] : []
}

extension ISO8601DateFormatter {
    static var withFraction: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
