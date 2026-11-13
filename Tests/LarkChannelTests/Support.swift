import Foundation
import Testing
@testable import LarkChannel
@testable import LarkCore

/// Records requests and replies with canned responses (copied from LarkCoreTests).
final class MockHTTPClient: LarkHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [LarkHTTPRequest] = []
    let responder: @Sendable (LarkHTTPRequest) throws -> LarkHTTPResponse

    init(_ responder: @escaping @Sendable (LarkHTTPRequest) throws -> LarkHTTPResponse) {
        self.responder = responder
    }

    var requests: [LarkHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    /// Requests other than the tenant token fetch.
    var apiRequests: [LarkHTTPRequest] {
        requests.filter { !$0.url.path.hasSuffix("tenant_access_token/internal") }
    }

    func send(_ request: LarkHTTPRequest) async throws -> LarkHTTPResponse {
        lock.withLock { _requests.append(request) }
        return try responder(request)
    }

    static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> LarkHTTPResponse {
        LarkHTTPResponse(statusCode: status, headers: headers, body: Data(value.jsonString().utf8))
    }
}

/// In-memory WebSocket (copied from LarkCoreTests).
final class MockWebSocket: WebSocketConnection, @unchecked Sendable {
    private let inbound: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    let outbound: AsyncStream<Data>
    private let outboundContinuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

    init() {
        (inbound, inboundContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        (outbound, outboundContinuation) = AsyncStream<Data>.makeStream()
        iterator = inbound.makeAsyncIterator()
    }

    func push(_ frame: WSFrame) { inboundContinuation.yield(frame.serialized()) }
    func drop() { inboundContinuation.finish(throwing: URLError(.networkConnectionLost)) }
    func send(_ data: Data) async throws { outboundContinuation.yield(data) }

    func receive() async throws -> Data {
        guard let d = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return d
    }

    func close(force: Bool) {
        inboundContinuation.finish()
        outboundContinuation.finish()
    }
}

final class MockConnector: WebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [MockWebSocket] = []
    var sockets: [MockWebSocket] { lock.withLock { _sockets } }

    func connect(url: URL, headers: [String: String], timeout: TimeInterval?) async throws -> any WebSocketConnection {
        let s = MockWebSocket()
        lock.withLock { _sockets.append(s) }
        return s
    }
}

/// Captures log lines.
final class CapturingLogger: LarkLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [(LarkLogLevel, String)] = []
    var lines: [(LarkLogLevel, String)] { lock.withLock { _lines } }
    func log(level: LarkLogLevel, message: String) { lock.withLock { _lines.append((level, message)) } }
    func count(_ level: LarkLogLevel) -> Int { lines.filter { $0.0 == level }.count }
}

/// Thread-safe recorder for test callbacks.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [T] = []
    var items: [T] { lock.withLock { _items } }
    func append(_ item: T) { lock.withLock { _items.append(item) } }
    var count: Int { items.count }
}

/// Static DNS answers for the SSRF guard.
struct StubResolver: HostResolver {
    var records: [ResolvedAddress]
    var calls: Recorder<String> = Recorder()
    func lookup(_ host: String) async throws -> [ResolvedAddress] {
        calls.append(host)
        return records
    }
}

enum TestSupport {
    static let tokenPath = "/open-apis/auth/v3/tenant_access_token/internal"

    /// A mock Open Platform: token endpoint + caller-provided routes.
    static func http(_ handler: @escaping @Sendable (LarkHTTPRequest) throws -> LarkHTTPResponse) -> MockHTTPClient {
        MockHTTPClient { req in
            if req.url.path == tokenPath {
                return MockHTTPClient.json(["code": 0, "tenant_access_token": "t-123", "expire": 7200])
            }
            return try handler(req)
        }
    }

    static func channel(
        http: MockHTTPClient, outbound: OutboundConfig? = nil, safety: SafetyConfig? = nil, policy: PolicyConfig? = nil,
        logger: (any LarkLogger)? = nil, connector: (any WebSocketConnector)? = nil, transport: LarkChannelOptions.Transport = .websocket,
        appId: String = "cli_test", includeRawEvent: Bool? = nil
    ) throws -> LarkChannel {
        let ch = try createLarkChannel(
            LarkChannelOptions(
                appId: appId, appSecret: "secret", transport: transport, safety: safety, policy: policy, outbound: outbound,
                logger: logger ?? SilentLarkLogger(), logLevel: logger == nil ? .fatal : .trace, cache: DefaultLarkCache(),
                httpClient: http, webSocketConnector: connector, includeRawEvent: includeRawEvent))
        // Pre-populate the bot identity so tests can skip the connect path.
        ch.botIdentity = BotIdentity(openId: "ou_bot", name: "TestBot")
        return ch
    }

    static func query(_ req: LarkHTTPRequest) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for item in URLComponents(url: req.url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name, default: []].append(item.value ?? "")
        }
        return out
    }

    static func bodyString(_ req: LarkHTTPRequest) -> String { String(decoding: req.body ?? Data(), as: UTF8.self) }

    static func body(_ req: LarkHTTPRequest) throws -> JSONValue { try JSONValue(data: req.body ?? Data()) }

    /// `JSON.parse(body.content)`.
    static func content(_ req: LarkHTTPRequest) throws -> JSONValue {
        try JSONValue(jsonString: try body(req)["content"]?.stringValue ?? "")
    }

    /// Multipart fields (`name` → text or bytes) of a request.
    static func multipart(_ req: LarkHTTPRequest) -> [String: Data] {
        guard let ct = req.headers["Content-Type"], let r = ct.range(of: "boundary=") else { return [:] }
        let boundary = "--" + ct[r.upperBound...]
        let body = req.body ?? Data()
        var out: [String: Data] = [:]
        let sep = Data(boundary.utf8)
        var parts: [Data] = []
        var start = body.startIndex
        while let range = body.range(of: sep, in: start..<body.endIndex) {
            if range.lowerBound > start { parts.append(body[start..<range.lowerBound]) }
            start = range.upperBound
        }
        for part in parts {
            guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = String(decoding: part[part.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            guard let nameRange = header.range(of: "name=\""),
                let close = header[nameRange.upperBound...].firstIndex(of: "\"")
            else { continue }
            let name = String(header[nameRange.upperBound..<close])
            var value = part[headerEnd.upperBound...]
            if value.suffix(2) == Data("\r\n".utf8) { value = value.dropLast(2) }
            out[name] = Data(value)
        }
        return out
    }

    /// Wraps a node-style business error response.
    static func apiError(code: Int, status: Int) -> LarkHTTPResponse {
        MockHTTPClient.json(["code": .number(Double(code)), "msg": .string("code \(code)")], status: status)
    }
}

/// Parsed node-sdk vectors.
enum Vectors {
    static let root: JSONValue = {
        do { return try JSONValue(jsonString: NodeVectors.json) } catch { fatalError("bad vectors: \(error)") }
    }()

    static subscript(_ key: String) -> JSONValue { root[key] ?? .null }
}

extension JSONValue {
    var array: [JSONValue] { arrayValue ?? [] }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
}

/// Polls `condition` until true (or ~`timeout` seconds).
func eventually(timeout: Double = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

func sleepMillis(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
