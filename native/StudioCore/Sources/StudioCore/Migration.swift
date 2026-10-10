import Foundation

/// 原生版的软件数据目录（和 Electron 版分开，两个版本互不干扰）。
public func nativeDataDir() -> String {
    Path.join(NSHomeDirectory(), "Library", "Application Support", "软件指南生成器（原生版）")
}

/// 从定档的 Electron 版导入软件数据：设置、生图线路、大模型、密钥、项目登记和状态、调用记录、补发线样本、任务账本。
/// 项目文件夹本身在工作区里，两个版本共用，不复制也不改动。Electron 版的数据只读，不修改。
public enum ElectronMigration {
    public static var defaultSourceDir: String { Path.join(NSHomeDirectory(), "Library", "Application Support", "软件指南生成器") }

    public static func available(_ sourceDir: String = defaultSourceDir) -> Bool {
        FS.exists(Path.join(sourceDir, "settings.json"))
    }

    /// 原生版还没有任何数据时（第一次打开）才主动提示导入。
    public static func isFresh(_ dataDir: String) -> Bool {
        !FS.exists(Path.join(dataDir, "settings.json")) && !FS.exists(Path.join(dataDir, "migrated-from-electron.json"))
    }

    /// 要在 StudioCore 创建之前调用（核心会缓存设置和调用记录），导入后再创建核心。
    /// readSecrets 为 false 时不读钥匙串（不导入密钥）。
    public static func migrate(from sourceDir: String = defaultSourceDir, to dataDir: String, secrets: SecretStore, readSecrets: Bool = true) async throws -> JSON {
        guard available(sourceDir) else { throw StudioError("没有找到 Electron 版的数据：\(sourceDir)") }
        try FS.mkdirp(dataDir)
        var summary = JSONObject()

        // 设置（线路、大模型、各步骤模型、工作区、代码来源……）整体用 Electron 版的
        if let settings = try FS.readJSON(Path.join(sourceDir, "settings.json")) {
            let decoded = (try? settings.decode(Settings.self)) ?? Settings()
            try FS.writeJSONAtomic(Path.join(dataDir, "settings.json"), try JSON.encode(decoded))
            summary["providers"] = .number(Double(decoded.providers.count))
            summary["vendors"] = .number(Double(decoded.llm.vendors.count))
        }

        // 项目登记：合并，已有的不重复
        let sourceIndex = FS.readJSONQuiet(Path.join(sourceDir, "projects-index.json"))?["projects"].items ?? []
        var index = FS.readJSONQuiet(Path.join(dataDir, "projects-index.json"))?["projects"].items ?? []
        let known = Set(index.compactMap { $0["dir"]?.string })
        var addedProjects = 0
        for entry in sourceIndex where !known.contains(entry["dir"]?.string ?? "") {
            index.append(entry)
            addedProjects += 1
        }
        try FS.writeJSONAtomic(Path.join(dataDir, "projects-index.json"), .obj(["projects": .array(index)]))
        summary["projects"] = .number(Double(addedProjects))

        // 项目状态：原生版没有的才复制
        let sourceProjects = Path.join(sourceDir, "projects")
        let targetProjects = Path.join(dataDir, "projects")
        try FS.mkdirp(targetProjects)
        var states = 0
        for name in FS.list(sourceProjects) ?? [] where name.hasSuffix(".json") {
            let target = Path.join(targetProjects, name)
            if FS.exists(target) { continue }
            try FileManager.default.copyItem(atPath: Path.join(sourceProjects, name), toPath: target)
            states += 1
        }
        summary["states"] = .number(Double(states))

        // 调用记录：两边合并，按时间排序，去掉重复行
        for file in ["image-calls.jsonl", "llm-calls.jsonl"] {
            let source = FS.readTextIfExists(Path.join(sourceDir, file)) ?? ""
            let current = FS.readTextIfExists(Path.join(dataDir, file)) ?? ""
            var seen = Set<String>()
            var rows: [(ts: String, line: String)] = []
            for line in (source + "\n" + current).split(separator: "\n").map(String.init) where !line.jsTrimmed.isEmpty {
                guard seen.insert(line).inserted, let parsed = try? JSON.parse(line) else { continue }
                rows.append((parsed["ts"]?.string ?? "", line))
            }
            let sorted = rows.enumerated().sorted { a, b in a.element.ts == b.element.ts ? a.offset < b.offset : a.element.ts < b.element.ts }.map(\.element.line)
            try FS.writeAtomic(Path.join(dataDir, file), sorted.isEmpty ? "" : sorted.joined(separator: "\n") + "\n")
            summary[file == "image-calls.jsonl" ? "imageCalls" : "llmCalls"] = .number(Double(sorted.count))
        }

        // 线路健康（冷却、熔断）、步骤用时样本、生图任务账本（异步任务号可以接着查）
        for file in ["provider-health.json", "step-durations.json", "image-jobs.json"] {
            let source = Path.join(sourceDir, file)
            let target = Path.join(dataDir, file)
            if FS.exists(source), !FS.exists(target) { try FileManager.default.copyItem(atPath: source, toPath: target) }
        }

        // 密钥：Electron 版用 safeStorage（钥匙串里的口令）加密，这里解开后用原生版的方式重新加密保存
        var imported = 0
        var failed: [String] = []
        if readSecrets, let stored = FS.readJSONQuiet(Path.join(sourceDir, "secrets.json"))?.object, !stored.isEmpty {
            if let storage = ElectronSafeStorage.fromKeychain() {
                for (id, value) in stored {
                    do {
                        let plain = try storage.decrypt(value.string ?? "")
                        if plain.isEmpty { continue }
                        try await secrets.set(id, plain)
                        imported += 1
                    } catch {
                        failed.append(id)
                    }
                }
            } else {
                failed = stored.keys
            }
        }
        summary["secrets"] = .number(Double(imported))
        summary["secretsFailed"] = JSON(failed)
        summary["at"] = .string(isoNow())
        summary["from"] = .string(sourceDir)
        try FS.writeJSONAtomic(Path.join(dataDir, "migrated-from-electron.json"), .object(summary))
        return .object(summary)
    }

    /// 用户选择「不导入，全新开始」时记一笔，下次不再提示。
    public static func declineFirstRun(_ dataDir: String) throws {
        try FS.mkdirp(dataDir)
        try FS.writeJSONAtomic(Path.join(dataDir, "migrated-from-electron.json"), .obj(["declined": true, "at": .string(isoNow())]))
    }
}
