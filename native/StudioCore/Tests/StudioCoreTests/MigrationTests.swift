import Foundation
import Testing
@testable import StudioCore

@Suite("从 Electron 版导入")
struct MigrationTests {
    @Test("设置、项目登记和状态、调用记录合并导入，原文件不动")
    func migrate() async throws {
        let root = try FS.makeTempDirectory(prefix: "migrate-")
        let source = Path.join(root, "electron")
        let target = Path.join(root, "native")
        try FS.write(Path.join(source, "settings.json"), #"{"workspaceDir":"/w","providers":[{"id":"cpa","name":"CPA","preset":"openai-sync","baseUrl":"https://x/v1","model":"m"}],"llm":{"vendors":[{"id":"llm-1","name":"V","preset":"custom","baseUrl":"https://y/v1"}],"assignments":{"plan":{"vendorId":"llm-1","model":"t"}}}}"#)
        try FS.write(Path.join(source, "projects-index.json"), #"{"projects":[{"dir":"/w/A","addedAt":"2026-01-01T00:00:00.000Z","origin":"created"},{"dir":"/w/B","addedAt":"2026-01-02T00:00:00.000Z","origin":"imported"}]}"#)
        try FS.write(Path.join(source, "projects", "\(projectKey("/w/A")).json"), #"{"request":{"softwareName":"A"},"steps":{},"screens":{}}"#)
        try FS.write(Path.join(source, "image-calls.jsonl"), "{\"ts\":\"2026-01-02\",\"providerId\":\"cpa\",\"ok\":true,\"durationMs\":1000}\n{\"ts\":\"2026-01-01\",\"providerId\":\"cpa\",\"ok\":true,\"durationMs\":2000}\n")
        try FS.write(Path.join(source, "step-durations.json"), #"{"plan":[1000,2000]}"#)
        // 原生版已经有一条记录和一个项目
        try FS.write(Path.join(target, "image-calls.jsonl"), "{\"ts\":\"2026-01-03\",\"providerId\":\"b\",\"ok\":true,\"durationMs\":3000}\n")
        try FS.write(Path.join(target, "projects-index.json"), #"{"projects":[{"dir":"/w/B","addedAt":"x","origin":"created"}]}"#)
        let before = try FS.readText(Path.join(source, "settings.json"))

        let secrets = MemorySecrets()
        let summary = try await ElectronMigration.migrate(from: source, to: target, secrets: secrets, readSecrets: false)
        #expect(summary["providers"]?.int == 1)
        #expect(summary["projects"]?.int == 1)
        #expect(summary["states"]?.int == 1)
        #expect(try FS.readText(Path.join(source, "settings.json")) == before, "Electron 版的数据不改")

        let core = try await StudioCore(dataDir: target, secrets: secrets, http: MockNetwork())
        let settings = try await core.getSettings().settings
        #expect(settings.providers.first?.id == "cpa")
        #expect(settings.llm.assignment("plan")?.model == "t")
        #expect(core.callLog.all().map { $0["ts"]?.string ?? "" } == ["2026-01-01", "2026-01-02", "2026-01-03"])
        #expect(core.readIndex()["projects"].items.compactMap { $0["dir"]?.string } == ["/w/B", "/w/A"])
        #expect(try core.projectStore.read("/w/A")?["request"]?["softwareName"]?.string == "A")
        #expect(core.stepEstimates()["plan"] == 2000)
        #expect(!ElectronMigration.isFresh(target))
    }
}
