import Foundation

/// 批量队列：按设置的项目并发数依次跑完整流程；软件重启后，之前「运行中」的项目回到队列续跑。
public final class BatchQueue: @unchecked Sendable {
    let file: String
    let settingsStore: SettingsStore
    let pipeline: Pipeline
    let emit: @Sendable (JSON) -> Void
    private let serial = SerialQueue()
    private let state = Locked<(items: [JSON], paused: Bool, loaded: Bool)>(([], false, false))
    private let active = Locked<Set<String>>([])
    private let pumpLock = SerialQueue()

    public init(dataDir: String, settingsStore: SettingsStore, pipeline: Pipeline, emit: @escaping @Sendable (JSON) -> Void = { _ in }) {
        file = Path.join(dataDir, "batch-queue.json")
        self.settingsStore = settingsStore
        self.pipeline = pipeline
        self.emit = emit
    }

    private func load() {
        state.withLock { current in
            guard !current.loaded else { return }
            let stored = FS.readJSONQuiet(file) ?? .emptyObject
            current.items = stored["items"].items.map { item in
                item["status"]?.string == "running" ? item.merging(["status": "queued"]) : item
            }
            current.paused = stored["paused"].isTruthy
            current.loaded = true
        }
    }

    private func persist() async {
        let snapshot = state.withLock { JSON.obj(["items": .array($0.items), "paused": .bool($0.paused)]) }
        let file = self.file
        _ = try? await serial.run { try FS.writeJSONAtomic(file, snapshot) }
    }

    private func notify() {
        let snapshot = state.withLock { (items: $0.items, paused: $0.paused) }
        emit(.obj(["type": "batch", "items": .array(snapshot.items), "paused": .bool(snapshot.paused)]))
    }

    private func mutate(_ id: String, _ body: (inout JSON) -> Void) {
        state.withLock { current in
            if let index = current.items.firstIndex(where: { $0["id"]?.string == id }) { body(&current.items[index]) }
        }
    }

    func pump() async {
        load()
        _ = try? await pumpLock.run { await self.pumpInner() }
    }

    private func pumpInner() async {
        if state.withLock({ $0.paused }) { return }
        let settings = try? await settingsStore.get()
        let limit = max(1, settings?.pipeline.batchConcurrency ?? 2)
        while active.withLock({ $0.count }) < limit {
            guard let item = state.withLock({ $0.items.first { $0["status"]?.string == "queued" } }), let id = item["id"]?.string else { break }
            let projectDir = item["projectDir"]?.string ?? ""
            let startedAt = isoNow()
            mutate(id) { entry in
                entry["status"] = "running"
                entry["startedAt"] = .string(startedAt)
                entry["error"] = .null
            }
            active.withLock { _ = $0.insert(id) }
            await persist()
            notify()
            Task {
                // 补发额度按「每个项目每次运行」计算，不在整个批量之间共用
                let result = await self.pipeline.run(projectDir, RunOptions(reviewPlan: false))
                let status = result.status == "done" ? "done" : result.status == "waiting" ? "needs-attention" : result.status == "canceled" ? "paused" : "failed"
                let error: JSON = result.error.map(JSON.string) ?? (result.status == "waiting" ? .string("等待确认：\(result.step ?? "")") : .null)
                let finishedAt = isoNow()
                self.mutate(id) { entry in
                    entry["status"] = .string(status)
                    entry["error"] = error
                    entry["finishedAt"] = .string(finishedAt)
                }
                self.active.withLock { _ = $0.remove(id) }
                await self.persist()
                self.notify()
                await self.pump()
            }
        }
    }

    public func kick() { Task { await pump() } }

    public func initialize() async {
        load()
        await persist()
        Task { await pump() }
    }

    public func list() -> (items: [JSON], paused: Bool) {
        load()
        return state.withLock { ($0.items, $0.paused) }
    }

    @discardableResult
    public func enqueue(_ projectDirs: [String], name: String = "") async -> String {
        load()
        let batchId = "batch-\(randomHex(4))"
        let addedAt = isoNow()
        state.withLock { current in
            for projectDir in projectDirs {
                if current.items.contains(where: { $0["projectDir"]?.string == projectDir && ["queued", "running"].contains($0["status"]?.string ?? "") }) { continue }
                current.items.append(.obj(["id": .string(randomHex(6)), "projectDir": .string(projectDir), "batchId": .string(batchId), "batchName": .string(name), "status": "queued", "addedAt": .string(addedAt)]))
            }
        }
        await persist()
        notify()
        Task { await pump() }
        return batchId
    }

    public func pause() async {
        load()
        let runningDirs: [String] = state.withLock { current in
            current.paused = true
            return current.items.filter { $0["status"]?.string == "running" }.compactMap { $0["projectDir"]?.string }
        }
        for dir in runningDirs { pipeline.cancel(dir) }
        await persist()
        notify()
    }

    public func resume() async {
        load()
        state.withLock { current in
            current.paused = false
            current.items = current.items.map { $0["status"]?.string == "paused" ? $0.merging(["status": "queued"]) : $0 }
        }
        await persist()
        notify()
        Task { await pump() }
    }

    public func retry(_ id: String) async {
        load()
        mutate(id) { entry in
            if !["running", "queued"].contains(entry["status"]?.string ?? "") { entry["status"] = "queued" }
        }
        await persist()
        notify()
        Task { await pump() }
    }

    public func remove(_ id: String) async {
        load()
        let runningDir: String? = state.withLock { current in
            let item = current.items.first { $0["id"]?.string == id }
            current.items.removeAll { $0["id"]?.string == id }
            return item?["status"]?.string == "running" ? item?["projectDir"]?.string : nil
        }
        if let runningDir { pipeline.cancel(runningDir) }
        await persist()
        notify()
    }

    /// 批量里失败或等确认的项目，之后在项目里手动处理完成了，就把这条记录也标成完成，
    /// 不然「需处理」一直挂着（Electron 版没有这一步，只能一直留着）。
    /// statusOf 返回项目当前状态；只在不是批量自己正在跑的项目上生效。
    public func settle(statusOf: (String) -> String?) async {
        load()
        let changed: Bool = state.withLock { current in
            var changed = false
            for index in current.items.indices {
                let item = current.items[index]
                guard ["failed", "needs-attention"].contains(item["status"]?.string ?? ""), let dir = item["projectDir"]?.string, statusOf(dir) == "done" else { continue }
                current.items[index] = item.merging(["status": "done", "error": .null, "finishedAt": .string(isoNow())])
                changed = true
            }
            return changed
        }
        guard changed else { return }
        await persist()
        notify()
    }

    public func clearFinished() async {
        load()
        state.withLock { $0.items.removeAll { $0["status"]?.string == "done" } }
        await persist()
        notify()
    }
}

public struct BatchRow: Sendable, Hashable {
    public let softwareName: String
    public let screenCount: Int?
    public let emphasis: String
    public let notes: String
}

/// 解析批量新建列表：每行一个项目，最简单就是每行一个软件名；
/// 也可以用逗号（或 Tab）带上：软件名,截图数,重点功能,补充说明。第一行是表头时自动跳过。
public func parseBatchList(_ text: String) -> [BatchRow] {
    var rows: [BatchRow] = []
    let cleaned = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    let lines = Rx.split(#"\r?\n"#, cleaned).filter { !$0.jsTrimmed.isEmpty }
    for (index, line) in lines.enumerated() {
        var cells: [String] = []
        var current = ""
        var quoted = false
        let characters = Array(line)
        var i = 0
        while i < characters.count {
            let char = characters[i]
            if char == "\"" {
                if quoted, i + 1 < characters.count, characters[i + 1] == "\"" {
                    current.append("\"")
                    i += 1
                } else {
                    quoted.toggle()
                }
            } else if (char == "," || char == "，" || char == "\t") && !quoted {
                cells.append(current.jsTrimmed)
                current = ""
            } else {
                current.append(char)
            }
            i += 1
        }
        cells.append(current.jsTrimmed)
        if index == 0, Rx.test("^(软件名|名称|name)$", cells[0], "i") { continue }
        if cells[0].isEmpty { continue }
        let countText = cells.count > 1 ? cells[1] : ""
        let count = Int(Rx.match("^[+-]?[0-9]+", countText.jsTrimmed)?[0] ?? "")
        // 旧格式第 4 列是代码来源路径：现在代码来源统一在设置里，路径就不当补充说明用了
        let fourth = cells.count > 3 ? cells[3] : ""
        let notes = !fourth.isEmpty && !Rx.test("^[/~]", fourth) ? fourth : ""
        rows.append(BatchRow(softwareName: cells[0], screenCount: count.flatMap { $0 > 0 ? $0 : nil }, emphasis: cells.count > 2 ? cells[2] : "", notes: notes))
    }
    return rows
}
