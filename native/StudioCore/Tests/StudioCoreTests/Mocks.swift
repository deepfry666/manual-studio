import Foundation
@testable import StudioCore

/// 生成一张非空白的 RGB PNG，seed 不同图案不同。blank=true 时生成纯色图（和 tests/helpers/png.mjs 一样）。
func makePng(_ width: Int = 216, _ height: Int = 456, seed: Int = 1, blank: Bool = false) -> Data {
    encodeRGBPng(width: width, height: height) { x, y in
        if blank { return (240, 240, 240) }
        return (UInt8((x * 3 + seed * 17) % 256), UInt8((y * 2 + seed * 31) % 256), UInt8(((x ^ y) + seed * 7) % 256))
    }
}

func jsonResponse(_ status: Int, _ body: JSON, headers: [String: String] = [:]) -> HTTPResponse {
    var all = ["content-type": "application/json"]
    for (key, value) in headers { all[key] = value }
    return HTTPResponse(status: status, headers: all, body: Data(body.serialized().utf8))
}

protocol MockHost: Sendable {
    func handle(_ request: HTTPRequest, path: String) async throws -> HTTPResponse
}

/// 测试用的网络：按主机名分给不同的模拟服务，不访问真实网络。
final class MockNetwork: HTTPClient, @unchecked Sendable {
    private let hosts = Locked<[String: MockHost]>([:])
    private var counter = Locked(0)

    func register(_ host: MockHost, name: String? = nil) -> String {
        let id = name ?? "mock-\(counter.withLock { $0 += 1; return $0 }).test"
        hosts.withLock { $0[id] = host }
        return id
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let components = URLComponents(string: request.url), let host = components.host, let handler = hosts.withLock({ $0[host] }) else {
            throw URLError(.cannotConnectToHost)
        }
        try Task.checkCancellation()
        let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        return try await handler.handle(request, path: path)
    }
}

/// 可取消的等待：被取消时抛 RequestCanceled（相当于客户端断开连接）。
func mockDelay(_ ms: Double) async throws {
    do { try await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000)) } catch { throw RequestCanceled() }
}

struct RelayPlan: Sendable {
    var delayMs: Double = 50
    var status: Int? = nil
    var error: String? = nil
    var headers: [String: String] = [:]
    var async = false
    var readyAfterMs: Double = 200
    var failTask = false
    var blank = false
    var width = 216
    var height = 456
}

/// 本地模拟中转站（tests/helpers/mock-relay.mjs）。behavior(第几次提交, 请求体) 决定怎么回。
final class MockRelay: MockHost, @unchecked Sendable {
    struct Record: Sendable {
        var kind: String
        var index: Int = 0
        var prompt: String = ""
        var size: String = ""
        var model: String = ""
        var body: JSON = .null
        var arrivedAt: Double = 0
        var finishedAt: Double?
        var aborted = false
        var taskId: String?
    }

    struct TaskInfo: Sendable {
        var readyAt: Double
        var failTask: Bool
        var seed: Int
    }

    let behavior: @Sendable (Int, JSON) -> RelayPlan
    let records = Locked<[Record]>([])
    let tasks = Locked<[String: TaskInfo]>([:])
    let submitCount = Locked(0)
    let taskSeq = Locked(0)
    let started = nowMs()
    var host = ""
    var baseUrl: String { "http://\(host)/v1" }

    init(network: MockNetwork, behavior: @escaping @Sendable (Int, JSON) -> RelayPlan = { _, _ in RelayPlan() }) {
        self.behavior = behavior
        host = network.register(self)
    }

    var submits: [Record] { records.current.filter { $0.kind == "submit" } }

    func handle(_ request: HTTPRequest, path: String) async throws -> HTTPResponse {
        if request.method == "GET", path.hasSuffix("/models") {
            return jsonResponse(200, ["data": [["id": "gpt-image-2.5"], ["id": "gpt-image-2"]]])
        }
        if request.method == "GET", path.hasPrefix("/img/") {
            let id = path.replacingOccurrences(of: "/img/", with: "").replacingOccurrences(of: ".png", with: "")
            let seed = tasks.withLock { $0[id]?.seed } ?? 3
            return HTTPResponse(status: 200, headers: ["content-type": "image/png"], body: makePng(216, 456, seed: seed))
        }
        if request.method == "GET", path.contains("/tasks/") {
            let id = String(path.components(separatedBy: "/tasks/")[1].split(separator: "?")[0])
            records.withLock { $0.append(Record(kind: "poll", arrivedAt: nowMs() - started, taskId: id)) }
            guard let task = tasks.withLock({ $0[id] }) else { return jsonResponse(404, ["error": ["message": "task not found"]]) }
            if nowMs() < task.readyAt { return jsonResponse(200, ["data": ["status": "processing"]]) }
            if task.failTask { return jsonResponse(200, ["data": ["status": "failed", "error": "upstream failed"]]) }
            return jsonResponse(200, ["data": ["status": "completed", "result": ["images": [["url": .array([.string("http://\(host)/img/\(id).png")])]]]]])
        }
        if request.method == "POST", path.hasSuffix("/images/generations") {
            let body = request.bodyJSON ?? .emptyObject
            let index = submitCount.withLock { value -> Int in defer { value += 1 }; return value }
            let plan = behavior(index, body)
            var record = Record(kind: "submit", index: index, prompt: body["prompt"].text, size: body["size"].text, model: body["model"].text, body: body, arrivedAt: nowMs() - started)
            let position = records.withLock { list -> Int in list.append(record); return list.count - 1 }
            do {
                try await mockDelay(plan.delayMs)
            } catch {
                records.withLock { $0[position].aborted = true }
                throw error
            }
            record.finishedAt = nowMs() - started
            records.withLock { $0[position].finishedAt = record.finishedAt }
            if let status = plan.status, status >= 400 {
                return jsonResponse(status, ["error": ["message": .string(plan.error ?? "error")]], headers: plan.headers)
            }
            if plan.async {
                let id = "task_\(taskSeq.withLock { $0 += 1; return $0 })"
                tasks.withLock { $0[id] = TaskInfo(readyAt: nowMs() + plan.readyAfterMs, failTask: plan.failTask, seed: index + 1) }
                return jsonResponse(200, ["code": 200, "data": [["status": "submitted", "task_id": .string(id)]]])
            }
            let png = makePng(plan.width, plan.height, seed: index + 1, blank: plan.blank)
            return jsonResponse(200, ["data": [["b64_json": .string(png.base64EncodedString())]]])
        }
        return jsonResponse(404, ["error": ["message": "not found"]])
    }
}

func longText(_ title: String, _ seed: Int) -> String {
    let base = "进入「\(title)」后，界面顶部显示当前页面标题和返回入口，中部区域按卡片排列本页的核心数据与操作控件。用户可以先查看列表中的状态标签，再点击主要按钮完成本页的关键操作；提交前系统会逐项校验必填内容，缺少信息时在对应输入框下方给出红色提示并保留已填写的内容。操作成功后页面顶部弹出浅色提示条，相关数值即时刷新，便于确认结果。若网络中断或服务暂时不可用，页面会显示重试按钮和最近一次同步时间，不会把空值当作零处理。完成本页操作后，可以通过底部导航切换到其他模块，或点击左上角返回上一页继续处理。"
    return "\(base)（第\(seed)屏补充：本页还支持下拉刷新与长按快捷操作，常用设置会自动记住，下次打开时直接沿用上次的筛选条件和排序方式。）"
}

/// 模拟 OpenAI 兼容的 /chat/completions（tests/helpers/mock-llm.mjs），按系统提示词判断是哪一步。
final class MockLlm: MockHost, @unchecked Sendable {
    struct Call: Sendable {
        var step: String
        var model: String = ""
        var title: String = ""
        var hasImage = false
        var user: String = ""
        var body: JSON = .null
    }

    let gateBrandOnce: [String]
    let gateBrandAlways: [String]
    let brandText: String
    let calls = Locked<[Call]>([])
    let gateSeen = Locked<[String: Int]>([:])
    /// 测试可以替换某一步的回答（返回 nil 走默认）
    let override = Locked<(@Sendable (String, JSON) -> HTTPResponse?)?>(nil)
    var host = ""
    var baseUrl: String { "http://\(host)/v1" }

    init(network: MockNetwork, gateBrandOnce: [String] = [], gateBrandAlways: [String] = [], brandText: String = "测试记账本") {
        self.gateBrandOnce = gateBrandOnce
        self.gateBrandAlways = gateBrandAlways
        self.brandText = brandText
        host = network.register(self)
    }

    func steps(_ name: String) -> [Call] { calls.current.filter { $0.step == name } }

    func handle(_ request: HTTPRequest, path: String) async throws -> HTTPResponse {
        if request.method == "GET", path.hasSuffix("/models") { return jsonResponse(200, ["data": [["id": "mock-text"], ["id": "mock-vision"]]]) }
        let body = request.bodyJSON ?? .emptyObject
        let system = body["messages"]?[0]?["content"]?.string ?? ""
        let userContent = body["messages"]?[1]?["content"]
        let user = userContent?.string ?? userContent?[0]?["text"]?.string ?? ""
        let model = body["model"].text
        if let custom = override.current, let response = custom(system, body) { return response }
        var result: JSON
        if system.contains("规划手机 App 界面截图") {
            calls.withLock { $0.append(Call(step: "plan", model: model, user: user, body: body)) }
            let count = Int(Rx.match("必须正好 ([0-9]+) 屏", user)?[1] ?? "") ?? 7
            let titles = ["账号登录", "记账首页", "新增账单", "账单明细", "统计分析", "预算提醒", "我的设置", "分类管理", "导出账单", "同步备份"]
            let chosen = Array(titles.prefix(count))
            result = .obj([
                "profile": ["domain": "个人记账", "targetUser": "需要管理日常收支的上班族", "coreFlow": "登录—首页—记账—明细—统计—设置"],
                "coverageReason": .string("\(count) 屏覆盖记账核心流程"),
                "features": .array(chosen.enumerated().map { ["name": .string($0.element), "screenId": .string(screenId($0.offset)), "tier": "core"] }),
                "uiContract": ["visualStyle": "clean light finance app", "palette": ["primary": "#2563EB", "background": "#F5F7FB", "surface": "#FFFFFF", "text": "#172033"], "typography": "system sans", "radius": "12px", "shadow": "subtle", "density": "comfortable", "navigation": ["type": "bottom-tabs", "labels": ["首页", "明细", "统计", "我的"], "iconSemantics": ["home", "list", "chart", "person"]]],
                "screens": .array(chosen.enumerated().map { index, title in
                    .obj([
                        "id": .string(screenId(index)), "title": .string(title), "pageType": "page", "activeTab": index == 0 ? .null : "首页",
                        "mustShow": ["标题栏", "数据卡片", "主要按钮"], "sampleData": ["本月支出 ¥3,280", "餐饮 ¥1,120"],
                        "textContract": ["entry": "从首页进入", "action": "录入并保存", "feedback": "保存成功提示", "exception": "必填项为空时提示", "exit": "返回首页"],
                        "visualBrief": .string("A clean personal finance screen titled \(title) with a header, a summary card showing 本月支出 ¥3,280, a category list including 餐饮 ¥1,120 and 交通 ¥360, a primary blue button, and consistent spacing. The layout is calm and readable, with clear Chinese labels and no branding of any kind anywhere on the screen."),
                    ])
                }),
            ])
        } else if system.contains("截图验收员") {
            let title = Rx.match("计划是「(.+?)」", user)?[1] ?? ""
            let seen = gateSeen.withLock { table -> Int in let value = table[title] ?? 0; table[title] = value + 1; return value }
            let hasImage = userContent?.array?.contains { $0["type"]?.string == "image_url" } ?? false
            calls.withLock { $0.append(Call(step: "gate", model: model, title: title, hasImage: hasImage, body: body)) }
            let brand = (gateBrandOnce.contains(title) && seen == 0) || gateBrandAlways.contains(title)
            result = .obj([
                "singleScreen": true, "portraitApp": true, "brandFound": .bool(brand), "brandEvidence": .string(brand ? "顶部写着软件名" : ""), "screenTitle": .string(title),
                "visibleText": brand ? JSON([title, brandText]) : JSON([title, "本月支出 ¥3,280", "餐饮 ¥1,120"]),
                "inventory": .string("界面标题为「\(title)」，上方是本月支出 ¥3,280 的汇总卡片，下面列出餐饮 ¥1,120、交通 ¥360 等分类，底部有蓝色主按钮。"),
                "warnings": [],
            ])
        } else if system.contains("修改意见整理成") {
            calls.withLock { $0.append(Call(step: "feedback", model: model, user: user)) }
            // 简单规则模拟大模型：图N + 说明/文字 → 改说明；图N → 改图；封面 → 封面介绍；整体 → 所有图；其他 → 提问
            let items = Rx.matches("意见([0-9]+)(?:（[^）]*）)?：(.+)", user).map { (Int($0[1]!)!, $0[2]!) }
            var merged: [(String, JSON)] = []
            var questions: [JSON] = []
            for (index, text) in items {
                let figure = Rx.match("图([0-9]+)", text)?[1]
                var action: (String, String)?
                if Rx.test("封面", text) { action = ("overview", "overview") }
                else if let figure, Rx.test("说明|文字|多写", text) { action = ("text", "screen-\(figure.padStart(2))") }
                else if let figure { action = ("image", "screen-\(figure.padStart(2))") }
                else if Rx.test("整体|全部", text) { action = ("image", "all") }
                guard let action else {
                    questions.append(.obj(["question": .string("「\(text)」具体想改哪一屏？"), "items": .array([.number(Double(index))])]))
                    continue
                }
                let key = "\(action.0):\(action.1)"
                if let position = merged.firstIndex(where: { $0.0 == key }) {
                    var previous = merged[position].1
                    previous["instruction"] = .string("\(previous["instruction"]!.string!)；\(text)")
                    previous["items"] = .array(previous["items"].items + [.number(Double(index))])
                    merged[position].1 = previous
                } else {
                    merged.append((key, .obj(["type": .string(action.0), "target": .string(action.1), "instruction": .string(text), "items": .array([.number(Double(index))])])))
                }
            }
            result = .obj(["summary": .string("共 \(merged.count) 处修改"), "actions": .array(merged.map(\.1)), "questions": .array(questions)])
        } else if system.contains("改写一份手机 App 截图的生图提示词") {
            calls.withLock { $0.append(Call(step: "prompt-edit", model: model, user: user)) }
            let instruction = Rx.match("修改要求：(.+)", user)?[1] ?? ""
            let original = user.components(separatedBy: "原提示词：\n").dropFirst().first?.components(separatedBy: "\n\n输出 JSON").first ?? ""
            result = .obj(["prompt": .string("\(original.jsTrimmed)\nRevision applied: \(instruction)")])
        } else if system.contains("用户手册撰写专家") {
            calls.withLock { $0.append(Call(step: "content", model: model, user: user)) }
            let blocks = Rx.matches("【(screen-[0-9]+)｜(.+?)】", user)
            var object = JSONObject()
            if user.contains("需要输出 overview") {
                object["overview"] = "本软件面向需要管理日常收支的上班族，提供快速记账、账单明细、分类统计与预算提醒等功能。用户登录后可在首页查看本月收支概况，通过新增账单快速录入每一笔消费，并在统计页按分类和时间查看趋势，预算接近上限时会收到提醒，个人设置中可管理分类、导出账单与同步备份，帮助用户长期养成记账习惯。"
            }
            object["screens"] = .array(blocks.enumerated().map { index, match in .obj(["id": .string(match[1]!), "title": .string(match[2]!), "text": .string(longText(match[2]!, index + 1))]) })
            result = .object(object)
        } else if system.contains("软件设计说明") {
            calls.withLock { $0.append(Call(step: "design")) }
            let section = { (title: String) -> JSON in
                .obj(["title": .string(title), "text": .string(String(repeating: "\(title)：本软件围绕记账、明细、统计与预算四个核心环节组织处理流程，前端负责输入校验与展示，服务层负责业务规则与数据汇总，数据层按用户、账单、分类和预算等实体保存记录，并为每条记录保留创建时间、更新时间和状态字段，保证数据可追溯、可恢复。", count: 2))])
            }
            result = .obj(["sections": .array(["软件基本处理流程", "程序系统组织结构", "功能模块划分", "接口设计", "数据结构设计"].map(section))])
        } else {
            calls.withLock { $0.append(Call(step: "other", user: user, body: body)) }
            result = ["ok": true]
        }
        return jsonResponse(200, ["choices": [["message": ["role": "assistant", "content": .string(result.serialized())]]], "usage": ["prompt_tokens": 10, "completion_tokens": 10]])
    }
}

/// 收集事件
final class EventLog: @unchecked Sendable {
    let events = Locked<[JSON]>([])
    var handler: @Sendable (JSON) -> Void { { [events] event in events.withLock { $0.append(event) } } }
    var all: [JSON] { events.current }
}

func waitUntil(timeout: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = nowMs() + timeout * 1000
    while nowMs() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}
