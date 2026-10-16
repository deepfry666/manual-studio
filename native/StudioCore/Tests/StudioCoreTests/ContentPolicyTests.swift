import Foundation
import Testing
@testable import StudioCore

@Suite("内容日期与运行平台", .serialized)
struct ContentPolicyTests {
    @Test("新建默认本地当天，跨 UTC 日界仍正确，日期校验")
    func defaults() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let dir = try await ctx.create("日期默认测试 V1.0", screenCount: 2)
        let state = try #require(try ctx.core.projectStore.read(dir))
        #expect(state["request"]?["contentDate"]?.string == localDateKey())
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-14T17:00:00Z"))
        #expect(localDateKey(instant, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!) == "2026-10-15")
        #expect(validContentDate("2026-10-15"))
        #expect(!validContentDate("2026-02-30"))
        #expect(!validContentDate("2026-2-3"))
        do {
            try await ctx.core.pipeline.updateRequest(dir, ["contentDate": "2026-02-30"])
            Issue.record("无效日期不应保存")
        } catch {}
        #expect(try ctx.core.projectStore.read(dir)?["request"]?["contentDate"] == state["request"]?["contentDate"])
    }

    @Test("公开入口生成、恢复、修改日期后重新生成，检查 TXT 与 Word 实际产物", .timeLimit(.minutes(3)))
    func delivery() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let dir = try await ctx.create("日期验收账本 V1.0", screenCount: 2, extra: ["contentDate": "2026-10-15", "wantDesign": true])
        #expect(await ctx.run(dir).status == "done")
        let restored = ProjectStore(dataDir: ctx.dataDir)
        #expect(try restored.read(dir)?["request"]?["contentDate"]?.string == "2026-10-15")
        let prompt = try FS.readText(Path.join(dir, "prompts/screen-01.md"))
        #expect(prompt.contains("2026-10-15"))
        #expect(prompt.contains("不得自行编造更早的经营记录"))
        let twice = ensureContentDateRule(ensureContentDateRule(prompt, try #require(try restored.read(dir))), try #require(try restored.read(dir)))
        #expect(twice == prompt)
        let edited = ensureContentDateRule(prompt + "\nRevision applied: 蓝色按钮", try #require(try restored.read(dir)))
        #expect(edited.contains("Revision applied: 蓝色按钮"))
        let txtPath = Path.join(dir, "日期验收账本 V1.0", "日期验收账本 V1.0指南.txt")
        let txt = try FS.readText(txtPath)
        #expect(!txt.contains("【该软件的运行平台/操作系统】"))
        #expect(!txt.contains("【运行的硬件环境】"))
        #expect(!txt.contains("Android"))
        let guidePath = Path.join(dir, "日期验收账本 V1.0", "日期验收账本 V1.0指南.docx")
        let word = try ZipReader(FS.read(guidePath))
        #expect(String(decoding: try #require(try word.read("word/document.xml")), as: UTF8.self).contains("2026年10月15日"))
        let baseline = try readJSONFile(Path.join(dir, "content.json"))
        for key in ["overview", "title", "caption", "text", "design"] {
            var bad = baseline
            switch key {
            case "overview": bad["cover"]?["overview"] = "本软件运行环境为 iOS 端。"
            case "design": bad["design"] = ["sections": [["title": "运行环境", "text": "仅支持 iOS"]]]
            default: bad["screens"]?[0]?[key] = .string(key == "text" ? String(repeating: "适用 iOS 端。", count: 50) : "图1 iOS 首页")
            }
            do {
                _ = try validateGuideContent(bad, "日期验收账本 V1.0")
                Issue.record("不应接受未声明平台的指南 \(key)")
            } catch { #expect(messageOf(error).contains("系统或设备字样")) }
        }
        let initialImages = ctx.relay.submits.count
        let initialContent = ctx.llm.steps("content").count
        let initialDesign = ctx.llm.steps("design").count
        try await ctx.core.pipeline.updateRequest(dir, ["contentDate": "2026-10-16"])
        let blockedRewrite = try await ctx.core.pipeline.rewriteContent(dir, ["screen-01"])
        #expect(await blockedRewrite.value.status == "failed")
        #expect(ctx.relay.submits.count == initialImages)
        let blockedImage = try ctx.core.pipeline.regenerateScreen(dir, "screen-01")
        #expect(await blockedImage.value.status == "failed")
        #expect(ctx.relay.submits.count == initialImages)
        #expect(await ctx.run(dir).status == "done")
        #expect(ctx.relay.submits.count == initialImages + 2)
        #expect(ctx.llm.steps("content").count > initialContent)
        #expect(ctx.llm.steps("design").count == initialDesign + 1)
        let updated = try FS.readText(Path.join(dir, "prompts/screen-01.md"))
        #expect(updated.contains("2026-10-16"))
        #expect(!updated.contains("2026-10-15"))
        let content = try readJSONFile(Path.join(dir, "content.json"))
        #expect(content["compileDate"]?.string == "2026年10月16日")
        #expect(content["contentDate"]?.string == "2026-10-16")
        let info = try #require(inspectProject(dir))
        let imported = try createImportedState(dir, info)
        #expect(imported["request"]?["contentDate"]?.string == "2026-10-16")
        #expect(imported["request"]?["compileDate"]?.string == "")
        let manifest = try readJSONFile(Path.join(dir, "project-manifest.json"))
        #expect(manifest["contentDate"]?.string == "2026-10-16")
        #expect(ctx.llm.steps("plan").last?.user.contains("2026-10-16") == true)
    }
}
