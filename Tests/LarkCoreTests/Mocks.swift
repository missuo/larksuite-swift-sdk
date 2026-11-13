import Foundation
@testable import LarkCore

/// Records requests and replies with canned responses.
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

    func send(_ request: LarkHTTPRequest) async throws -> LarkHTTPResponse {
        lock.withLock { _requests.append(request) }
        return try responder(request)
    }

    static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> LarkHTTPResponse {
        LarkHTTPResponse(statusCode: status, headers: headers, body: Data(value.jsonString().utf8))
    }
}

/// In-memory WebSocket: the test pushes inbound frames and reads outbound ones.
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

    private let lock = NSLock()
    private var _closeCalls: [Bool] = []
    /// The `force` flag of every `close(force:)` call, in order.
    var closeCalls: [Bool] { lock.withLock { _closeCalls } }

    func pushRaw(_ data: Data) { inboundContinuation.yield(data) }

    func send(_ data: Data) async throws { outboundContinuation.yield(data) }

    func receive() async throws -> Data {
        guard let d = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return d
    }

    func close(force: Bool) {
        lock.withLock { _closeCalls.append(force) }
        inboundContinuation.finish()
        outboundContinuation.finish()
    }
}

/// Collects every log line (level + message) for assertions.
final class RecordingLogger: LarkLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [(LarkLogLevel, String)] = []

    func log(level: LarkLogLevel, message: String) { lock.withLock { _lines.append((level, message)) } }

    func messages(_ level: LarkLogLevel) -> [String] { lock.withLock { _lines.filter { $0.0 == level }.map(\.1) } }
    var all: [String] { lock.withLock { _lines.map(\.1) } }
    func clear() { lock.withLock { _lines.removeAll() } }
}

/// In-memory cache that records every `set` call (node tests use a jest.fn cache).
actor RecordingCache: LarkCache {
    struct SetCall: Sendable {
        var key: String
        var value: String
        var expiresAt: Date?
        var namespace: String?
    }

    private var store: [String: String] = [:]
    private(set) var setCalls: [SetCall] = []

    init(_ initial: [(key: String, value: String, namespace: String?)] = []) {
        for e in initial { store["\(e.key)|\(e.namespace ?? "")"] = e.value }
    }

    func get(_ key: String, namespace: String?) async -> String? { store["\(key)|\(namespace ?? "")"] }

    func set(_ key: String, value: String, expiresAt: Date?, namespace: String?) async -> Bool {
        setCalls.append(SetCall(key: key, value: value, expiresAt: expiresAt, namespace: namespace))
        store["\(key)|\(namespace ?? "")"] = value
        return true
    }
}

/// An error with a fixed message (stands in for EPIPE / ETIMEDOUT / provider failures).
struct TestError: Error, Equatable, CustomStringConvertible, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

/// Thread-safe mutable box for test state shared with `@Sendable` closures.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func mutate<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&_value) } }
}

/// Polls `condition` until it holds (or the timeout elapses); returns whether it held.
@discardableResult
func eventually(timeout: TimeInterval = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// Sleeps for `ms` milliseconds.
func sleepMs(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

/// HTTP client whose requests stay pending until the test resolves or rejects them
/// (port of the node tests' `createControlledHttp` / deferred `httpInstance.request`).
final class ControlledHTTPClient: LarkHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<LarkHTTPResponse, Error>] = []
    private var _requests: [LarkHTTPRequest] = []

    var requests: [LarkHTTPRequest] { lock.withLock { _requests } }
    var pendingCount: Int { lock.withLock { pending.count } }

    func send(_ request: LarkHTTPRequest) async throws -> LarkHTTPResponse {
        try await withCheckedThrowingContinuation { c in
            lock.withLock {
                _requests.append(request)
                pending.append(c)
            }
        }
    }

    private func takeNext() -> CheckedContinuation<LarkHTTPResponse, Error>? {
        lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
    }

    @discardableResult
    func resolveNext(_ json: JSONValue, status: Int = 200) -> Bool {
        guard let c = takeNext() else { return false }
        c.resume(returning: MockHTTPClient.json(json, status: status))
        return true
    }

    @discardableResult
    func rejectNext(_ error: Error) -> Bool {
        guard let c = takeNext() else { return false }
        c.resume(throwing: error)
        return true
    }

    /// Fails every pending request (test cleanup).
    func rejectAll() { while rejectNext(CancellationError()) {} }

    static let wsSuccess: JSONValue = [
        "code": 0,
        "data": [
            "URL": "wss://fake?device_id=d1&service_id=s1",
            "ClientConfig": ["PingInterval": 120, "ReconnectCount": 3, "ReconnectInterval": 0.001, "ReconnectNonce": 0],
        ],
        "msg": "ok",
    ]

    static func wsFailure(_ code: Int, _ msg: String = "failed") -> JSONValue {
        ["code": .number(Double(code)), "data": ["URL": "", "ClientConfig": [:]], "msg": .string(msg)]
    }
}

/// WebSocket connector whose handshakes stay pending until the test opens or fails them.
/// A cancelled handshake is recorded but stays pending, like a transport stuck in DNS/NAT.
final class ControlledConnector: WebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<any WebSocketConnection, Error>] = []
    private var _urls: [URL] = []
    private var _headers: [[String: String]] = []
    private var _sockets: [MockWebSocket] = []
    private var _cancelled = 0

    var urls: [URL] { lock.withLock { _urls } }
    var headers: [[String: String]] { lock.withLock { _headers } }
    var sockets: [MockWebSocket] { lock.withLock { _sockets } }
    var attempts: Int { lock.withLock { _urls.count } }
    var pendingCount: Int { lock.withLock { pending.count } }
    var cancelledCount: Int { lock.withLock { _cancelled } }

    func connect(url: URL, headers: [String: String], timeout: TimeInterval?) async throws -> any WebSocketConnection {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.withLock {
                    _urls.append(url)
                    _headers.append(headers)
                    pending.append(c)
                }
            }
        } onCancel: {
            lock.withLock { _cancelled += 1 }
        }
    }

    /// Completes the oldest pending handshake with a fresh socket.
    @discardableResult
    func openNext() -> MockWebSocket? {
        let socket = MockWebSocket()
        guard let c = lock.withLock({ () -> CheckedContinuation<any WebSocketConnection, Error>? in
            guard !pending.isEmpty else { return nil }
            _sockets.append(socket)
            return pending.removeFirst()
        }) else { return nil }
        c.resume(returning: socket)
        return socket
    }

    @discardableResult
    func failNext(_ error: Error = TestError("test rejection")) -> Bool {
        guard let c = lock.withLock({ pending.isEmpty ? nil : pending.removeFirst() }) else { return false }
        c.resume(throwing: error)
        return true
    }

    func failAll() { while failNext() {} }
}

final class MockConnector: WebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [MockWebSocket] = []
    private var _urls: [URL] = []
    private var _headers: [[String: String]] = []

    var sockets: [MockWebSocket] { lock.withLock { _sockets } }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    var headers: [[String: String]] { lock.lock(); defer { lock.unlock() }; return _headers }

    func connect(url: URL, headers: [String: String], timeout: TimeInterval?) async throws -> any WebSocketConnection {
        let s = MockWebSocket()
        lock.withLock {
            _sockets.append(s)
            _urls.append(url)
            _headers.append(headers)
        }
        return s
    }
}

/// Test-only access to `WSClient` internals (node tests poke the same private fields via `client as any`).
extension WSClient {
    func testSet(
        isConnecting: Bool? = nil, hasEverConnected: Bool? = nil, terminalError: Bool? = nil,
        reconnectAttempts: Int? = nil, dispatcher: EventDispatcher? = nil
    ) {
        if let isConnecting { self.isConnecting = isConnecting }
        if let hasEverConnected { self.hasEverConnected = hasEverConnected }
        if let terminalError { self.terminalError = terminalError }
        if let reconnectAttempts { self.currentReconnectAttempts = reconnectAttempts }
        if let dispatcher { self.dispatcher = dispatcher }
    }

    /// Installs `socket` as the live connection (like `wsConfig.setWSInstance`), returning its id.
    @discardableResult
    func testAdopt(_ socket: any WebSocketConnection) -> Int {
        connectionID += 1
        connection = socket
        return connectionID
    }

    var testState: (isConnecting: Bool, hasEverConnected: Bool, closed: Bool, generation: Int) {
        (isConnecting, hasEverConnected, closed, generation)
    }

    var testHasLivenessTimer: Bool { livenessTask != nil }
    var testHasReconnectTimer: Bool { reconnectTask != nil }
    var testHasConnection: Bool { connection != nil }
}

/// A valid-looking app id (matches `^cli_[0-9a-fA-F]{16}$`).
let testWSAppId = "cli_0000000000000001"
