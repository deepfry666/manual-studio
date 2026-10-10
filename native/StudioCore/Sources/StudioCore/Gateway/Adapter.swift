import Foundation

public struct ProviderError: Error, LocalizedError, Sendable {
    public var message: String
    public var kind: String
    public var status: Int?
    public var retryAfterSec: Double?
    public var allowedRatios: [String] = []
    public var taskId: String?

    public init(_ message: String, kind: String = "unknown", status: Int? = nil, retryAfterSec: Double? = nil, allowedRatios: [String] = [], taskId: String? = nil) {
        self.message = message
        self.kind = kind
        self.status = status
        self.retryAfterSec = retryAfterSec
        self.allowedRatios = allowedRatios
        self.taskId = taskId
    }

    init(_ message: String, _ classified: Classified, status: Int? = nil, taskId: String? = nil) {
        self.init(message, kind: classified.kind, status: status, retryAfterSec: classified.retryAfterSec, allowedRatios: classified.allowedRatios, taskId: taskId)
    }

    public var errorDescription: String? { message }

    public static func aborted() -> ProviderError { ProviderError("请求已取消", kind: "aborted") }
}

func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError || error is RequestCanceled { return true }
    if let error = error as? ProviderError { return error.kind == "aborted" }
    if let error = error as? URLError { return error.code == .cancelled }
    return false
}

/// 读取 JSON 路径：$.data[0].task_id、$.data[*]、$.data.result.images[*]
public func readPath(_ value: JSON?, _ pathExpression: String?) -> JSON? {
    guard let pathExpression, !pathExpression.isEmpty, pathExpression != "$" else { return value }
    var expression = Rx.replaceFirst(#"^\$\.?"#, in: pathExpression, with: "")
    expression = Rx.replace(#"\[([0-9]+|\*)\]"#, in: expression, with: ".[$1]")
    let tokens = expression.split(separator: ".").map(String.init).filter { !$0.isEmpty }
    var current: [JSON?] = [value]
    var fanOut = false
    for token in tokens {
        var next: [JSON?] = []
        for item in current {
            guard let item, !item.isNull else { continue }
            if token == "[*]" {
                fanOut = true
                if let array = item.array { next.append(contentsOf: array.map { Optional($0) }) }
            } else if let match = Rx.match(#"^\[([0-9]+)\]$"#, token), let index = Int(match[1] ?? "") {
                if let array = item.array { next.append(index < array.count ? array[index] : Optional<JSON>.none) }
            } else {
                next.append(item[token])
            }
        }
        current = next
    }
    let defined = current.compactMap { $0 }
    return fanOut ? .array(defined) : defined.first
}

/// 把模板里的 "$model" 等占位替换成实际值；值为空的字段会被去掉。
public func fillTemplate(_ template: JSON, _ context: [String: JSON?]) -> JSON? {
    switch template {
    case .string(let text):
        if let exact = Rx.match(#"^\$([A-Za-z_][A-Za-z0-9_]*)$"#, text), let key = exact[1] {
            return context[key] ?? nil
        }
        return .string(Rx.replace(#"\$([A-Za-z_][A-Za-z0-9_]*)"#, in: text) { groups in
            guard let key = groups[1], let value = context[key] ?? nil, !value.isNull else { return "" }
            return value.jsString
        })
    case .array(let items):
        return .array(items.map { fillTemplate($0, context) ?? .null })
    case .object(let object):
        var result = JSONObject()
        for (key, value) in object {
            if let filled = fillTemplate(value, context), filled != .string("") { result[key] = filled }
        }
        return .object(result)
    default:
        return template
    }
}

public func fillTemplateString(_ template: String, _ context: [String: JSON?]) -> String {
    fillTemplate(.string(template), context)?.jsString ?? ""
}

public func joinUrl(_ baseUrl: String, _ pathPart: String) -> String {
    if Rx.test("^https?://", pathPart, "i") { return pathPart }
    let base = Rx.replace("/+$", in: baseUrl.jsTrimmed, with: "")
    return base + (pathPart.hasPrefix("/") ? pathPart : "/" + pathPart)
}

enum Body {
    case json(JSON)
    case text(String)

    var json: JSON? { if case .json(let value) = self { return value }; return nil }
}

func errorText(_ data: Body) -> String {
    switch data {
    case .text(let text):
        if Rx.test(#"<!doctype html|<html[\s>]"#, text, "i") {
            let title = Rx.match(#"<title>([^<]{0,120})</title>"#, text, "i")?[1]?.jsTrimmed
            return "中转站返回了网页而不是接口数据\(title.map { $0.isEmpty ? "" : "（\($0)）" } ?? "")，可能是网关故障或地址填错"
        }
        return text.jsSlice(0, 600)
    case .json(let value):
        if let text = value.string { return errorText(.text(text)) }
        if value.isArray { return value.serialized().jsSlice(0, 600) }
        guard value.isObject else { return "" }
        let candidates: [JSON?] = [value["error"]?["message"], value["error"], value["message"], value["msg"], value["detail"], value["data"]?["error"], value["data"]?["message"]]
        for candidate in candidates {
            if let text = candidate?.string, !text.isEmpty { return text.jsSlice(0, 600) }
        }
        return value.serialized().jsSlice(0, 600)
    }
}

/// 从报错里解析冷却时间：Retry-After、reset_seconds、48m20s、reset in 15 min。
public func parseRetryAfter(_ headers: [String: String]?, _ message: String) -> Double? {
    if let header = headers?["retry-after"], Rx.test("^[0-9]+$", header.jsTrimmed) { return Double(header.jsTrimmed) }
    if let seconds = Rx.match(#"reset_seconds['"]?\s*[:=]\s*([0-9]+)"#, message, "i") { return Double(seconds[1] ?? "") }
    if let hms = Rx.match("(?:([0-9]+)h)?([0-9]+)m([0-9]+)s", message, "i") {
        return Double(hms[1] ?? "0")! * 3600 + Double(hms[2]!)! * 60 + Double(hms[3]!)!
    }
    if let minutes = Rx.match(#"(?:reset|retry|try again)[^0-9]{0,20}([0-9]+)\s*(?:min|minutes|分钟)"#, message, "i") { return Double(minutes[1]!)! * 60 }
    return nil
}

public struct Classified: Sendable {
    public var kind: String
    public var retryAfterSec: Double? = nil
    public var allowedRatios: [String] = []
}

public func classifyHttpError(_ status: Int, _ message: String, _ headers: [String: String]? = nil) -> Classified {
    if status == 401 || status == 403 { return Classified(kind: "auth") }
    if status == 429 || Rx.test("quota|credential_quota|cooling down|rate.?limit|insufficient_quota|余额不足|额度", message, "i") {
        return Classified(kind: "quota", retryAfterSec: parseRetryAfter(headers, message))
    }
    if looksLikeUnsupportedPixelSize(message) { return Classified(kind: "size", allowedRatios: parseAllowedRatios(message)) }
    if status == 404 || Rx.test("model_not_found|model .* (?:not|isn't) (?:supported|found)|model .* does not exist|no such model|模型不存在|无效的模型", message, "i") {
        return Classified(kind: "config")
    }
    if Rx.test("safety|moderation|content[_ ]policy|违规|敏感", message, "i") { return Classified(kind: "content") }
    if status >= 500 { return Classified(kind: "server") }
    if status == 408 || status == 409 || status == 425 { return Classified(kind: "server") }
    return Classified(kind: "request")
}

func readBody(_ response: HTTPResponse) -> Body {
    let type = response.header("content-type") ?? ""
    let text = response.text
    if type.contains("json") || Rx.test(#"^[\s]*[{\[]"#, text) {
        if let parsed = try? JSON.parse(text) { return .json(parsed) }
        return .text(text)
    }
    return .text(text)
}

func request(_ http: HTTPClient, _ request: HTTPRequest) async throws -> HTTPResponse {
    do {
        try Task.checkCancellation()
        return try await http.send(request)
    } catch {
        if Task.isCancelled || isCancellation(error) { throw ProviderError.aborted() }
        if error is RequestTimedOut { throw ProviderError("网络错误：请求超时", kind: "network") }
        throw ProviderError("网络错误：\(networkCode(error))", kind: "network")
    }
}

func networkCode(_ error: Error) -> String {
    if let error = error as? URLError {
        switch error.code {
        case .cannotConnectToHost: return "ECONNREFUSED"
        case .timedOut: return "ETIMEDOUT"
        case .cannotFindHost, .dnsLookupFailed: return "ENOTFOUND"
        case .networkConnectionLost: return "ECONNRESET"
        case .notConnectedToInternet: return "没有网络连接"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "TLS 握手失败"
        default: return error.localizedDescription
        }
    }
    return messageOf(error)
}

func authHeaders(_ mapping: JSON, _ apiKey: String) -> [String: String] {
    let auth = mapping["auth"]
    if auth?["type"]?.string == "header", let name = auth?["name"]?.string, !name.isEmpty { return [name: apiKey] }
    if auth?["type"]?.string == "query" { return [:] }
    return ["Authorization": "Bearer \(apiKey)"]
}

func withQueryAuth(_ url: String, _ mapping: JSON, _ apiKey: String) -> String {
    guard mapping["auth"]?["type"]?.string == "query", let name = mapping["auth"]?["name"]?.string, !name.isEmpty else { return url }
    let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? value }
    return "\(url)\(url.contains("?") ? "&" : "?")\(encode(name))=\(encode(apiKey))"
}

enum ImageItem {
    case b64(String)
    case dataUrl(String)
    case url(String)
}

func flatten(_ value: JSON) -> [JSON] {
    if let array = value.array { return array.flatMap(flatten) }
    return [value]
}

func normalizeImageItems(_ raw: JSON?) -> [ImageItem] {
    guard let raw else { return [] }
    var result: [ImageItem] = []
    for item in flatten(raw) {
        if let text = item.string {
            if !text.isEmpty { result.append(text.hasPrefix("data:") ? .dataUrl(text) : .url(text)) }
        } else if item.isObject {
            if let b64 = item["b64_json"]?.string, !b64.isEmpty { result.append(.b64(b64)) }
            else if let url = item["url"]?.string { result.append(.url(url)) }
            else if let urls = item["url"]?.array { for url in urls { if let text = url.string { result.append(.url(text)) } } }
            else if let url = item["image_url"]?.string { result.append(.url(url)) }
            else if let image = item["image"]?.string { result.append(image.hasPrefix("http") ? .url(image) : .b64(image)) }
        }
    }
    return result
}

/// 和 Node 的 Buffer.from(x, "base64") 一样宽松：忽略非法字符，补齐 =。
public func decodeBase64Loose(_ text: String) -> Data {
    var cleaned = Rx.replace("[^A-Za-z0-9+/=_-]", in: text, with: "")
    cleaned = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    if let index = cleaned.firstIndex(of: "=") { cleaned = String(cleaned[..<index]) }
    while cleaned.count % 4 != 0 { cleaned += "=" }
    return Data(base64Encoded: cleaned) ?? Data()
}

func materialize(_ item: ImageItem, _ http: HTTPClient) async throws -> Data {
    switch item {
    // 有的中转站在 b64_json 里也带 data: 前缀
    case .b64(let value): return decodeBase64Loose(Rx.replaceFirst("^data:[^,]*,", in: value, with: ""))
    case .dataUrl(let value): return decodeBase64Loose(Rx.replaceFirst("^data:[^,]*,", in: value, with: ""))
    case .url(let url):
        let response = try await request(http, HTTPRequest(url: url))
        if !response.ok { throw ProviderError("下载图片失败（HTTP \(response.status)）", kind: "server", status: response.status) }
        return response.body
    }
}

/// 测试用：把异步线路的轮询间隔改短（nil 表示用映射里的值）。
public let pollingIntervalOverride = Locked<Double?>(nil)

public struct AttemptResult: Sendable {
    public let bytes: Data
    public let taskId: String?
}

/// 执行一次生图尝试（真正的异步请求，不阻塞其他屏）。取消当前任务即中止请求。
/// - 同步线路：一个请求直接拿到图。
/// - 异步线路：提交拿任务号 → onTaskId 立即落盘 → 轮询，临时错误按「还在处理」继续等。
/// - resumeTaskId：软件重启后直接续查，不重复提交，避免重复扣费。
public func runAttempt(
    provider: ImageProvider,
    apiKey: String,
    prompt: String,
    size: String? = nil,
    quality: String? = nil,
    resumeTaskId: String? = nil,
    onTaskId: (@Sendable (String) async -> Void)? = nil,
    http: HTTPClient,
    maxPollMs: Double = 30 * 60 * 1000
) async throws -> AttemptResult {
    let mapping = providerMapping(provider)
    let effectiveQuality = quality ?? (provider.quality.isEmpty ? nil : provider.quality)
    var context: [String: JSON?] = ["model": .string(provider.model), "prompt": .string(prompt), "size": size.map(JSON.string), "quality": effectiveQuality.map(JSON.string)]
    var taskId = resumeTaskId

    if taskId == nil {
        let submit = mapping["submit"] ?? .emptyObject
        let url = withQueryAuth(joinUrl(provider.baseUrl, fillTemplateString(submit["path"]?.string ?? "/images/generations", context)), mapping, apiKey)
        var body = fillTemplate(submit["body"] ?? .emptyObject, context) ?? .emptyObject
        if let extra = provider.extraBody?.object { body = body.merging(.object(extra)) }
        var headers = ["Content-Type": "application/json"]
        for (key, value) in authHeaders(mapping, apiKey) { headers[key] = value }
        for (key, value) in submit["headers"]?.object ?? JSONObject() { headers[key] = value.jsString }
        let response = try await request(http, HTTPRequest(url: url, method: submit["method"]?.string ?? "POST", headers: headers, body: Data(body.serialized().utf8)))
        let data = readBody(response)
        if !response.ok {
            let text = errorText(data)
            let message = text.isEmpty ? "HTTP \(response.status)" : text
            throw ProviderError(message, classifyHttpError(response.status, message, response.headers), status: response.status)
        }
        if let json = data.json, json.isObject, let code = json["code"]?.number, code != 0, code != 200 {
            let message = errorText(data)
            throw ProviderError(message, classifyHttpError(400, message), status: response.status)
        }
        let immediate = normalizeImageItems(readPath(data.json, mapping["response"]?["images"]?.string ?? "$.data[*]"))
        var foundTaskId: String?
        if let path = mapping["response"]?["taskId"]?.string, let raw = readPath(data.json, path) {
            if let number = raw.number { foundTaskId = JSON.formatNumber(number) } else { foundTaskId = raw.string }
        }
        let polling = mapping["polling"]?.truthy == true
        if !immediate.isEmpty, !(polling && foundTaskId != nil && !(foundTaskId ?? "").isEmpty) {
            return AttemptResult(bytes: try await materialize(immediate[0], http), taskId: nil)
        }
        if let found = foundTaskId, !found.isEmpty, polling {
            taskId = found
            await onTaskId?(found)
        } else {
            // 有的中转站把额度、尺寸等错误放在 HTTP 200 的响应体里，照样按内容分类（额度错误要触发冷却）
            let message = errorText(data)
            throw ProviderError("线路返回里没有图片：\(message)", classifyHttpError(400, message))
        }
    }

    guard let taskId, let polling = mapping["polling"], polling.truthy else {
        throw ProviderError("线路没有配置轮询接口，无法续查任务", kind: "config", taskId: taskId)
    }
    context["taskId"] = .string(taskId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? taskId)
    let started = nowMs()
    let successValues = polling["successValues"]?.stringArray.map { $0.lowercased() } ?? []
    let failureValues = polling["failureValues"]?.stringArray.map { $0.lowercased() } ?? []
    while nowMs() - started < maxPollMs {
        do {
            try await sleepMs(pollingIntervalOverride.current ?? polling["intervalMs"]?.number ?? 3000)
        } catch {
            throw ProviderError.aborted()
        }
        let url = withQueryAuth(joinUrl(provider.baseUrl, fillTemplateString(polling["path"]?.string ?? "", context)), mapping, apiKey)
        let response: HTTPResponse
        do {
            response = try await request(http, HTTPRequest(url: url, method: polling["method"]?.string ?? "GET", headers: authHeaders(mapping, apiKey)))
        } catch let error as ProviderError {
            if error.kind == "aborted" { throw error }
            continue // 查询时的网络抖动不算失败
        }
        let data = readBody(response)
        if !response.ok {
            if [408, 409, 425, 429, 500, 502, 503, 504].contains(response.status) { continue }
            let message = errorText(data)
            // 查询任务时的 404 是「任务不存在/已过期」，不是线路配置错，不能因此停用整条线路
            if response.status == 404 { throw ProviderError("任务不存在或已过期：\(message)", kind: "task-failed", status: 404, taskId: taskId) }
            throw ProviderError(message, classifyHttpError(response.status, message), status: response.status, taskId: taskId)
        }
        let status = (readPath(data.json, polling["statusPath"]?.string).map { $0.isNull ? "" : $0.jsString } ?? "").lowercased()
        if failureValues.contains(status) {
            let message = errorText(data)
            throw ProviderError("任务失败（\(status)）：\(message)", kind: classifyHttpError(400, message).kind == "content" ? "content" : "task-failed", taskId: taskId)
        }
        if !successValues.contains(status) { continue }
        let images = normalizeImageItems(readPath(data.json, polling["resultPath"]?.string))
        if images.isEmpty { throw ProviderError("任务已完成，但结果里没有图片", kind: "task-failed", taskId: taskId) }
        return AttemptResult(bytes: try await materialize(images[0], http), taskId: taskId)
    }
    throw ProviderError("任务还在处理中，已保留任务号，稍后可以继续查询", kind: "pending", taskId: taskId)
}

/// 免费的连通性检查：GET /models，确认 key 和模型名。
public func probeModels(provider: ImageProvider, apiKey: String, http: HTTPClient) async throws -> (models: [String], hasModel: Bool?) {
    let mapping = providerMapping(provider)
    let url = withQueryAuth(joinUrl(provider.baseUrl, "/models"), mapping, apiKey)
    let response = try await request(http, HTTPRequest(url: url, headers: authHeaders(mapping, apiKey), timeout: 60))
    let data = readBody(response)
    if !response.ok {
        let text = errorText(data)
        let message = text.isEmpty ? "HTTP \(response.status)" : text
        throw ProviderError(message, classifyHttpError(response.status, message, response.headers), status: response.status)
    }
    let ids = (data.json?["data"]?.array ?? []).compactMap { $0["id"]?.string }.filter { !$0.isEmpty }
    return (ids, ids.isEmpty ? nil : ids.contains(provider.model))
}
