import Foundation
import CryptoKit

public let STATE_VERSION = 1

public func screenId(_ index: Int) -> String { "screen-\(String(index + 1).padStart(2))" }

public struct ProjectPaths: Sendable {
    public let dir: String
    public var prompts: String { Path.join(dir, "prompts") }
    public var screens: String { Path.join(dir, "screens") }
    public var alternates: String { Path.join(dir, "screens", "alternates") }
    public var archive: String { Path.join(dir, "archive") }
    public var content: String { Path.join(dir, "content.json") }
    public var profile: String { Path.join(dir, "software-profile.json") }
    public var featureMap: String { Path.join(dir, "feature-map.json") }
    public var screenPlan: String { Path.join(dir, "screen-plan.json") }
    public var uiContract: String { Path.join(dir, "ui-contract.json") }
    public var manifest: String { Path.join(dir, "project-manifest.json") }
    public var regionIndex: String { Path.join(dir, "region-index.json") }
    public func screenFile(_ id: String) -> String { Path.join(dir, "screens", "\(id).png") }
    public func promptFile(_ id: String) -> String { Path.join(dir, "prompts", "\(id).md") }
    public func bundle(_ softwareName: String) -> String { Path.join(dir, softwareName) }
}

public func projectPaths(_ dir: String) -> ProjectPaths { ProjectPaths(dir: dir) }

/// 新项目的状态（字段和 Electron 版一致）。
public func newState(_ request: JSON) -> JSON {
    var steps = JSONObject()
    for step in PIPELINE_STEPS { steps[step] = ["status": "pending"] }
    var fields = JSONObject()
    fields["softwareName"] = request["softwareName"] ?? ""
    fields["versionPolicy"] = request["versionPolicy"].or("in-name")
    fields["applicableVersion"] = .string(request["applicableVersion"].text)
    fields["screenCount"] = request["screenCount"].or(.null)
    fields["emphasis"] = .string(request["emphasis"].text)
    fields["notes"] = .string(request["notes"].text)
    fields["platform"] = .string(request["platform"].text)
    fields["wantDesign"] = .bool(request["wantDesign"].isTruthy)
    fields["codeSource"] = request["codeSource"].or(.null)
    fields["txtFields"] = request["txtFields"].or(.null)
    fields["extraBrandTokens"] = request["extraBrandTokens"].or([])
    fields["compileDate"] = .string(request["compileDate"].text)
    fields["createdAt"] = request["createdAt"].or(.string(isoNow().jsSlice(0, 10)))
    var state = JSONObject()
    state["schemaVersion"] = .number(Double(STATE_VERSION))
    state["request"] = .object(fields)
    state["status"] = "idle"
    state["steps"] = .object(steps)
    state["screens"] = .emptyObject
    state["warnings"] = []
    state["log"] = []
    state["origin"] = request["origin"].or("created")
    return .object(state)
}

/// 项目状态文件名：路径的 SHA-1 前 16 位（和 Electron 版一致，导入后能对上）。
public func projectKey(_ dir: String) -> String {
    String(Insecure.SHA1.hash(data: Data(Path.resolve(dir).utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
}

/// 项目状态存在软件自己的数据目录里（不往项目文件夹写隐藏文件），
/// 每个项目的写操作排队执行，避免多个步骤同时改状态。
public final class ProjectStore: @unchecked Sendable {
    public let dataDir: String
    public let stagingRoot: String
    private let queues = Locked<[String: SerialQueue]>([:])

    public init(dataDir: String) {
        self.dataDir = dataDir
        stagingRoot = Path.join(dataDir, "staging")
    }

    private func queue(_ dir: String) -> SerialQueue {
        queues.withLock { table in
            if let existing = table[dir] { return existing }
            let created = SerialQueue()
            table[dir] = created
            return created
        }
    }

    public func stateFile(_ dir: String) -> String { Path.join(dataDir, "projects", "\(projectKey(dir)).json") }

    public func read(_ dir: String) throws -> JSON? {
        guard var state = try FS.readJSON(stateFile(dir)) else { return nil }
        for step in PIPELINE_STEPS where state["steps"]?[step] == nil {
            if state["steps"] == nil { state["steps"] = .emptyObject }
            state["steps"]?[step] = ["status": "pending"]
        }
        state["dir"] = .string(dir)
        return state
    }

    public func exists(_ dir: String) -> Bool { FS.exists(stateFile(dir)) }

    public func write(_ dir: String, _ state: JSON) async throws {
        let file = stateFile(dir)
        var next = state
        next["dir"] = .string(dir)
        let snapshot = next
        try await queue(dir).run { try FS.writeJSONAtomic(file, snapshot) }
    }

    /// 读出当前状态 → 修改 → 写回（同一个项目排队执行）。
    @discardableResult
    public func update(_ dir: String, _ mutate: @escaping @Sendable (inout JSON) throws -> Void) async throws -> JSON {
        let file = stateFile(dir)
        return try await queue(dir).run { [self] in
            guard var state = try self.read(dir) else { throw StudioError("项目状态不存在：\(dir)") }
            try mutate(&state)
            state["dir"] = .string(dir)
            try FS.writeJSONAtomic(file, state)
            return state
        }
    }

    public func remove(_ dir: String) async {
        let file = stateFile(dir)
        _ = try? await queue(dir).run { FS.remove(file) }
    }

    /// 项目文件夹改名后，把状态搬到新路径名下。
    public func move(_ fromDir: String, _ toDir: String) throws {
        guard var state = try read(fromDir) else { return }
        state["dir"] = .string(toDir)
        try FS.writeJSONAtomic(stateFile(toDir), state)
        FS.remove(stateFile(fromDir))
    }
}

/// 读规划。历史项目的规划格式不统一：数组 / { screens } / { flow }，行里用 id 或 screenId。
public func readPlan(_ dir: String) throws -> JSON? {
    let paths = projectPaths(dir)
    let profile = try FS.readJSON(paths.profile)
    let featureMap = try FS.readJSON(paths.featureMap)
    let uiContract = try FS.readJSON(paths.uiContract)
    guard let screenPlan = try FS.readJSON(paths.screenPlan), screenPlan.truthy else { return nil }
    let listed: JSON = screenPlan.isArray ? screenPlan : screenPlan["screens"].or(screenPlan["flow"] ?? .null)
    var rows: [JSON] = listed.items
    rows = rows.map { row in
        if let title = row.string { return ["title": .string(title)] }
        return row.isObject ? row : .emptyObject
    }
    if rows.isEmpty {
        // 规划里一屏都读不到时，按文案里的界面补齐，避免把已有文案当成「0 屏」
        let content = FS.readJSONQuiet(paths.content)
        rows = (content?["screens"]?.array ?? []).map { .obj(["title": $0["title"]]) }
    }
    var screens: [JSON] = []
    for (index, screen) in rows.enumerated() {
        var next = screen
        let fallback = JSON.string(screenId(index))
        next["id"] = screen["id"].or(screen["screenId"].or(fallback))
        next["title"] = screen["title"].or(screen["name"].or(screen["purpose"].or(fallback)))
        screens.append(next)
    }
    if screens.isEmpty { return nil }
    var planObject = screenPlan.isArray ? JSON.emptyObject : screenPlan
    planObject["screens"] = .array(screens)
    var result = JSONObject()
    result["profile"] = profile ?? .null
    result["featureMap"] = featureMap ?? .null
    result["screenPlan"] = planObject
    result["uiContract"] = uiContract ?? .null
    result["screens"] = .array(screens)
    return .object(result)
}

public func listScreenFiles(_ dir: String) -> [String] {
    (FS.list(projectPaths(dir).screens) ?? []).filter { Rx.test("^screen-[0-9]+\\.png$", $0, "i") }.sorted()
}

public func listAlternates(_ dir: String, _ id: String) -> [JSON] {
    let folder = Path.join(projectPaths(dir).alternates, id)
    let names = (FS.list(folder) ?? []).filter { $0.hasSuffix(".png") }.sorted().reversed()
    return names.map { .obj(["file": .string(Path.join(folder, $0)), "name": .string($0)]) }
}

public func appendLog(_ state: inout JSON, _ message: String, _ level: String = "info") {
    var log = state["log"]?.array ?? []
    log.append(.obj(["at": .string(isoNow()), "level": .string(level), "message": .string(message)]))
    if log.count > 400 { log.removeFirst(log.count - 400) }
    state["log"] = .array(log)
}
