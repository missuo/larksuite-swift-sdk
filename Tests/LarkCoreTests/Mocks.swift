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
    private var _urls: [URL] = []
    private var _headers: [[String: String]] = []

    var sockets: [MockWebSocket] { lock.lock(); defer { lock.unlock() }; return _sockets }
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
