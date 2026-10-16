import Foundation
import Testing
@testable import StudioCore

/// 看图模型的回答（测试替换某一次验收结果用）。
private func gateReply(_ title: String, _ visibleText: [String], extra: JSON = .emptyObject) -> HTTPResponse {
    let result = JSON.obj([
        "singleScreen": true, "portraitApp": true, "brandFound": false, "brandEvidence": "", "screenTitle": .string(title),
        "visibleText": JSON(visibleText), "inventory": .string("界面标题为「\(title)」，列出几条记录和一个蓝色主按钮，整体布局清楚。"), "warnings": [],
    ]).merging(extra)
    return jsonResponse(200, ["choices": [["message": ["role": "assistant", "content": .string(result.serialized())]]], "usage": ["prompt_tokens": 10, "completion_tokens": 10]])
}

private func dated(_ contentDate: String, earliest: String? = nil) -> JSON {
    .obj(["request": .obj(["contentDate": .string(contentDate), "earliestDate": JSON.maybe(earliest)])])
}

@Suite("日期规则与修改意见", .serialized)
struct DateAndFeedbackTests {
    @Test("认得出常见日期写法；早于最早日期的才算，事实日期和未来安排不算")
    func dateDetection() {
        let base = "2026-10-16", earliest = "2026-09-16"
        func hits(_ text: String, allowed: Set<String> = []) -> [String] { datesBefore([text], earliest: earliest, base: base, allowed: allowed) }
        #expect(hits("到账 2026-08-08") == ["2026-08-08"])
        #expect(hits("到账 2026–08–08").count == 1, "看图模型抄出来的长横线也要认")
        #expect(hits("2026年8月8日缴费") == ["2026年8月8日"])
        #expect(hits("2026-09-28 基础验收").isEmpty)
        #expect(hits("8月8日 门诊") == ["8月8日"])
        #expect(hits("12月1日 预约复诊").isEmpty, "没写年份又晚于内容日期的当作未来安排")
        #expect(hits("2026-08 期 已缴") == ["2026-08"])
        #expect(hits("2026-09 期 已缴").isEmpty, "9 月还有在最早日期之后的日子")
        #expect(hits("08-08 09:30 支出").count == 1)
        #expect(hits("10-12 人小团队").isEmpty)
        #expect(hits("出生日期 1990-05-12").isEmpty)
        #expect(hits("身份证有效期 2020.01.01-2040.01.01").isEmpty)
        #expect(hits("余额 ¥2025.08").isEmpty)
        #expect(hits("到账 2026-08-08", allowed: ["2026-08-08"]).isEmpty, "截图里本来就有的日期，正文照实写不算")
        #expect(hits("2027-03-15 截止").isEmpty)
    }

    @Test("最早日期：填了用填的，不填为内容日期前 30 天；没设内容日期的旧项目不套规则")
    func earliestDate() {
        #expect(earliestDateOf(dated("2026-10-16")) == "2026-09-16")
        #expect(earliestDateOf(dated("2026-03-01")) == "2026-01-30")
        #expect(earliestDateOf(dated("2026-10-16", earliest: "2026-10-01")) == "2026-10-01")
        #expect(earliestDateOf(dated("2026-10-16", earliest: "2026-11-01")) == "2026-10-16", "填得比内容日期还晚时按内容日期")
        #expect(contentDateRule(dated("2026-10-16")).contains("历史记录最早只能到 2026-09-16"))
        #expect(contentDateRule(dated("2026-10-16", earliest: "2026-10-01")).contains("项目填写的最早日期"))
        #expect(contentDateRule(dated("2026-10-16")).contains("只有 30 天"))
        #expect(contentDateRule(.obj(["request": .emptyObject])).isEmpty)
        #expect(dateProblems(.obj(["request": .emptyObject]), "正文", ["2020-01-01"]).isEmpty)
        #expect(dateProblems(dated("2026-10-16"), "正文", ["2026-08-08 支出"]).first?.contains("2026-09-16 至 2026-10-16") == true)
    }

    @Test("新建和修改时校验最早日期", .timeLimit(.minutes(1)))
    func earliestValidation() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        await #expect(throws: StudioError.self) { _ = try await ctx.create("最早日期错 V1.0", screenCount: 1, extra: ["contentDate": "2026-10-16", "earliestDate": "2026-10-20"]) }
        let dir = try await ctx.create("最早日期对 V1.0", screenCount: 1, extra: ["contentDate": "2026-10-16", "earliestDate": "2026-10-01"])
        #expect(try ctx.core.projectStore.read(dir)?["request"]?["earliestDate"]?.string == "2026-10-01")
        await #expect(throws: StudioError.self) { try await ctx.core.pipeline.updateRequest(dir, ["earliestDate": "2026-13-01"]) }
        await #expect(throws: StudioError.self) { try await ctx.core.pipeline.updateRequest(dir, ["earliestDate": "2026-10-17"]) }
        try await ctx.core.pipeline.updateRequest(dir, ["earliestDate": ""])
        #expect(earliestDateOf(try #require(try ctx.core.projectStore.read(dir))) == "2026-09-16")
    }

    @Test("软性检查：问题带回去让模型修，重试用完仍返回结果；硬性检查照旧报错", .timeLimit(.minutes(1)))
    func softCheck() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let dir = try await ctx.create("软性检查 V1.0", screenCount: 1)
        let result = try await ctx.core.pipeline.callLlm("plan", dir, ChatJsonRequest(system: "测试软性检查", user: "x", softCheck: { _ in ["日期还早"] }))
        #expect(result["ok"] == true)
        #expect(ctx.llm.steps("other").count == 3)
        let retry = ctx.llm.calls.current.last?.body["messages"]?.array?.last?["content"]?.string ?? ""
        #expect(retry.contains("日期还早"))
        await #expect(throws: (any Error).self) { _ = try await ctx.core.pipeline.callLlm("plan", dir, ChatJsonRequest(system: "测试硬性检查", user: "x", check: { _ in ["格式不对"] })) }
    }

    @Test("截图上有早于最早日期的日期：验收不通过，带着原因重生一次", .timeLimit(.minutes(2)))
    func gateRejectsEarlyDates() async throws {
        let ctx = try await CoreContext()
        defer { FS.remove(ctx.root) }
        let dir = try await ctx.create("日期验收重生 V1.0", screenCount: 1, extra: ["contentDate": "2026-10-16"])
        let first = Locked(true)
        ctx.llm.override.withLock { hook in
            hook = { system, body in
                guard system.contains("截图验收员"), first.withLock({ value in defer { value = false }; return value }) else { return nil }
                let user = body["messages"]?[1]?["content"]?[0]?["text"]?.string ?? ""
                return gateReply(Rx.match("计划是「(.+?)」", user)?[1] ?? "", ["账单明细", "到账 2026-08-08", "2026-10-08 午餐"])
            }
        }
        #expect(await ctx.run(dir).status == "done")
        #expect(ctx.relay.submits.count == 2, "第一张验收不通过，自动重生一次")
        let retried = ctx.relay.submits[1].prompt
        #expect(retried.contains("between 2026-09-16 and 2026-10-16"))
        #expect(retried.contains("2026-08-08"))
        #expect(retried.jsTrimmedEnd.hasSuffix(BRAND_BAN_BLOCK.jsTrimmedEnd), "品牌禁令仍在末尾")
        #expect(!(try FS.readText(Path.join(dir, "prompts", "screen-01.md"))).contains("This attempt must fix"), "补充要求只用于这一次，不写进提示词文件")
        let project = try await ctx.project(dir)
        #expect(project["state"]?["log"].items.contains { $0["message"].text.contains("截图里有早于 2026-09-16 的日期：2026-08-08") } == true)
        // 提示词哈希和生图时一致，再运行不会重生
        #expect(await ctx.run(dir).status == "done")
        #expect(ctx.relay.submits.count == 2)
    }

    @Test("修改意见整理补全：指定位置为准，目标写错的纠正，漏掉的意见不会丢")
    func feedbackRepair() {
        let ids = ["screen-01", "screen-02", "screen-03"]
        let items = [FeedbackInput(text: "按钮改成绿色", target: "screen-02"), FeedbackInput(text: "日期都改成今天", target: nil), FeedbackInput(text: "封面多写一句", target: nil)]
        // 模型把指定了图2的意见改到图3，漏了第2条，第3条只给了 overview 但没写来源
        let raw: JSON = ["actions": [
            ["type": "image", "target": "screen-03", "instruction": "按钮改成绿色", "items": [1]],
            ["type": "overview", "target": "overview", "instruction": "封面多写一句"],
            ["type": "image", "target": "screen-09", "instruction": "乱写的屏", "items": [2]],
        ]]
        let repaired = repairFeedbackResult(raw, items: items, screenIds: ids, hasDesign: false)
        #expect(repaired.actions.map { "\($0["type"]!.jsString):\($0["target"]!.jsString)" } == ["overview:overview", "image:screen-02"])
        #expect(repaired.actions.last?["items"] == .array([.number(1)]))
        #expect(repaired.actions.first?["items"] == .array([.number(3)]), "没写来源的动作按内容认领意见")
        #expect(repaired.questions.count == 1)
        #expect(repaired.questions.first?["items"] == .array([.number(2)]))
        // 模型完全失败：指定了位置的照样能改，没指定的列出来让用户选
        let fallback = repairFeedbackResult(.emptyObject, items: items, screenIds: ids, hasDesign: false)
        #expect(fallback.actions.map { "\($0["type"]!.jsString):\($0["target"]!.jsString)" } == ["image:screen-02"])
        #expect(fallback.questions.flatMap { $0["items"].items } == [.number(2), .number(3)])
        #expect(feedbackTargetValid("design", screenIds: ids, hasDesign: false) == nil)
        #expect(feedbackTargetValid("screen-02", screenIds: ids, hasDesign: false) == "screen-02")
    }

    @Test("修改意见：指定位置直接改那里；整理失败也能确认；改图后核对修改有没有改到", .timeLimit(.minutes(2)))
    func feedbackPinned() async throws {
        let ctx = try await CoreContext(relayBehavior: { _, _ in RelayPlan(delayMs: 40) })
        defer { FS.remove(ctx.root) }
        let pipeline = ctx.core.pipeline
        let dir = try await ctx.create("指定位置 V1.0", screenCount: 3)
        #expect(await ctx.run(dir).status == "done")
        let before = ctx.relay.submits.count

        // 意见里写的是图3，但用户在「改哪里」选了图1：以用户选的为准
        try await pipeline.addFeedback(dir, "图3 按钮改成绿色", target: "screen-01")
        let vague = try await pipeline.addFeedback(dir, "日期都改成今天")
        let plan = try await pipeline.analyzeFeedback(dir)
        #expect(plan["actions"].items.map { $0["key"]!.jsString } == ["image:screen-01"])
        #expect(plan["questions"].items.count == 1)
        #expect(ctx.llm.steps("feedback").last?.user.contains("用户指定改：图1") == true)

        // 整理失败（模型一直输出不合格）：不报错，指定了位置的照样列出
        ctx.llm.override.withLock { hook in
            hook = { system, _ in
                system.contains("修改意见整理成") ? jsonResponse(200, ["choices": [["message": ["role": "assistant", "content": "这不是 JSON"]]]]) : nil
            }
        }
        try await pipeline.setFeedbackTarget(dir, vague["id"]!.jsString, "all")
        let fallback = try await pipeline.analyzeFeedback(dir)
        #expect(fallback["notice"]?.string?.contains("自动整理没有成功") == true)
        #expect(fallback["actions"].items.map { $0["key"]!.jsString } == ["image:screen-01", "image:screen-02", "image:screen-03"])
        #expect(fallback["actions"]?[0]?["items"]?.array?.count == 2)
        #expect(fallback["questions"].items.isEmpty)

        // 改图后验收：第一次看图模型说图1没改到，自动重生一次
        let missed = Locked(true)
        ctx.llm.override.withLock { hook in
            hook = { system, body in
                let user = body["messages"]?[1]?["content"]?[0]?["text"]?.string ?? ""
                guard system.contains("截图验收员"), user.contains("修改意见："), user.contains("账号登录"), missed.withLock({ value in defer { value = false }; return value }) else { return nil }
                return gateReply("账号登录", ["账号登录", "登录"], extra: ["changeApplied": false, "changeEvidence": "按钮还是蓝色"])
            }
        }
        _ = try await pipeline.applyFeedback(dir, actions: fallback["actions"].items)
        #expect(await ctx.run(dir).status == "done")
        #expect(ctx.relay.submits.count == before + 4, "三张按意见重生，图1 没改到又重生一次")
        let retried = ctx.relay.submits.last { $0.prompt.contains("the requested change was not visible") }
        #expect(retried?.prompt.contains("按钮改成绿色") == true)
        let project = try await ctx.project(dir)
        #expect(project["state"]?["screens"]?["screen-01"]?["requestedChange"] == nil, "验收通过后清掉")
        #expect(project["state"]?["log"].items.contains { $0["message"].text.contains("截图没有按修改意见改") } == true)
        #expect(project["state"]?["feedback"].items.allSatisfy { $0["status"]?.string == "done" } == true)
    }
}
