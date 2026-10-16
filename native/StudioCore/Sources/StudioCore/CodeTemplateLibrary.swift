import Foundation

// MARK: - 代码模板库
//
// 设置里可以放多个代码模板，按加入顺序叫「模板 1、模板 2…」。加入时就整理成统一版式、正好 60 页 × 50 行，
// 存进数据文件夹的 code-templates/<编号指纹>.docx；之后每个项目原样使用，只换页眉。
// 新建项目时按设置分配：默认「轮流平均分」（哪个用得少先分给谁），也可以全部用某一个。
// 模板被项目用过以后不能删、不能换内容，保证已交付的项目能原样重出。

public struct CodeTemplateEntry: Codable, Sendable, Hashable, Identifiable {
    /// 整理好的模板文件指纹，也是文件名
    public var id: String
    public var number: Int
    /// 用户给的原文件名（只用来显示）
    public var sourceName: String
    /// 原文件指纹：同一份文件再加一次时认得出来；旧项目记的是原模板路径，也靠它对上
    public var sourceSha: String
    /// 原模板印出来多少行（超过 3000 的被裁过）
    public var sourceRows: Int
    public var enabled: Bool
    public var addedAt: String

    public var label: String { "模板 \(number)" }
    public var cropped: Bool { sourceRows > CodeLayout.totalRows }

    public init(id: String, number: Int, sourceName: String, sourceSha: String, sourceRows: Int, enabled: Bool = true, addedAt: String = isoNow()) {
        self.id = id
        self.number = number
        self.sourceName = sourceName
        self.sourceSha = sourceSha
        self.sourceRows = sourceRows
        self.enabled = enabled
        self.addedAt = addedAt
    }
    enum CodingKeys: String, CodingKey { case id, number, sourceName, sourceSha, sourceRows, enabled, addedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, "")
        number = c.number(.number, 0)
        sourceName = c.value(.sourceName, "")
        sourceSha = c.value(.sourceSha, "")
        sourceRows = c.number(.sourceRows, CodeLayout.totalRows)
        enabled = c.value(.enabled, true)
        addedAt = c.value(.addedAt, "")
    }
}

public struct CodeTemplateLibrary: Codable, Sendable, Hashable {
    public var entries: [CodeTemplateEntry] = []
    /// balance：轮流平均分；fixed：全部用 fixedId
    public var assign = "balance"
    public var fixedId = ""

    public init() {}
    enum CodingKeys: String, CodingKey { case entries, assign, fixedId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = c.value(.entries, [])
        assign = c.value(.assign, "balance")
        fixedId = c.value(.fixedId, "")
    }

    public var enabled: [CodeTemplateEntry] { entries.filter(\.enabled).sorted { $0.number < $1.number } }
    public func entry(_ id: String) -> CodeTemplateEntry? { entries.first { $0.id == id } }

    /// 项目记的代码来源路径对应哪个模板：新项目记整理好的文件，旧项目记的是原模板副本。
    public func entry(forPath path: String) -> CodeTemplateEntry? {
        guard Path.extname(path).lowercased() == ".docx" else { return nil }
        let sha = Path.basename(path, ".docx")
        return entries.first { $0.id == sha || $0.sourceSha == sha }
    }

    /// 给下一个项目分模板。usage 是各模板已用的项目数，分完会加一。
    public func pick(_ usage: inout [String: Int]) -> CodeTemplateEntry? {
        let candidates = enabled
        if assign == "fixed", let fixed = candidates.first(where: { $0.id == fixedId }) {
            usage[fixed.id, default: 0] += 1
            return fixed
        }
        guard let chosen = candidates.min(by: { (usage[$0.id] ?? 0, $0.number) < (usage[$1.id] ?? 0, $1.number) }) else { return nil }
        usage[chosen.id, default: 0] += 1
        return chosen
    }
}

public func codeTemplateFile(_ dataDir: String, _ id: String) -> String { Path.join(dataDir, "code-templates", "\(id).docx") }

public func codeSourceJSON(_ dataDir: String, _ entry: CodeTemplateEntry) -> JSON {
    ["path": .string(codeTemplateFile(dataDir, entry.id)), "extensions": [".java"], "templateId": .string(entry.id)]
}

extension StudioCore {
    /// 旧版本只有一个代码模板（设置里的 codeSource）：第一次打开模板库时把它整理好，作为「模板 1」。
    func migrateCodeTemplateLibrary() async throws {
        let settings = try await settingsStore.get()
        guard settings.codeTemplates.entries.isEmpty, Path.extname(settings.codeSource.path).lowercased() == ".docx", FS.exists(settings.codeSource.path) else { return }
        let raw = try FS.read(settings.codeSource.path)
        let template = try CodeWordTemplate(data: raw)
        let file = codeTemplateFile(dataDir, template.sha256)
        if !FS.exists(file) { try FS.writeAtomic(file, template.data) }
        let entry = CodeTemplateEntry(id: template.sha256, number: 1, sourceName: "原来的代码模板", sourceSha: sha256Hex(raw), sourceRows: template.sourceRows)
        _ = try await settingsStore.update { next in
            guard next.codeTemplates.entries.isEmpty else { return }
            next.codeTemplates.entries = [entry]
            next.codeSource = CodeSourceSetting(path: file, extensions: [".java"])
        }
    }

    /// 各模板用在几个项目上。没记代码来源、也还没锁定的项目会用默认模板，算在默认模板上。
    func codeTemplateUsage(_ library: CodeTemplateLibrary, _ settings: Settings) -> [String: Int] {
        var usage: [String: Int] = [:]
        for item in readIndex()["projects"].items {
            guard let dir = item["dir"]?.string, let state = try? projectStore.read(dir) else { continue }
            let path = codeSourceFor(state, settings).source?["path"]?.string ?? ""
            if let entry = library.entry(forPath: path) { usage[entry.id, default: 0] += 1 }
        }
        return usage
    }

    /// 模板库和各模板的使用情况（给设置页用）。
    public func codeTemplateLibrary() async throws -> JSON {
        try? await migrateCodeTemplateLibrary()
        let settings = try await settingsStore.get()
        let library = settings.codeTemplates
        let usage = codeTemplateUsage(library, settings)
        return .obj([
            "assign": .string(library.assign), "fixedId": .string(library.fixedId),
            "entries": .array(library.entries.sorted { $0.number < $1.number }.map { entry in
                .obj([
                    "id": .string(entry.id), "number": .number(Double(entry.number)), "label": .string(entry.label), "sourceName": .string(entry.sourceName),
                    "sourceRows": .number(Double(entry.sourceRows)), "cropped": .bool(entry.cropped), "enabled": .bool(entry.enabled), "addedAt": .string(entry.addedAt),
                    "usage": .number(Double(usage[entry.id] ?? 0)), "file": .string(codeTemplateFile(dataDir, entry.id)),
                ])
            }),
        ])
    }

    /// 用某个模板的项目（设置页点「用在几个项目」时列出来）。
    public func projectsUsingCodeTemplate(_ id: String) async throws -> [String] {
        let settings = try await settingsStore.get()
        guard let entry = settings.codeTemplates.entry(id) else { return [] }
        return readIndex()["projects"].items.compactMap { item -> String? in
            guard let dir = item["dir"]?.string, let state = try? projectStore.read(dir) else { return nil }
            return settings.codeTemplates.entry(forPath: codeSourceFor(state, settings).source?["path"]?.string ?? "")?.id == entry.id ? dir : nil
        }
    }

    /// 一次加多份模板。每份单独检查：.doc 先转成 .docx；印出来不够 3000 行、格式不对的不加，写明原因；
    /// 超过 60 页的按「前 1500 + 后 1500 行」裁好再存。原文件不改。
    public func addCodeTemplates(_ paths: [String]) async throws -> [JSON] {
        try? await migrateCodeTemplateLibrary()
        var results: [JSON] = []
        for path in paths {
            let name = Path.basename(path)
            do {
                let raw: Data
                switch Path.extname(path).lowercased() {
                case ".docx": raw = try FS.read(path)
                case ".doc": raw = try await convertDocToDocx(path)
                default: throw StudioError("只支持 Word 文件（.docx 或 .doc）")
                }
                let sourceSha = sha256Hex(try FS.read(path))
                let template = try CodeWordTemplate(data: raw)
                let current = try await settingsStore.get().codeTemplates
                if let found = current.entries.first(where: { $0.id == template.sha256 || $0.sourceSha == sourceSha }) {
                    results.append(.obj(["file": .string(name), "ok": false, "error": .string("已经在模板库里了（\(found.label)）")]))
                    continue
                }
                let file = codeTemplateFile(dataDir, template.sha256)
                if !FS.exists(file) { try FS.writeAtomic(file, template.data) }
                let entry = CodeTemplateEntry(id: template.sha256, number: (current.entries.map(\.number).max() ?? 0) + 1, sourceName: name, sourceSha: sourceSha, sourceRows: template.sourceRows)
                _ = try await settingsStore.update { next in
                    next.codeTemplates.entries.append(entry)
                    if next.codeSource.path.isEmpty { next.codeSource = CodeSourceSetting(path: file, extensions: [".java"]) }
                }
                results.append(.obj([
                    "file": .string(name), "ok": true, "label": .string(entry.label), "id": .string(entry.id),
                    "sourceRows": .number(Double(template.sourceRows)), "cropped": .bool(template.cropped), "lines": .number(Double(template.sourceLineCount)),
                ]))
            } catch {
                results.append(.obj(["file": .string(name), "ok": false, "error": .string(messageOf(error))]))
            }
        }
        return results
    }

    public func setCodeTemplateEnabled(_ id: String, _ enabled: Bool) async throws {
        _ = try await settingsStore.update { next in
            guard let index = next.codeTemplates.entries.firstIndex(where: { $0.id == id }) else { throw StudioError("模板不存在") }
            if !enabled, next.codeTemplates.entries.filter(\.enabled).count == 1, next.codeTemplates.entries[index].enabled {
                throw StudioError("至少要留一个启用的模板")
            }
            next.codeTemplates.entries[index].enabled = enabled
        }
    }

    /// 只能删没被任何项目用过的模板。
    public func removeCodeTemplate(_ id: String) async throws {
        let settings = try await settingsStore.get()
        guard let entry = settings.codeTemplates.entry(id) else { throw StudioError("模板不存在") }
        let used = codeTemplateUsage(settings.codeTemplates, settings)[id] ?? 0
        guard used == 0 else { throw StudioError("\(entry.label) 已用在 \(used) 个项目上，不能删除；不想再用可以停用") }
        let dataDir = self.dataDir
        _ = try await settingsStore.update { next in
            next.codeTemplates.entries.removeAll { $0.id == id }
            if next.codeTemplates.fixedId == id { next.codeTemplates.fixedId = ""; next.codeTemplates.assign = "balance" }
            if Path.basename(next.codeSource.path, ".docx") == id {
                let fallback = next.codeTemplates.enabled.first
                next.codeSource = CodeSourceSetting(path: fallback.map { codeTemplateFile(dataDir, $0.id) } ?? "", extensions: [".java"])
            }
        }
        FS.remove(codeTemplateFile(dataDir, id))
    }

    public func setCodeTemplateAssignment(_ assign: String, fixedId: String = "") async throws {
        _ = try await settingsStore.update { next in
            if assign == "fixed" {
                guard next.codeTemplates.entries.contains(where: { $0.id == fixedId && $0.enabled }) else { throw StudioError("请选一个启用的模板") }
                next.codeTemplates.assign = "fixed"
                next.codeTemplates.fixedId = fixedId
            } else {
                next.codeTemplates.assign = "balance"
            }
        }
    }

    /// 给一批新项目分模板（批量新建前预览用）：返回每个项目分到的模板编号。
    public func previewCodeTemplateAssignment(count: Int, fixedId: String? = nil) async throws -> [String] {
        try? await migrateCodeTemplateLibrary()
        let settings = try await settingsStore.get()
        var library = settings.codeTemplates
        if let fixedId, !fixedId.isEmpty { library.assign = "fixed"; library.fixedId = fixedId }
        var usage = codeTemplateUsage(library, settings)
        return (0..<count).compactMap { _ in library.pick(&usage)?.label }
    }

    /// 给一个项目换代码模板：已经有交付包的，马上只重做代码 Word、PDF 和 TXT 开头（不调用 AI）；还没有的，下次生成时用新模板。
    public func useCodeTemplate(_ dir: String, _ id: String) async throws -> JSON {
        let settings = try await settingsStore.get()
        guard let entry = settings.codeTemplates.entry(id), entry.enabled else { throw StudioError("请选一个启用的模板") }
        guard let state = try projectStore.read(dir) else { throw StudioError("项目不存在") }
        try assertNotSubmitted(state)
        let name = state["request"]?["softwareName"]?.jsString ?? ""
        let bundle = projectPaths(dir).bundle(name)
        if state["lastBuild"].isTruthy, FS.exists(Path.join(bundle, "\(name)指南.txt")) {
            let result = await applyCodeTemplates([dir], mode: "fixed", templateId: id)
            if let message = (result["failed"].items + result["skipped"].items).first?.jsString { throw StudioError(message) }
            return .obj(["applied": true])
        }
        _ = try await pipeline.updateRequest(dir, .obj(["codeSource": codeSourceJSON(dataDir, entry), "codeSourceLocked": true]))
        return .obj(["applied": false])
    }
}
