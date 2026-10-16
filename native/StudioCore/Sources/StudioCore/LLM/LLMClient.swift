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
    public init(_ message: String, kind: String = "unknown", status: Int? = nil) {
        self.message = message
        self.kind = kind
        self.status = status
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
        let data = try? JSON.parse(raw)
        if !response.ok {
            let message = redact(llmErrorMessage(data, raw, response.status), [apiKey])
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
        let message = data?["choices"]?[0]?["message"]
        return ChatResult(text: contentText(message), usage: data?["usage"], raw: data)
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
    var lastProblem = ""
    var acceptable: JSON?
    for _ in 0..<3 {
        let result = try await chatCompletion(vendor: vendor, apiKey: apiKey, model: model, messages: messages, temperature: request.temperature, maxTokens: request.maxTokens, http: http, retryDelay: retryDelay)
        var parsed: JSON?
        do {
            parsed = try extractJson(result.text)
        } catch {
            lastProblem = messageOf(error)
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
    throw LlmError("模型多次输出都不符合格式要求：\(lastProblem)", kind: "bad-output")
}

public func listModels(vendor: LlmVendor, apiKey: String, http: HTTPClient) async throws -> [String] {
    let response = try await http.send(HTTPRequest(url: llmJoinUrl(vendor.baseUrl, "/models"), headers: ["Authorization": "Bearer \(apiKey)"], timeout: 30))
    let raw = response.text
    let data = try? JSON.parse(raw)
    if !response.ok { throw LlmError("HTTP \(response.status)：\(redact(llmErrorMessage(data, raw, response.status), [apiKey]))", status: response.status) }
    return (data?["data"]?.array ?? []).compactMap { $0["id"]?.string }.filter { !$0.isEmpty }.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
}
