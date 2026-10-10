import Foundation

public let RECORD_FILE = "generation-record.json"
let MAX_HISTORY = 500
private let recordQueues = Locked<[String: SerialQueue]>([:])

private func recordQueue(_ dir: String) -> SerialQueue {
    recordQueues.withLock { table in
        if let existing = table[dir] { return existing }
        let created = SerialQueue()
        table[dir] = created
        return created
    }
}

public func recordPath(_ projectDir: String) -> String { Path.join(projectDir, RECORD_FILE) }

/// 项目文件夹里的生成记录（溯源用）：每张截图由哪条线路、哪个模型、什么时候生成，
/// 验收用了什么方式，各步骤用了哪个大模型，以及按时间顺序的事件。
/// 只在本软件真的生成或修改了东西时才写，导入历史项目不会写。
@discardableResult
public func updateRecord(_ projectDir: String, _ mutate: @escaping @Sendable (inout JSON) -> Void) async throws -> JSON {
    try await recordQueue(projectDir).run {
        let file = recordPath(projectDir)
        var record = FS.readJSONQuiet(file).flatMap { $0.isObject ? $0 : nil }
            ?? ["generatedBy": "软件指南生成器", "screens": .emptyObject, "gate": .emptyObject, "llm": .emptyObject, "history": []]
        for key in ["screens", "gate", "llm"] where !(record[key]?.truthy ?? false) { record[key] = .emptyObject }
        if !(record["history"]?.truthy ?? false) { record["history"] = [] }
        mutate(&record)
        if var history = record["history"]?.array, history.count > MAX_HISTORY {
            history.removeFirst(history.count - MAX_HISTORY)
            record["history"] = .array(history)
        }
        record["updatedAt"] = .string(isoNow())
        try FS.writeJSONAtomic(file, record)
        return record
    }
}

public func readRecord(_ projectDir: String) -> JSON? { FS.readJSONQuiet(recordPath(projectDir)) }

extension JSON {
    /// 往数组字段末尾追加（字段不存在时新建）。
    public mutating func append(_ key: String, _ value: JSON) {
        var array = self[key]?.array ?? []
        array.append(value)
        self[key] = .array(array)
    }
}
