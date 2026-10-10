import Foundation
import Testing
@testable import StudioCore

let electronDataDir = Path.join(NSHomeDirectory(), "Library", "Application Support", "软件指南生成器")

@Suite("本机 Electron 版数据（只读）")
struct RealDataTests {
    @Test("步骤输入哈希和 Electron 版存下来的一致", .enabled(if: FS.exists(Path.join(electronDataDir, "settings.json"))))
    func inputHashes() async throws {
        let settings = try (FS.readJSON(Path.join(electronDataDir, "settings.json")) ?? .emptyObject).decode(Settings.self)
        let store = ProjectStore(dataDir: electronDataDir)
        let index = FS.readJSONQuiet(Path.join(electronDataDir, "projects-index.json"))?["projects"].items ?? []
        let tmp = try FS.makeTempDirectory(prefix: "realdata-")
        defer { FS.remove(tmp) }
        let pipeline = Pipeline(settingsStore: SettingsStore(dataDir: tmp), secrets: MemorySecrets(), gateway: ImageGateway(getSettings: { settings }, secrets: MemorySecrets(), ledger: Ledger(dataDir: tmp), health: HealthStore(dataDir: tmp), callLog: CallLog(dataDir: tmp), http: MockNetwork()), projectStore: store, llmLog: CallLog(dataDir: tmp, fileName: "llm.jsonl"), http: MockNetwork())
        var checked: [String: Int] = [:]
        var mismatched: [String] = []
        for entry in index {
            let dir = entry["dir"]?.string ?? ""
            guard FS.exists(dir), let state = try store.read(dir) else { continue }
            for step in ["plan", "prompts", "build"] {
                guard state["steps"]?[step]?["status"]?.string == "done", let stored = state["steps"]?[step]?["inputHash"]?.string else { continue }
                let ours = pipeline.stepInputHash(step, dir, state, settings)
                checked[step, default: 0] += 1
                if ours != stored { mismatched.append("\(Path.basename(dir)) \(step)") }
            }
        }
        #expect(checked.values.reduce(0, +) > 0)
        #expect(mismatched.isEmpty, "\(mismatched.prefix(20))")
    }
}
