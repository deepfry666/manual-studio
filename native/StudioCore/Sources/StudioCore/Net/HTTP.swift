import Foundation

public struct HTTPRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// 整个请求最长等多久（秒）；nil 表示不单独限时（由调用方的任务取消控制）。
    public var timeout: TimeInterval?

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    public var bodyJSON: JSON? { body.flatMap { try? JSON.parse($0) } }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// 键都是小写
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public var ok: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: body, as: UTF8.self) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// 网络传输（相当于 Electron 版的 fetchImpl）：App 用 URLSession，测试换成模拟中转站。
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// 请求被取消（任务取消或超时）。
public struct RequestCanceled: Error, Sendable {}
public struct RequestTimedOut: Error, Sendable {}

public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 3600
        configuration.httpMaximumConnectionsPerHost = 32
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) ?? URL(string: request.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else {
            throw StudioError("接口地址不对：\(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        urlRequest.httpBody = request.body
        if let timeout = request.timeout { urlRequest.timeoutInterval = timeout }
        let prepared = urlRequest
        let perform: @Sendable () async throws -> HTTPResponse = { [session] in
            do {
                let (data, response) = try await session.data(for: prepared)
                guard let http = response as? HTTPURLResponse else { throw StudioError("不是 HTTP 响应") }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { headers["\(key)".lowercased()] = "\(value)" }
                return HTTPResponse(status: http.statusCode, headers: headers, body: data)
            } catch let error as URLError where error.code == .cancelled {
                throw RequestCanceled()
            } catch is CancellationError {
                throw RequestCanceled()
            }
        }
        if let timeout = request.timeout { return try await withDeadline(seconds: timeout, perform) }
        return try await perform()
    }
}

/// 限时执行：超时抛 RequestTimedOut，并取消里面的任务。
public func withDeadline<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw RequestTimedOut()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw RequestCanceled() }
        return result
    }
}

/// 可取消的等待（毫秒）。
public func sleepMs(_ ms: Double) async throws {
    if ms <= 0 { try Task.checkCancellation(); return }
    try await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
}
