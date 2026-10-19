import Foundation

public struct LlmPreset: Sendable, Codable, Hashable {
    public let label: String
    public let baseUrl: String
    public let jsonMode: Bool
    public let vision: Bool
    public let suggestedModels: [String]
}

public let LLM_PRESET_ORDER = ["openai", "deepseek", "zhipu", "custom"]
public let LLM_PRESETS: [String: LlmPreset] = [
    "openai": LlmPreset(label: "OpenAI", baseUrl: "https://api.openai.com/v1", jsonMode: true, vision: true, suggestedModels: []),
    "deepseek": LlmPreset(label: "DeepSeek", baseUrl: "https://api.deepseek.com/v1", jsonMode: true, vision: false, suggestedModels: ["deepseek-chat", "deepseek-reasoner"]),
    "zhipu": LlmPreset(label: "智谱 GLM", baseUrl: "https://open.bigmodel.cn/api/paas/v4", jsonMode: true, vision: true, suggestedModels: []),
    "custom": LlmPreset(label: "OpenAI 兼容（自定义 / CPA）", baseUrl: "", jsonMode: true, vision: true, suggestedModels: []),
]

public struct LlmError: Error, LocalizedError, Sendable {
    public let message: String
    public let kind: String
    public let status: Int?
    /// 失败现场：每次模型回了什么（开头、结尾摘录）、为什么结束。写进调用记录，方便事后看是哪种问题
    public let detail: String?
    public init(_ message: String, kind: String = "unknown", status: Int? = nil, detail: String? = nil) {
        self.message = message
        self.kind = kind
        self.status = status
        self.detail = detail
    }
    public var errorDescription: String? { message }
}

func llmJoinUrl(_ baseUrl: String, _ pathPart: String) -> String {
    Rx.replace("/+$", in: baseUrl.jsTrimmed, with: "") + pathPart
}

func llmErrorMessage(_ data: JSON?, _ raw: String, _ status: Int) -> String {
    if let data, data.isObject {
        let candidates: [JSON?] = [data["error"]?["message"], data["error"], data["message"], data["msg"]]
        for candidate in candidates {
            guard let candidate, candidate.truthy else { continue }
            if let text = candidate.string { return text }
            return data.serialized().jsSlice(0, 500)
        }
        return data.serialized().jsSlice(0, 500)
    }
    if let text = data?.string { return text.jsSlice(0, 500) }
    return (raw.isEmpty ? "HTTP \(status)" : raw).jsSlice(0, 500)
}

/// 从模型输出里取出 JSON：兼容 ```json 代码块、<think> 推理段、前后多余文字。
public func extractJson(_ text: String) throws -> JSON {
    var content = Rx.replace(#"<think>[\s\S]*?</think>"#, in: text, with: "", "i").jsTrimmed
    if let fenced = Rx.match(#"```(?:json)?\s*([\s\S]*?)```"#, content, "i") { content = (fenced[1] ?? "").jsTrimmed }
    if let parsed = try? JSON.parse(content) { return parsed }
    let ns = content as NSString
    let start = ns.range(of: "{").location
    let end = ns.range(of: "}", options: .backwards).location
    if start != NSNotFound, end != NSNotFound, end > start, let parsed = try? JSON.parse(ns.substring(with: NSRange(location: start, length: end - start + 1))) {
        return parsed
    }
    throw LlmError("模型输出不是有效的 JSON", kind: "bad-json")
}

func contentText(_ message: JSON?) -> String {
    guard let message else { return "" }
    if let text = message["content"]?.string { return text }
    if let parts = message["content"]?.array { return parts.map { $0["text"]?.string ?? "" }.joined() }
    return ""
}

public struct ChatResult: Sendable {
    public let text: String
    public let usage: JSON?
    public let raw: JSON?
    /// 结束原因：stop 正常结束；length 超过单次输出上限被截断
    public var finishReason: String? = nil
    public var truncated: Bool { ["length", "max_tokens", "max_output_tokens"].contains(finishReason ?? "") }

    /// 推理（思考）内容：有的线路把它放在 reasoning_content / reasoning / reasoning_details 里，和正文分开
    public var reasoningText: String {
        let message = raw?["choices"]?[0]?["message"]
        if let text = message?["reasoning_content"]?.string, !text.isEmpty { return text }
        if let text = message?["reasoning"]?.string, !text.isEmpty { return text }
        if let parts = message?["reasoning_details"]?.array { return parts.map { $0["text"]?.string ?? $0["summary"]?.string ?? "" }.joined() }
        return ""
    }
    /// 推理用掉的 token 数（线路报了才有）
    public var reasoningTokens: Int? { usage?["completion_tokens_details"]?["reasoning_tokens"]?.int }

    /// 给人看的一段诊断：结束原因、正文和推理各多少字、用量，以及线路回的原始内容（截断）
    public var diagnostics: String {
        var lines = [
            "结束原因：\(finishReason ?? "（没给）")",
            "正文：\(text.count) 字\(text.isEmpty ? "（空）" : "，开头：" + text.jsSlice(0, 120))",
            "推理内容：\(reasoningText.isEmpty ? "没有" : "\(reasoningText.count) 字，开头：" + reasoningText.jsSlice(0, 120))",
        ]
        if let usage { lines.append("用量：\(usage.serialized().jsSlice(0, 300))\(reasoningTokens.map { "（其中推理 \($0) tokens）" } ?? "")") }
        lines.append("原始返回：\(raw?.serialized().jsSlice(0, 1500) ?? "（不是 JSON 或为空）")")
        return lines.joined(separator: "\n")
    }

    /// 一句话说明正文为什么是空的
    public var emptyReason: String? {
        guard text.jsTrimmed.isEmpty else { return nil }
        if !reasoningText.isEmpty {
            return truncated
                ? "正文是空的：模型把这次的输出额度都用在了推理（思考）上，还没写正文就到上限被截断了"
                : "正文是空的：线路把回答放在了推理字段里，正文字段没有内容"
        }
        return "正文和推理都是空的：线路没有返回任何文字（可能这条线路不支持非流式请求，或者上游出错但没报错）"
    }
}

/// 有的中转线路（比如 CPA 转接 Cline Pass 的非流式请求）会把标准回包再包一层：{"data": {"choices": …}}。
/// 最外层没有 choices / error、而 data 里有的时候，取里面那层；标准回包原样返回。
func unwrapEnvelope(_ json: JSON?) -> JSON? {
    guard let json, json.isObject, json["choices"] == nil, json["error"] == nil, let inner = json["data"], inner.isObject,
          inner["choices"] != nil || inner["error"] != nil else { return json }
    return inner
}

/// 中转线路或厂商的余额、额度不够（重试也没用，直接告诉用户）
func isBillingError(_ message: String, _ status: Int) -> Bool {
    status == 402 || Rx.test(#"insufficient[_ ](?:credits?|balance|quota|funds)|purchase more credits|credit balance|余额不足|额度不足|欠费|账户余额"#, message, "i")
}

/// 一次对话补全（OpenAI 兼容 /chat/completions）。
/// 处理：网络和 5xx 重试；推理模型不支持 response_format / temperature 时自动去掉重发。
public func chatCompletion(vendor: LlmVendor, apiKey: String, model: String, messages: [JSON], temperature: Double = 0.7, maxTokens: Int = 4096, jsonMode: Bool? = nil, http: HTTPClient, timeoutSec: Double = 240, retryDelay: @Sendable (Double) async throws -> Void = { try await sleepMs($0) }) async throws -> ChatResult {
    if vendor.baseUrl.isEmpty { throw LlmError("大模型接口地址为空", kind: "config") }
    if apiKey.isEmpty { throw LlmError("「\(vendor.name.isEmpty ? vendor.id : vendor.name)」还没有填写密钥", kind: "auth") }
    if model.isEmpty { throw LlmError("没有选择模型", kind: "config") }
    var useJsonMode = jsonMode ?? vendor.jsonMode
    var useTemperature = true
    var tokenLimit = maxTokens
    var lastError: LlmError?
    for attempt in 0..<7 {
        var body: JSON = ["model": .string(model), "messages": .array(messages), "max_tokens": .number(Double(tokenLimit)), "stream": false]
        if useTemperature { body["temperature"] = .number(temperature) }
        if useJsonMode { body["response_format"] = ["type": "json_object"] }
        let response: HTTPResponse
        do {
            try Task.checkCancellation()
            response = try await http.send(HTTPRequest(
                url: llmJoinUrl(vendor.baseUrl, "/chat/completions"),
                method: "POST",
                headers: ["Content-Type": "application/json", "Authorization": "Bearer \(apiKey)"],
                body: Data(body.serialized().utf8),
                timeout: timeoutSec
            ))
        } catch {
            if Task.isCancelled || isCancellation(error) { throw LlmError("已取消", kind: "aborted") }
            lastError = LlmError("网络错误：\(error is RequestTimedOut ? "请求超时" : networkCode(error))", kind: "network")
            do { try await retryDelay(1500 * Double(attempt + 1)) } catch { throw LlmError("已取消", kind: "aborted") }
            continue
        }
        let raw = response.text
        let data = unwrapEnvelope(try? JSON.parse(raw))
        if !response.ok {
            let message = redact(llmErrorMessage(data, raw, response.status), [apiKey])
            if isBillingError(message, response.status) {
                throw LlmError("线路额度不够（\(message.jsSlice(0, 160))）。请给这条线路充值，或换一条线路", kind: "billing", status: response.status)
            }
            if response.status == 400 || response.status == 422 {
                // 兼容不同厂商的限制：输出上限（DeepSeek 为 8192）、不支持 JSON 模式、不支持 temperature
                if Rx.test("max_tokens|max_completion_tokens|maximum.{0,30}tokens|tokens?.{0,20}(?:limit|exceed|range)|最大.{0,10}(?:token|长度)", message, "i"), tokenLimit > 4096 {
                    tokenLimit = tokenLimit > 8192 ? 8192 : 4096
                    continue
                }
                if useTemperature, Rx.test("temperature", message, "i") {
                    useTemperature = false
                    continue
                }
                if useJsonMode {
                    useJsonMode = false
                    continue
                }
            }
            let kind = response.status == 401 || response.status == 403 ? "auth" : response.status == 429 ? "quota" : response.status >= 500 ? "server" : "request"
            let error = LlmError("HTTP \(response.status)：\(message)", kind: kind, status: response.status)
            lastError = error
            if kind == "server" || kind == "quota" {
                do { try await retryDelay(2000 * Double(attempt + 1)) } catch { throw LlmError("已取消", kind: "aborted") }
                continue
            }
            throw error
        }
        let choice = data?["choices"]?[0]
        return ChatResult(text: contentText(choice?["message"]), usage: data?["usage"], raw: data, finishReason: choice?["finish_reason"]?.string)
    }
    throw lastError ?? LlmError("大模型请求失败")
}

public struct ChatJsonRequest: Sendable {
    public var system: String
    public var user: String
    public var images: [String] = []
    public var schema: JSON?
    public var check: (@Sendable (JSON) -> [String])?
    /// 软性检查：问题会带回去让模型修，但重试用完后只剩这类问题时仍然返回最后一次合格的输出，不让整个项目失败。
    public var softCheck: (@Sendable (JSON) -> [String])?
    public var temperature: Double = 0.6
    public var maxTokens: Int = 8000

    public init(system: String, user: String, images: [String] = [], schema: JSON? = nil, check: (@Sendable (JSON) -> [String])? = nil, softCheck: (@Sendable (JSON) -> [String])? = nil, temperature: Double = 0.6, maxTokens: Int = 8000) {
        self.system = system
        self.user = user
        self.images = images
        self.schema = schema
        self.check = check
        self.softCheck = softCheck
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// 让模型按 JSON Schema 输出。不合格时把错误带回去让模型修一次。
/// images：data URL 数组，用于看图模型。
public func chatJson(vendor: LlmVendor, apiKey: String, model: String, request: ChatJsonRequest, http: HTTPClient, retryDelay: @escaping @Sendable (Double) async throws -> Void = { try await sleepMs($0) }) async throws -> JSON {
    // 智谱看图接口按官方示例传不带 data: 前缀的 base64
    let imageUrl = { (url: String) -> String in vendor.preset == "zhipu" ? Rx.replaceFirst("^data:[^;]+;base64,", in: url, with: "") : url }
    let userContent: JSON = request.images.isEmpty
        ? .string(request.user)
        : .array([["type": "text", "text": .string(request.user)]] + request.images.map { ["type": "image_url", "image_url": ["url": .string(imageUrl($0))]] })
    var messages: [JSON] = [
        ["role": "system", "content": .string("\(request.system)\n\n只输出一个 JSON 对象，不要输出任何解释、Markdown 或代码块标记。")],
        ["role": "user", "content": userContent],
    ]
    let base = messages
    var lastProblem = ""
    var acceptable: JSON?
    /// 每次没解析出 JSON 的现场
    var failures: [(truncated: Bool, text: String, finish: String?, reasoning: Int)] = []
    var lastEmptyReason: String?
    for _ in 0..<3 {
        let result = try await chatCompletion(vendor: vendor, apiKey: apiKey, model: model, messages: messages, temperature: request.temperature, maxTokens: request.maxTokens, http: http, retryDelay: retryDelay)
        var parsed: JSON?
        do {
            parsed = try extractJson(result.text)
        } catch {
            failures.append((result.truncated, result.text, result.finishReason, result.reasoningText.count))
            if let reason = result.emptyReason { lastEmptyReason = reason }
            if result.truncated {
                // 被截断：坏输出不带回去（越带越长），直接要求写短一点重来
                lastProblem = "输出太长被截断"
                messages = base + [["role": "user", "content": "（补充要求）上一次输出太长，超过了单次输出上限被截断，JSON 不完整。这次请把各个文字字段写得更精简，只输出一个完整的 JSON 对象。"]]
            } else {
                lastProblem = "模型输出不是有效的 JSON"
                messages.append(["role": "assistant", "content": .string(result.text.jsSlice(0, 2000))])
                messages.append(["role": "user", "content": "上面的输出不是有效的 JSON 对象。请只输出一个完整的 JSON 对象，不要输出任何解释、Markdown 或代码块标记。"])
            }
            continue
        }
        if let parsed {
            var problems: [String] = []
            if let schema = request.schema {
                let errors = SchemaValidator.validate(parsed, schema)
                if !errors.isEmpty { problems.append(SchemaValidator.describe(errors)) }
            }
            if let check = request.check { problems.append(contentsOf: check(parsed)) }
            let soft = problems.isEmpty ? request.softCheck?(parsed) ?? [] : []
            if problems.isEmpty && soft.isEmpty { return parsed }
            if problems.isEmpty { acceptable = parsed }
            lastProblem = (problems + soft).joined(separator: "；")
        }
        messages.append(["role": "assistant", "content": .string(result.text.jsSlice(0, 12000))])
        messages.append(["role": "user", "content": .string("上面的输出不符合要求：\(lastProblem)。请修正后重新输出完整的 JSON 对象。")])
    }
    if let acceptable { return acceptable }
    let detail = failures.enumerated().map { index, item in
        let text = item.text
        let tail = text.count > 600 ? "\n……\n结尾：" + String(text.suffix(300)) : ""
        return "第 \(index + 1) 次：\(item.truncated ? "被截断" : "不是有效的 JSON")（结束原因 \(item.finish ?? "未知")，共 \(text.count) 字\(item.reasoning > 0 ? "，另有推理内容 \(item.reasoning) 字" : "")）\n开头：\(text.jsSlice(0, 600))\(tail)"
    }.joined(separator: "\n\n")
    if let lastEmptyReason, failures.allSatisfy({ $0.text.jsTrimmed.isEmpty }) {
        throw LlmError("模型没有回正文（\(failures.count) 次）：\(lastEmptyReason)。可以换一条线路或换一个模型再试", kind: "empty", detail: detail)
    }
    if !failures.isEmpty, failures.allSatisfy(\.truncated) {
        throw LlmError("模型输出太长被截断：\(failures.count) 次都超过了这条线路允许的单次输出长度，JSON 不完整。这条线路可能限制了输出长度，可以换一条线路或换一个模型再试", kind: "truncated", detail: detail)
    }
    if let sample = failures.first(where: { !$0.truncated }) {
        let head = sample.text.jsTrimmed.isEmpty ? "（空）" : Rx.replace(#"\s+"#, in: sample.text.jsTrimmed, with: " ").jsSlice(0, 80)
        throw LlmError("模型没有按 JSON 格式输出（\(failures.count) 次）。它回的开头是：「\(head)」。这条线路可能不支持 JSON 输出，可以换一条线路或换一个模型再试", kind: "bad-json", detail: detail)
    }
    throw LlmError("模型多次输出都不符合格式要求：\(lastProblem)", kind: "bad-output", detail: detail.isEmpty ? nil : detail)
}

public func listModels(vendor: LlmVendor, apiKey: String, http: HTTPClient) async throws -> [String] {
    let response = try await http.send(HTTPRequest(url: llmJoinUrl(vendor.baseUrl, "/models"), headers: ["Authorization": "Bearer \(apiKey)"], timeout: 30))
    let raw = response.text
    let data = try? JSON.parse(raw)
    if !response.ok { throw LlmError("HTTP \(response.status)：\(redact(llmErrorMessage(data, raw, response.status), [apiKey]))", status: response.status) }
    return (data?["data"]?.array ?? []).compactMap { $0["id"]?.string }.filter { !$0.isEmpty }.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
}
