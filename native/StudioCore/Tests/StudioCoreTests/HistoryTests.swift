import Foundation
import Testing
@testable import StudioCore

@Suite("改错了能回去", .serialized)
struct HistoryTests {
    @Test("文字：保存前和大模型重写前的旧文字都能找回；连续自动保存只记一份", .timeLimit(.minutes(2)))
    func contentHistoryKept() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let dir = try await ctx.create("历史文字 V1.0", screenCount: 2)
        #expect(await ctx.run(dir).status == "done")
        let original = try readJSONFile(projectPaths(dir).content)["screens"]?[0]?["text"]?.string ?? ""
        let edited1 = original + "补充一句。"
        try await ctx.core.pipeline.saveContent(dir, overview: nil, screens: [["id": "screen-01", "text": .string(edited1)]])
        try await ctx.core.pipeline.saveContent(dir, overview: nil, screens: [["id": "screen-01", "text": .string(edited1 + "再补一句。")]])
        var versions = contentHistory(dir, target: "screen-01")
        #expect(versions.count == 1, "连续保存 3 分钟内只记一份")
        #expect(versions.first?["text"]?.string == original)
        #expect(versions.first?["source"]?.string == "修改前")
        // 大模型重写：被覆盖的人工文字记进历史
        _ = await (try ctx.core.pipeline.rewriteContent(dir, ["screen-01"])).value
        versions = contentHistory(dir, target: "screen-01")
        #expect(versions.first?["source"]?.string == "AI 重写前")
        #expect(versions.first?["text"]?.string == edited1 + "再补一句。")
        let project = try await ctx.project(dir)
        #expect(project["contentHistory"].items.count == versions.count)
    }

    @Test("截图：重新生成后旧图能在「以前的截图」里找到并换回，换回的同时现在那张也留下", .timeLimit(.minutes(2)))
    func screenHistoryRestore() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let dir = try await ctx.create("历史截图 V1.0", screenCount: 1)
        #expect(await ctx.run(dir).status == "done")
        let first = try FS.read(projectPaths(dir).screenFile("screen-01"))
        #expect(await (try ctx.core.pipeline.regenerateScreen(dir, "screen-01")).value.status == "done")
        let second = try FS.read(projectPaths(dir).screenFile("screen-01"))
        let history = screenHistory(dir, "screen-01")
        #expect(history.count == 1)
        let old = try #require(history.first?["file"]?.string)
        #expect(try FS.read(old) == first)
        #expect(history.first?["at"]?.string != nil)
        try await ctx.core.pipeline.restoreScreen(dir, "screen-01", old)
        #expect(try FS.read(projectPaths(dir).screenFile("screen-01")) == first)
        #expect(screenHistory(dir, "screen-01").contains { (try? FS.read($0["file"]!.string!)) == second }, "被换下的那张也能再换回")
        await #expect(throws: StudioError.self) { try await ctx.core.pipeline.restoreScreen(dir, "screen-01", "/etc/hosts") }
        // 换回后重新验收、重建，不会再花钱生图
        let submits = ctx.relay.submits.count
        #expect(await ctx.run(dir).status == "done")
        #expect(ctx.relay.submits.count == submits)
    }

    @Test("交付包在软件外改过：更新前先停下来问；保留不覆盖，覆盖时手改的文件另存", .timeLimit(.minutes(3)))
    func externalEditsGuarded() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let name = "手改保护 V1.0"
        let dir = try await ctx.create(name, screenCount: 1)
        #expect(await ctx.run(dir).status == "done")
        let state = try #require(try ctx.core.projectStore.read(dir))
        #expect(state["lastBuild"]?["bundleHashes"]?.fields.keys.contains("\(name)指南.docx") == true)
        #expect(externallyEditedFiles(dir, state).isEmpty)
        // 模拟在 WPS 里改了 TXT
        let txt = Path.join(projectPaths(dir).bundle(name), "\(name)指南.txt")
        let handEdited = try FS.readText(txt) + "\n我在 WPS 里加的一行"
        try FS.write(txt, handEdited)
        #expect(externallyEditedFiles(dir, try #require(try ctx.core.projectStore.read(dir))) == ["\(name)指南.txt"])
        #expect(try await ctx.project(dir)["externalEdits"] == JSON(["\(name)指南.txt"]))
        // 软件里改了文字，需要重建：停在交付这一步问
        let text = try readJSONFile(projectPaths(dir).content)["screens"]?[0]?["text"]?.string ?? ""
        try await ctx.core.pipeline.saveContent(dir, overview: nil, screens: [["id": "screen-01", "text": .string(text + "软件里改的。")]])
        let waiting = await ctx.run(dir)
        #expect(waiting.status == "waiting")
        #expect(waiting.step == "build")
        #expect(try FS.readText(txt) == handEdited, "没有确认前不覆盖")
        // 保留：交付包不动，下次更新还会再问
        _ = try await ctx.core.pipeline.resolveExternalEdits(dir, overwrite: false)
        #expect(try FS.readText(txt) == handEdited)
        #expect(await ctx.run(dir).status == "waiting")
        // 覆盖：用软件里的内容重建，手改的文件另存到 archive，不受「只留 3 份」清理
        let task = try #require(try await ctx.core.pipeline.resolveExternalEdits(dir, overwrite: true))
        #expect(await task.value.status == "done")
        #expect(try FS.readText(txt) != handEdited)
        let archive = projectPaths(dir).archive
        let kept = try #require((FS.list(archive) ?? []).first { $0.hasPrefix("\(name)-手改保留-") })
        #expect(try FS.readText(Path.join(archive, kept, "\(name)指南.txt")) == handEdited)
        pruneBundleArchives(archive, name, keep: 0)
        #expect(FS.exists(Path.join(archive, kept)))
        let after = try #require(try ctx.core.projectStore.read(dir))
        #expect(externallyEditedFiles(dir, after).isEmpty)
        #expect(after["overwriteExternalEdits"] == nil)
    }

    @Test("编辑页：设计说明直接改并留历史；单屏「改图」不经过意见清单也能执行并核对", .timeLimit(.minutes(2)))
    func editorActions() async throws {
        let ctx = try await CoreContext(relayBehavior: { _, _ in RelayPlan(delayMs: 40) })
        defer { FS.remove(ctx.root) }
        let dir = try await ctx.create("编辑页 V1.0", screenCount: 2, extra: ["wantDesign": true])
        #expect(await ctx.run(dir).status == "done")
        let sections = try readJSONFile(projectPaths(dir).content)["design"]?["sections"].items ?? []
        #expect(sections.count == 5)
        var edited = sections
        edited[0]["text"] = .string("我改过的处理流程说明。" + (sections[0]["text"]?.string ?? ""))
        try await ctx.core.pipeline.saveContent(dir, overview: nil, screens: [], design: edited)
        let saved = try readJSONFile(projectPaths(dir).content)["design"]?["sections"].items ?? []
        #expect(saved[0]["text"]?.string?.hasPrefix("我改过的处理流程说明。") == true)
        #expect(contentHistory(dir, target: "design-1").first?["text"] == sections[0]["text"])
        #expect(try ctx.core.projectStore.read(dir)?["designEdited"] == true)
        // 编辑页的「改图」：单个动作、不带意见编号
        let before = ctx.relay.submits.count
        _ = try await ctx.core.pipeline.applyFeedback(dir, actions: [["type": "image", "target": "screen-02", "targetLabel": "图2", "instruction": "底部按钮改成绿色", "items": []]])
        #expect(await ctx.run(dir).status == "done")
        #expect(ctx.relay.submits.count == before + 1)
        #expect(try FS.readText(Path.join(dir, "prompts", "screen-02.md")).contains("底部按钮改成绿色"))
        #expect(ctx.llm.calls.current.contains { $0.step == "gate" && ($0.body["messages"]?[1]?["content"]?[0]?["text"]?.string ?? "").contains("修改意见：底部按钮改成绿色") })
    }
}
