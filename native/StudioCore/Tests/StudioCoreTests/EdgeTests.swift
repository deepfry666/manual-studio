import Foundation
import Testing
@testable import StudioCore

/// 一个按脚本回复的假服务。handler(请求, 请求体, 第几次) → 响应
final class ScriptedServer: MockHost, @unchecked Sendable {
    struct Call: Sendable {
        let path: String
        let method: String
        let body: JSON?
    }

    let handler: @Sendable (HTTPRequest, JSON?, Int) -> HTTPResponse
    let calls = Locked<[Call]>([])
    var host = ""
    var url: String { "http://\(host)" }

    init(network: MockNetwork, handler: @escaping @Sendable (HTTPRequest, JSON?, Int) -> HTTPResponse) {
        self.handler = handler
        host = network.register(self)
    }

    func handle(_ request: HTTPRequest, path: String) async throws -> HTTPResponse {
        let body = request.bodyJSON
        let index = calls.withLock { list -> Int in list.append(Call(path: path, method: request.method, body: body)); return list.count - 1 }
        return handler(request, body, index)
    }
}

func chatReply(_ content: String) -> HTTPResponse { jsonResponse(200, ["choices": [["message": ["content": .string(content)]]]]) }
func vendor(_ url: String, preset: String = "custom") -> LlmVendor { LlmVendor(id: "v", name: "测试", preset: preset, baseUrl: url) }
func syncProvider(_ url: String) -> ImageProvider {
    var provider = newProviderFromPreset("openai-sync", id: "p", name: "p")
    provider.baseUrl = url
    provider.model = "m"
    return provider
}
let noDelay: @Sendable (Double) async throws -> Void = { _ in }

@Suite("边界情况", .serialized)
struct EdgeTests {
    @Test("大模型输出带 <think> 和 ```json 代码块也能解析")
    func extract() throws {
        #expect(try extractJson("<think>先想一想</think>\n好的：\n```json\n{\"a\":1}\n```") == ["a": 1])
        #expect(try extractJson(#"结果如下 {"a":{"b":[1,2]}} 以上"#) == ["a": ["b": [1, 2]]])
        #expect(throws: LlmError.self) { try extractJson("完全不是 JSON") }
    }

    @Test("大模型第一次输出不合格，带着错误让它修正后通过")
    func repair() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, index in index == 0 ? chatReply(#"{"name": 1}"#) : chatReply(#"{"name": "ok"}"#) }
        let result = try await chatJson(vendor: vendor(server.url), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u", schema: ["type": "object", "required": ["name"], "properties": ["name": ["type": "string"]]]), http: network, retryDelay: noDelay)
        #expect(result["name"]?.string == "ok")
        #expect(server.calls.current[1].body?["messages"]?.array?.last?.serialized().contains("不符合要求") == true)
    }

    @Test("厂商不支持 JSON 模式、输出上限更小时自动降级重试")
    func downgrade() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, body, _ in
            if (body?["max_tokens"]?.number ?? 0) > 8192 { return jsonResponse(400, ["error": ["message": "Invalid max_tokens value, the valid range of max_tokens is [1, 8192]"]]) }
            if body?["response_format"] != nil { return jsonResponse(400, ["error": ["message": "1210 API 调用参数有误"]]) }
            return chatReply(#"{"ok":true}"#)
        }
        let result = try await chatJson(vendor: vendor(server.url), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u", maxTokens: 12000), http: network, retryDelay: noDelay)
        #expect(result["ok"]?.bool == true)
        let last = server.calls.current.last!.body!
        #expect(last["max_tokens"]?.int == 8192)
        #expect(last["response_format"] == nil)
    }

    @Test("智谱看图请求发不带前缀的 base64，其他厂商发 data URL")
    func zhipuImages() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, _ in chatReply(#"{"ok":true}"#) }
        _ = try await chatJson(vendor: vendor(server.url, preset: "zhipu"), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u", images: ["data:image/jpeg;base64,QUJD"]), http: network)
        _ = try await chatJson(vendor: vendor(server.url), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u", images: ["data:image/jpeg;base64,QUJD"]), http: network)
        #expect(server.calls.current[0].body?["messages"]?[1]?["content"]?[1]?["image_url"]?["url"]?.string == "QUJD")
        #expect(server.calls.current[1].body?["messages"]?[1]?["content"]?[1]?["image_url"]?["url"]?.string == "data:image/jpeg;base64,QUJD")
    }

    @Test("中转站返回网页（502）时报错是一句人话")
    func htmlError() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, _ in
            HTTPResponse(status: 502, headers: ["content-type": "text/html"], body: Data("<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head><body>cloudflare</body></html>".utf8))
        }
        do {
            _ = try await runAttempt(provider: syncProvider(server.url), apiKey: "k", prompt: "p", size: "864x1824", http: network)
            Issue.record("应该失败")
        } catch let error as ProviderError {
            #expect(error.kind == "server")
            #expect(Rx.test("返回了网页.*502 Bad Gateway", error.message))
        }
    }

    @Test("HTTP 200 里装着额度错误：按额度处理（会触发冷却）")
    func quotaIn200() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, _ in jsonResponse(200, ["error": ["message": "insufficient_quota: 余额不足"]]) }
        do {
            _ = try await runAttempt(provider: syncProvider(server.url), apiKey: "k", prompt: "p", size: "864x1824", http: network)
            Issue.record("应该失败")
        } catch let error as ProviderError {
            #expect(error.kind == "quota")
        }
    }

    @Test("b64_json 带 data: 前缀也能解码")
    func dataPrefix() async throws {
        let network = MockNetwork()
        let png = makePng(216, 456)
        let server = ScriptedServer(network: network) { _, _, _ in jsonResponse(200, ["data": [["b64_json": .string("data:image/png;base64,\(png.base64EncodedString())")]]]) }
        let result = try await runAttempt(provider: syncProvider(server.url), apiKey: "k", prompt: "p", size: "864x1824", http: network)
        #expect(result.bytes == png)
    }

    @Test("查询异步任务返回 404：算这次任务失败，不把线路判成配置错误")
    func asyncNotFound() async throws {
        pollingIntervalOverride.withLock { $0 = 20 }
        defer { pollingIntervalOverride.withLock { $0 = nil } }
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { request, _, _ in
            request.method == "POST" ? jsonResponse(200, ["data": [["task_id": "a/b"]]]) : jsonResponse(404, ["error": ["message": "task not found"]])
        }
        var provider = newProviderFromPreset("apimart-async", id: "p", name: "p")
        provider.baseUrl = server.url
        provider.model = "m"
        do {
            _ = try await runAttempt(provider: provider, apiKey: "k", prompt: "p", size: "1:2", http: network)
            Issue.record("应该失败")
        } catch let error as ProviderError {
            #expect(error.kind == "task-failed")
        }
        #expect(server.calls.current[1].path.contains("/tasks/a%2Fb"), "任务号经过转义")
    }

    @Test("中转站返回 JPEG 时转成 PNG 再验收")
    func jpeg() async throws {
        let dir = try FS.makeTempDirectory(prefix: "jpeg-")
        try FS.write(Path.join(dir, "a.png"), makePng(216, 456))
        _ = try await runProcess("/usr/bin/sips", ["-s", "format", "jpeg", Path.join(dir, "a.png"), "--out", Path.join(dir, "a.jpg")])
        let jpeg = try FS.read(Path.join(dir, "a.jpg"))
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, _ in jsonResponse(200, ["data": [["b64_json": .string(jpeg.base64EncodedString())]]]) }
        let result = try await runAttempt(provider: syncProvider(server.url), apiKey: "k", prompt: "p", size: "864x1824", http: network)
        let check = checkScreenImage(result.bytes)
        #expect(check.ok, "\(check.reason ?? "")")
        #expect(check.png.map { String(decoding: $0[1..<4], as: UTF8.self) } == "PNG")
    }

    @Test("批量新建列表：每行一个软件名，也可以带逗号分隔的列（表头、中文逗号、引号、制表符、空行、非法屏数）")
    func batchList() {
        let rows = parseBatchList("\u{FEFF}软件名,截图数,重点功能\n\"云伴日程, 专业版 V1.0\",7,日程提醒\n\n快记账本 V1.0，abc，预算\n办公助手 V2\t5\t审批\t/Users/x/code\n只有名字 V3.1\n")
        #expect(rows.count == 4)
        #expect(rows[0] == BatchRow(softwareName: "云伴日程, 专业版 V1.0", screenCount: 7, emphasis: "日程提醒", notes: ""))
        #expect(rows[1].screenCount == nil)
        #expect(rows[1].emphasis == "预算")
        // 旧格式第 4 列的代码来源路径不再使用（代码来源统一在设置里），也不会被当成补充说明
        #expect(rows[2].notes == "")
        #expect(rows[3] == BatchRow(softwareName: "只有名字 V3.1", screenCount: nil, emphasis: "", notes: ""))
    }

    @Test("代码来源：跳过二进制和排除目录，去掉 BOM，统一换行，按路径排序")
    func codeSource() throws {
        let dir = try FS.makeTempDirectory(prefix: "code-")
        try FS.write(Path.join(dir, "src", "b", "Z.java"), "\u{FEFF}class Z {}\r\n")
        try FS.write(Path.join(dir, "src", "A.java"), "class A {}")
        try FS.write(Path.join(dir, "src", "Bin.java"), Data([0x63, 0x00, 0x01]))
        try FS.write(Path.join(dir, "build", "Gen.java"), "class Gen {}")
        let result = try collectCodeSource(path: dir, extensions: ["java"], excludeDirs: ["build"])
        #expect(result.files == ["src/A.java", "src/b/Z.java"])
        #expect(result.body == "class A {}\nclass Z {}\n")
        #expect(result.lineCount == 2)
        #expect(result.warnings.count == 1)
        #expect(try collectCodeSource(path: Path.join(dir, "src", "A.java"), extensions: [".java"]).fileCount == 1)
        #expect(throws: StudioError.self) { try collectCodeSource(path: Path.join(dir, "nope"), extensions: []) }
        #expect(throws: StudioError.self) { try collectCodeSource(path: dir, extensions: [".kt"]) }
    }

    @Test("软件名非法字符、重复建项目都会被拦下")
    func names() async throws {
        let ctx = try await CoreContext()
        for (name, message) in [("a/b V1.0", "不能包含"), (".隐藏 V1.0", "以点开头"), ("   ", "为空")] {
            do {
                _ = try await ctx.create(name)
                Issue.record("应该失败：\(name)")
            } catch {
                #expect(messageOf(error).contains(message))
            }
        }
        let dir = try await ctx.create("车辆投屏（Android 端）V1.0")
        #expect(FS.exists(dir))
        do {
            _ = try await ctx.create("车辆投屏（Android 端）V1.0")
            Issue.record("应该失败")
        } catch {
            #expect(messageOf(error).contains("已经有"))
        }
    }

    @Test("没有看图模型：截图等人工确认，全部确认后继续到交付包", .timeLimit(.minutes(2)))
    func manualGate() async throws {
        let ctx = try await CoreContext(withVision: false, relayBehavior: { _, _ in RelayPlan(delayMs: 60) })
        let dir = try await ctx.create("人工确认 V1.0", screenCount: 2)
        let first = await ctx.run(dir)
        #expect(first.status == "waiting")
        #expect(first.step == "gate")
        for id in ["screen-01", "screen-02"] { try await ctx.core.pipeline.manualGate(dir, id, true) }
        let second = await ctx.run(dir)
        let project = try await ctx.project(dir)
        #expect(second.status == "done", "\(project["state"]?["lastError"] ?? .null)")
        #expect(project["state"]?["warnings"].items.contains { $0.jsString.contains("文案未按截图对账") } == true)
    }

    @Test("中途取消后再运行：只补生成缺的截图，不重复购买", .timeLimit(.minutes(2)))
    func cancelThenResume() async throws {
        let ctx = try await CoreContext(relayBehavior: { index, _ in RelayPlan(delayMs: index < 2 ? 50 : 1500) })
        let dir = try await ctx.create("取消测试 V1.0", screenCount: 4)
        let running = ctx.core.run(dir)
        try await Task.sleep(nanoseconds: 900_000_000)
        ctx.core.cancel(dir)
        let canceled = await running.value
        #expect(canceled.status == "canceled")
        let made = (FS.list(Path.join(dir, "screens")) ?? []).filter { $0.hasSuffix(".png") }
        #expect(made.count >= 1 && made.count < 4, "取消前生成了 \(made.count) 张")
        let submitsBefore = ctx.relay.submits.count
        #expect(await ctx.run(dir).status == "done")
        #expect(ctx.relay.submits.count - submitsBefore == 4 - made.count, "只补缺的")
    }

    @Test("只读的历史项目不能运行")
    func readOnly() async throws {
        let ctx = try await CoreContext()
        let dir = Path.join(ctx.workspace, "只读项目 V1.0")
        try FS.write(Path.join(dir, "只读项目 V1.0", "只读项目 V1.0指南.docx"), "x")
        let scan = try await ctx.core.scanWorkspace()
        #expect(scan.first?["grade"]?.string == "readonly")
        _ = try await ctx.core.importProjects([dir])
        let result = await ctx.run(dir)
        #expect(result.status == "failed")
        #expect(result.error?.contains("只读") == true)
        #expect(ctx.llm.calls.current.isEmpty)
    }

    @Test("批量：暂停、继续、软件重启后自动续跑", .timeLimit(.minutes(2)))
    func batchPauseResume() async throws {
        let ctx = try await CoreContext(relayBehavior: { _, _ in RelayPlan(delayMs: 300) }, fileSecrets: true)
        try await ctx.core.updateSettings(["pipeline": ["batchConcurrency": 1]])
        let a = try await ctx.create("批量甲 V1.0", screenCount: 2)
        let b = try await ctx.create("批量乙 V1.0", screenCount: 2)
        await ctx.core.batch.initialize()
        await ctx.core.batch.enqueue([a, b])
        try await Task.sleep(nanoseconds: 150_000_000)
        await ctx.core.batch.pause()
        try await Task.sleep(nanoseconds: 600_000_000)
        var list = ctx.core.batch.list()
        #expect(list.items.allSatisfy { $0["status"]?.string != "running" }, "\(list.items.map { $0["status"] ?? .null })")
        // 模拟软件重启：用同一个数据目录建新的 core
        let core2 = try await StudioCore(dataDir: ctx.dataDir, secrets: FileSecrets(dataDir: ctx.dataDir, cipher: Base64Cipher()), http: ctx.network)
        await core2.batch.initialize()
        await core2.batch.resume()
        for _ in 0..<150 {
            list = core2.batch.list()
            if list.items.allSatisfy({ $0["status"]?.string == "done" }) { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(list.items.map { $0["status"]?.string ?? "" } == ["done", "done"])
    }

    @Test("批量里失败的项目，之后手动跑完或重启时已完成，记录改成完成", .timeLimit(.minutes(2)))
    func batchSettle() async throws {
        let ctx = try await CoreContext(fileSecrets: true)
        let dir = try await ctx.create("批量失败 V1.0", screenCount: 2)
        let failedQueue: JSON = .obj(["items": [.obj(["id": "x1", "projectDir": .string(dir), "batchId": "batch-1", "batchName": "", "status": "failed", "error": "模型输出不符合格式"])], "paused": false])
        try FS.writeJSONAtomic(Path.join(ctx.dataDir, "batch-queue.json"), failedQueue)
        let core2 = try await StudioCore(dataDir: ctx.dataDir, secrets: FileSecrets(dataDir: ctx.dataDir, cipher: Base64Cipher()), http: ctx.network)
        #expect(core2.batch.list().items.first?["status"]?.string == "failed")
        let result = await core2.run(dir).value
        #expect(result.status == "done")
        var status = ""
        for _ in 0..<50 {
            status = core2.batch.list().items.first?["status"]?.string ?? ""
            if status == "done" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(status == "done")

        // 重启时：项目已经是完成状态，失败记录直接改成完成
        try FS.writeJSONAtomic(Path.join(ctx.dataDir, "batch-queue.json"), failedQueue)
        let core3 = try await StudioCore(dataDir: ctx.dataDir, secrets: FileSecrets(dataDir: ctx.dataDir, cipher: Base64Cipher()), http: ctx.network)
        await core3.start()
        #expect(core3.batch.list().items.first?["status"]?.string == "done")
    }

    @Test("忽略 PDF 字体提示：不再标红，记日志，不碰别的字段")
    func ignorePdfFonts() async throws {
        let ctx = try await CoreContext()
        let dir = try await ctx.create("字体忽略 V1.0", screenCount: 2)
        _ = try await ctx.core.pipeline.update(dir) { draft in
            draft["lastBuild"] = .obj(["at": "x", "pdfFonts": .obj(["guide": .obj(["ok": false, "intended": "苹方-简", "fonts": ["HiraMinProN-W3", "PingFangSC-Regular"]]), "code": .obj(["ok": true, "intended": "华文宋体"])]), "warnings": ["说明书 PDF 字体不对：应为「苹方-简」", "指南 PDF 有 9 页"]])
        }
        #expect(try await ctx.core.listProjects().first { $0["dir"]?.string == dir }?["pdfFontProblem"] == .bool(true))
        try await ctx.core.pipeline.ignorePdfFontWarning(dir)
        let state = try #require(try ctx.core.pipeline.projectStore.read(dir))
        #expect(state["lastBuild"]?["pdfFonts"]?["guide"]?["ignored"] == .bool(true))
        #expect(state["lastBuild"]?["pdfFonts"]?["code"]?["ignored"] == nil)
        #expect(state["lastBuild"]?["warnings"].items.map(\.jsString) == ["指南 PDF 有 9 页"])
        #expect(state["log"].items.last?["message"]?.string?.contains("已忽略 PDF 字体提示（说明书）") == true)
        #expect(try await ctx.core.listProjects().first { $0["dir"]?.string == dir }?["pdfFontProblem"] == .bool(false))
    }

    @Test("从列表移除：可选把项目文件夹移到废纸篓；不能删工作区这类上层文件夹")
    func removeWithFolder() async throws {
        let ctx = try await CoreContext()
        let keep = try await ctx.create("只移除 V1.0", screenCount: 2)
        let drop = try await ctx.create("连文件夹 V1.0", screenCount: 2)
        try await ctx.core.removeFromList(keep)
        #expect(FS.exists(keep), "只从列表移除不动文件夹")
        try await ctx.core.removeFromList(drop, deleteFolder: true)
        #expect(ctx.trashed.current == [Path.resolve(drop)])
        #expect(!FS.exists(drop))
        let left = try await ctx.core.listProjects().compactMap { $0["dir"]?.string }
        #expect(!left.contains(keep) && !left.contains(drop))
        await #expect(throws: StudioError.self) { try await ctx.core.removeFromList(ctx.workspace, deleteFolder: true) }
        #expect(FS.exists(ctx.workspace))
    }

    @Test("批次：批量新建记下批次；以前的按 1 秒内连续新建推断；导入的不分批")
    func batchesGrouping() async throws {
        let entries: [JSON] = [
            .obj(["dir": "/w/a", "addedAt": "2026-10-10T08:01:16.209Z", "origin": "created"]),
            .obj(["dir": "/w/b", "addedAt": "2026-10-10T08:01:16.213Z", "origin": "created"]),
            .obj(["dir": "/w/c", "addedAt": "2026-10-10T08:01:16.900Z", "origin": "created"]),
            .obj(["dir": "/w/single", "addedAt": "2026-10-10T09:00:00.000Z", "origin": "created"]),
            .obj(["dir": "/w/i1", "addedAt": "2026-10-09T09:15:29.765Z", "origin": "imported"]),
            .obj(["dir": "/w/i2", "addedAt": "2026-10-09T09:15:29.778Z", "origin": "imported"]),
            .obj(["dir": "/w/x", "addedAt": "2026-10-10T10:00:00.000Z", "origin": "created", "batchId": "batch-1"]),
            .obj(["dir": "/w/y", "addedAt": "2026-10-10T10:05:00.000Z", "origin": "created", "batchId": "batch-1"]),
        ]
        let batches = projectBatches(entries)
        #expect(batches["/w/a"]?["count"]?.int == 3 && batches["/w/a"]?["id"] == batches["/w/c"]?["id"])
        #expect(batches["/w/single"] == nil && batches["/w/i1"] == nil)
        #expect(batches["/w/x"]?["id"]?.string == "batch-1" && batches["/w/y"]?["count"]?.int == 2)

        let ctx = try await CoreContext()
        let result = try await ctx.core.createProjectsFromList("批次甲 V1.0\n批次乙 V1.0\n批次丙 V1.0", screenCount: 2, platform: "iPhone", wantDesign: false)
        let listed = try await ctx.core.listProjects().filter { result.created.contains($0["dir"]?.string ?? "") }
        #expect(listed.count == 3)
        #expect(Set(listed.compactMap { $0["batch"]?["id"]?.string }).count == 1)
        #expect(listed.first?["batch"]?["id"]?.string?.hasPrefix("batch-") == true)
    }

    @Test("同时处理项目设为不限（0）：队列里的项目全部同时开跑", .timeLimit(.minutes(2)))
    func batchUnlimited() async throws {
        let ctx = try await CoreContext(relayBehavior: { _, _ in RelayPlan(delayMs: 600) })
        try await ctx.core.updateSettings(["pipeline": ["batchConcurrency": 0], "image": ["globalConcurrency": 0]])
        var dirs: [String] = []
        for index in 1...4 { dirs.append(try await ctx.create("不限并发\(index) V1.0", screenCount: 2)) }
        await ctx.core.batch.enqueue(dirs)
        var maxRunning = 0
        for _ in 0..<150 {
            let items = ctx.core.batch.list().items
            maxRunning = max(maxRunning, items.filter { $0["status"]?.string == "running" }.count)
            if items.allSatisfy({ $0["status"]?.string == "done" }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(maxRunning == 4)
        #expect(ctx.core.batch.list().items.allSatisfy { $0["status"]?.string == "done" })
    }

    @Test("截图编号不合法会被拒绝；项目运行中不能修改", .timeLimit(.minutes(2)))
    func safety() async throws {
        let ctx = try await CoreContext(relayBehavior: { _, _ in RelayPlan(delayMs: 800) })
        let dir = try await ctx.create("安全测试 V1.0", screenCount: 2)
        await #expect(throws: StudioError.self) { try await ctx.core.pipeline.savePrompt(dir, "../../evil", "x") }
        await #expect(throws: StudioError.self) { try await ctx.core.pipeline.manualGate(dir, "screen-1", true) }
        let running = ctx.core.run(dir)
        try await Task.sleep(nanoseconds: 300_000_000)
        do {
            _ = try await ctx.core.pipeline.updateRequest(dir, ["emphasis": "x"])
            Issue.record("应该失败")
        } catch {
            #expect(messageOf(error).contains("正在运行"))
        }
        await #expect(throws: StudioError.self) { try await ctx.core.pipeline.savePrompt(dir, "screen-01", "x") }
        #expect(await running.value.status == "done")
        #expect(!FS.exists(Path.join(dir, "..", "..", "evil.md")))
    }

    @Test("历史回执字段顺序不同、多了字段：内容一致就不重写 content.json", .timeLimit(.minutes(2)))
    func receiptKept() async throws {
        let ctx = try await CoreContext(relayBehavior: { _, _ in RelayPlan(delayMs: 60) })
        let dir = try await ctx.create("回执测试 V1.0", screenCount: 2)
        #expect(await ctx.run(dir).status == "done")
        let file = Path.join(dir, "content.json")
        var content = try readJSONFile(file)
        let reviewed: [JSON] = content["screenshotReview"]?["reviewedScreens"].items.map { .obj(["sha256": $0["sha256"], "image": $0["image"], "screenId": $0["screenId"], "note": "人工"]) } ?? []
        content["screenshotReview"] = .obj(["reviewedAt": "2026-09-01", "reviewedScreens": .array(reviewed), "status": "passed"])
        try FS.writeJSONAtomic(file, content)
        try await ctx.core.pipeline.updateRequest(dir, ["compileDate": "2026年10月4日"])
        #expect(await ctx.run(dir).status == "done")
        #expect(try readJSONFile(file)["screenshotReview"]?["reviewedAt"]?.string == "2026-09-01", "回执原样保留")
    }

    @Test("缺标准提示词的历史项目：检查更新不写文件，重生某一屏时才补写这一屏的提示词", .timeLimit(.minutes(2)))
    func missingPrompts() async throws {
        let ctx = try await CoreContext(relayBehavior: { _, _ in RelayPlan(delayMs: 60) })
        let dir = try await ctx.create("旧项目 V1.0", screenCount: 2)
        #expect(await ctx.run(dir).status == "done")
        // 变成「旧 skill 做的历史项目」：没有本软件的状态，提示词是非标准文件名
        try await ctx.core.removeFromList(dir)
        FS.remove(Path.join(dir, "generation-record.json"))
        try FS.move(Path.join(dir, "prompts", "screen-01.md"), Path.join(dir, "prompts", "screen-01-login.md"))
        FS.remove(Path.join(dir, "prompts", "screen-02.md"))
        _ = try await ctx.core.importProjects([dir])
        let files = { (FS.list(Path.join(dir, "prompts")) ?? []).sorted().joined(separator: ",") }
        let before = files()
        #expect(await ctx.run(dir).status == "done")
        #expect(files() == before, "检查更新不补写提示词")
        let submits = ctx.relay.submits.count
        try await ctx.core.pipeline.updateRequest(dir, ["allowDropCodeDoc": true])
        _ = await (try ctx.core.pipeline.regenerateScreen(dir, "screen-02")).value
        #expect(ctx.relay.submits.count == submits + 1)
        #expect(FS.exists(Path.join(dir, "prompts", "screen-02.md")), "重生时补写了这一屏")
        #expect(!FS.exists(Path.join(dir, "prompts", "screen-01.md")), "没动其他屏")
        #expect(try FS.readText(Path.join(dir, "prompts", "screen-02.md")).contains("Do NOT render the software name"))
    }

    @Test("设置里的数值被存成空值时自动换回默认值")
    func settingsSanitize() async throws {
        let dir = try FS.makeTempDirectory(prefix: "settings-")
        try FS.write(Path.join(dir, "settings.json"), #"{"image":{"globalConcurrency":null,"hedge":{"minSec":"x"}},"pipeline":{"batchConcurrency":5}}"#)
        let store = SettingsStore(dataDir: dir)
        let settings = try await store.get()
        #expect(settings.image.globalConcurrency == 10)
        #expect(settings.image.hedge.minSec == 20)
        #expect(settings.pipeline.batchConcurrency == 5)
        let next = try await store.update(patch: ["image": ["maxAttemptsPerScreen": nil]])
        #expect(next.image.maxAttemptsPerScreen == 4)
    }

    @Test("从 Electron 版迁移：safeStorage 密文能解出来")
    func safeStorage() throws {
        // 用 Chromium 的算法加密一段文字（口令 "peanuts"），再用迁移代码解开
        let storage = ElectronSafeStorage(password: Data("peanuts".utf8))
        let key = storage.derivedKey()
        #expect(key.count == 16)
        #expect(key.map { String(format: "%02x", $0) }.joined() == "d9a09d499b4e1b7461f28e67972c6dbd")
        // Node 按 Chromium 的算法加密出来的密文
        #expect(try storage.decrypt("djEw46U7EtyL9akDthLtnN0S8A==") == "sk-node-加密")
        let encrypted = try chromiumEncrypt("sk-hello-密钥", key: key)
        #expect(try storage.decrypt(encrypted) == "sk-hello-密钥")
    }
}

import CommonCrypto

func chromiumEncrypt(_ text: String, key: Data) throws -> String {
    let input = Data(text.utf8)
    let iv = Data(repeating: 0x20, count: 16)
    var output = Data(count: input.count + kCCBlockSizeAES128)
    var written = 0
    let capacity = output.count
    let status = output.withUnsafeMutableBytes { out in
        input.withUnsafeBytes { inBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress, inBytes.baseAddress, input.count, out.baseAddress, capacity, &written)
                }
            }
        }
    }
    guard status == kCCSuccess else { throw StudioError("加密失败") }
    return (Data("v10".utf8) + output.prefix(written)).base64EncodedString()
}
