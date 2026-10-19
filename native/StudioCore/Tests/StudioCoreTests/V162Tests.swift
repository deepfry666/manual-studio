import Foundation
import Testing
@testable import StudioCore

private func truncatedReply(_ content: String) -> HTTPResponse {
    jsonResponse(200, ["choices": [["message": ["content": .string(content)], "finish_reason": "length"]]])
}

@Suite("1.6.2：模型输出不是 JSON 时说清楚原因", .serialized)
struct V162LlmTests {
    @Test("被截断：坏输出不带回去，改成要求写短；三次都截断时报错说明是截断，并记下现场")
    func truncated() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, _ in truncatedReply(#"{"screens": [{"title": "首页", "text": "很长很长"#) }
        do {
            _ = try await chatJson(vendor: vendor(server.url), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u"), http: network, retryDelay: noDelay)
            Issue.record("应该失败")
        } catch let error as LlmError {
            #expect(error.kind == "truncated")
            #expect(error.message.contains("被截断"))
            #expect(error.detail?.contains("结束原因 length") == true)
            #expect(error.detail?.contains("很长很长") == true)
        }
        let second = try #require(server.calls.current[1].body?["messages"]?.array)
        #expect(second.count == 3, "截断后重试不带回坏输出，只多一句要求")
        #expect(second.last?.serialized().contains("写得更精简") == true)
    }

    @Test("截断一次、第二次写短了就通过")
    func truncatedThenOk() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, index in index == 0 ? truncatedReply(#"{"a": "#) : chatReply(#"{"a": 1}"#) }
        let result = try await chatJson(vendor: vendor(server.url), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u"), http: network, retryDelay: noDelay)
        #expect(result["a"]?.int == 1)
    }

    @Test("回的是一段话：报错带上它回的开头，提示线路可能不支持 JSON")
    func notJson() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, _ in chatReply("抱歉，我无法按要求输出。") }
        do {
            _ = try await chatJson(vendor: vendor(server.url), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u"), http: network, retryDelay: noDelay)
            Issue.record("应该失败")
        } catch let error as LlmError {
            #expect(error.kind == "bad-json")
            #expect(error.message.contains("抱歉，我无法按要求输出"))
            #expect(error.detail?.contains("不是有效的 JSON") == true)
        }
        #expect(server.calls.current.count == 3)
    }

    @Test("线路额度不够：直接说明，不重试")
    func billing() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, _ in jsonResponse(400, ["error": ["message": "You have insufficient credits to make this request. Please purchase more credits to continue using the service."]]) }
        do {
            _ = try await chatJson(vendor: vendor(server.url), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u"), http: network, retryDelay: noDelay)
            Issue.record("应该失败")
        } catch let error as LlmError {
            #expect(error.kind == "billing")
            #expect(error.message.hasPrefix("线路额度不够"))
        }
        #expect(server.calls.current.count == 1, "额度不够重试也没用")
    }
}

@Suite("1.6.2：按名单批量处理", .serialized)
struct V162BatchTests {
    func waitQueue(_ ctx: CoreContext, _ count: Int) async throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let items = ctx.core.batch.list().items
            if items.count >= count, items.allSatisfy({ ["done", "failed", "needs-attention"].contains($0["status"]?.string ?? "") }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("只重写文字不出图；全部重做重新规划、出图；已提交的被拦下", .timeLimit(.minutes(3)))
    func modes() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let dir = try await ctx.create("名单测试 V1.0", screenCount: 2)
        #expect(await ctx.run(dir).status == "done")
        let images = ctx.relay.submits.count
        let contentCalls = ctx.llm.calls.current.filter { $0.step == "content" }.count
        let planCalls = ctx.llm.calls.current.filter { $0.step == "plan" }.count

        await ctx.core.batch.enqueue([dir], name: "名单：只重写文字", mode: "rewrite")
        try await waitQueue(ctx, 1)
        #expect(ctx.core.batch.list().items.last?["status"]?.string == "done", "\(ctx.core.batch.list().items)")
        #expect(ctx.relay.submits.count == images, "只重写文字不出图")
        #expect(ctx.llm.calls.current.filter { $0.step == "content" }.count > contentCalls, "说明重写了")
        #expect(ctx.llm.calls.current.filter { $0.step == "plan" }.count == planCalls, "不重新规划")

        await ctx.core.batch.enqueue([dir], name: "名单：全部重做", mode: "redo")
        try await waitQueue(ctx, 2)
        #expect(ctx.core.batch.list().items.last?["status"]?.string == "done", "\(ctx.core.batch.list().items)")
        #expect(ctx.llm.calls.current.filter { $0.step == "plan" }.count > planCalls, "重新规划了")
        #expect(ctx.relay.submits.count > images, "重新出图了")

        _ = try await ctx.core.setSubmitted([dir], true)
        await ctx.core.batch.enqueue([dir], name: "名单：全部重做", mode: "redo")
        try await waitQueue(ctx, 3)
        let last = ctx.core.batch.list().items.last
        #expect(last?["status"]?.string == "failed")
        #expect(last?["error"]?.string?.contains("已提交") == true)
    }
}

@Suite("1.6.3：线路回空正文时说清楚空在哪")
struct V163EmptyTests {
    @Test("正文空、推理里有东西并且到上限：说明额度用在推理上了")
    func reasoningTruncated() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, _ in
            jsonResponse(200, ["choices": [["message": ["content": "", "reasoning_content": "我先想想怎么规划这几个界面……"], "finish_reason": "length"]], "usage": ["completion_tokens": 300, "completion_tokens_details": ["reasoning_tokens": 300]]])
        }
        do {
            _ = try await chatJson(vendor: vendor(server.url), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u"), http: network, retryDelay: noDelay)
            Issue.record("应该失败")
        } catch let error as LlmError {
            #expect(error.kind == "empty")
            #expect(error.message.contains("推理"))
            #expect(error.detail?.contains("另有推理内容") == true)
        }
    }

    @Test("诊断文字：结束原因、正文、推理、原始返回都写出来")
    func diagnostics() {
        let raw: JSON = ["choices": [["message": ["content": "", "reasoning_content": "思考"], "finish_reason": "stop"]]]
        let result = ChatResult(text: "", usage: nil, raw: raw, finishReason: "stop")
        #expect(result.emptyReason?.contains("推理字段") == true)
        #expect(result.diagnostics.contains("结束原因：stop"))
        #expect(result.diagnostics.contains("推理内容：2 字"))
        #expect(result.diagnostics.contains("原始返回："))
        let nothing = ChatResult(text: "", usage: nil, raw: ["choices": [["message": ["content": ""]]]], finishReason: nil)
        #expect(nothing.emptyReason?.contains("正文和推理都是空的") == true)
        #expect(ChatResult(text: "好的", usage: nil, raw: nil).emptyReason == nil)
    }
}

@Suite("1.6.4：认出多包一层 data 的回包")
struct V164EnvelopeTests {
    @Test("Cline Pass 非流式回包 {data: {choices}} 能正常读出正文和 JSON")
    func wrapped() async throws {
        let network = MockNetwork()
        let server = ScriptedServer(network: network) { _, _, _ in
            jsonResponse(200, ["data": ["choices": [["finish_reason": "stop", "index": 0, "message": ["content": #"{"ok": true}"#, "provider_metadata": ["deepseek": ["choiceIndex": 0]]]]], "usage": ["completion_tokens": 5]]])
        }
        let result = try await chatJson(vendor: vendor(server.url), apiKey: "k", model: "m", request: ChatJsonRequest(system: "s", user: "u"), http: network, retryDelay: noDelay)
        #expect(result["ok"]?.bool == true)
        #expect(server.calls.current.count == 1)
    }

    @Test("包一层的报错也能认出来；标准回包和模型列表不受影响")
    func envelopeRules() {
        #expect(unwrapEnvelope(["data": ["error": ["message": "insufficient credits"]]])?["error"]?["message"]?.string == "insufficient credits")
        let standard: JSON = ["choices": [["message": ["content": "好"]]]]
        #expect(unwrapEnvelope(standard) == standard)
        let models: JSON = ["object": "list", "data": [["id": "m1"]]]
        #expect(unwrapEnvelope(models) == models, "模型列表的 data 是数组，不拆")
    }
}

@Suite("1.6.5：没有 Word 模板的项目更新代码材料时自动分模板", .serialized)
struct V165ReassignTests {
    @Test("纯文字代码来源和没有代码来源的项目，按轮流平均分到模板，照常更新", .timeLimit(.minutes(3)))
    func reassign() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        try await ctx.core.importCodeTemplate(testCodeTemplatePath)
        let second = Path.join(ctx.root, "第二份.docx")
        try FS.write(second, makeTestCodeTemplate(variant: 7))
        _ = try await ctx.core.addCodeTemplates([second])
        let txt = Path.join(ctx.root, "code-body-java.txt")
        try FS.write(txt, (0..<2888).map { "line \($0);" }.joined(separator: "\n"))
        var dirs: [String] = []
        for (index, source) in [JSON.obj(["path": .string(txt), "extensions": [".java"]]), .null].enumerated() {
            let name = "旧项目\(index) V1.0"
            let dir = try await fakeBuiltProject(ctx, name, ["\(name)指南.docx", "\(name)\(CODE_SUFFIX).docx"])
            try FS.write(Path.join(dir, name, "\(name)指南.txt"), "【编程语言】JAVA\r\n【源程序量】2888行\r\n【软件的主要功能】\r\n原来的功能介绍\r\n")
            try await ctx.core.projectStore.update(dir) { state in
                state["request"]?["codeSource"] = source
                state["request"]?["codeSourceLocked"] = true
            }
            dirs.append(dir)
        }
        let result = await ctx.core.applyCodeTemplates(dirs, mode: "keep")
        #expect(result["failed"].items.isEmpty, "\(result.serialized())")
        // 进度：开始时报这批有哪些，每做完一个报一次，最后报结束
        let events = ctx.events.all.filter { ["code-template-batch", "code-template-item"].contains($0["type"]?.string ?? "") }
        #expect(events.first?["phase"]?.string == "start")
        #expect(events.first?["dirs"].items.compactMap(\.string) == dirs)
        #expect(events.filter { $0["type"]?.string == "code-template-item" && $0["status"]?.string == "done" }.compactMap { $0["projectDir"]?.string } == dirs)
        #expect(events.filter { $0["type"]?.string == "code-template-item" }.allSatisfy { $0["reassigned"]?.string?.hasPrefix("模板") == true })
        #expect(events.last?["phase"]?.string == "end")
        #expect(result["done"].items.count == 2)
        #expect(result["done"].items.allSatisfy { $0["reassigned"]?.string?.hasPrefix("模板") == true })
        let library = try await ctx.core.settingsStore.get().codeTemplates
        for dir in dirs {
            let path = try #require(try ctx.core.projectStore.read(dir)?["request"]?["codeSource"]?["path"]?.string)
            #expect(library.entry(forPath: path) != nil, "分到了模板库里的模板")
            let name = Path.basename(dir)
            #expect(countPdfPages(Path.join(dir, name, "\(name)\(CODE_SUFFIX).pdf")) == 60)
            #expect(try FS.readText(Path.join(dir, name, "\(name)指南.txt")).contains("【源程序量】13534行"))
        }
    }
}
