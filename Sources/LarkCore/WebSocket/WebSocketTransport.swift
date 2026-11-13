import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An open WebSocket connection carrying binary messages.
public protocol WebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    /// Receives the next binary message. Throws when the connection closes.
    func receive() async throws -> Data
    func close(force: Bool)
}

/// Opens WebSocket connections. Replace it to use SwiftNIO / a proxy / a mock.
public protocol WebSocketConnector: Sendable {
    func connect(url: URL, headers: [String: String], timeout: TimeInterval?) async throws -> any WebSocketConnection
}

/// Default `URLSessionWebSocketTask`-based connector.
public struct URLSessionWebSocketConnector: WebSocketConnector {
    public var maximumMessageSize: Int

    public init(maximumMessageSize: Int = 64 * 1024 * 1024) {
        self.maximumMessageSize = maximumMessageSize
    }

    public func connect(url: URL, headers: [String: String], timeout: TimeInterval?) async throws -> any WebSocketConnection {
        let delegate = OpenWaiter()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        do {
            try await delegate.wait(timeout: timeout) { task.resume() }
        } catch {
            task.cancel(with: .abnormalClosure, reason: nil)
            session.invalidateAndCancel()
            throw error
        }
        return URLSessionWebSocketConnection(task: task, session: session)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    let session: URLSession

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: return Data()
        }
    }

    func close(force: Bool) {
        task.cancel(with: force ? .abnormalClosure : .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Waits for the WebSocket handshake to complete or fail.
final class OpenWaiter: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait(timeout: TimeInterval?, start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                c.resume(with: result)
                return
            }
            continuation = c
            lock.unlock()
            start()
            if let timeout, timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(LarkError.transport(message: "handshake timeout after \(Int(timeout * 1000))ms")))
                }
            }
        }
    }

    private func finish(_ r: Result<Void, Error>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            return
        }
        result = r
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: r)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finish(.success(()))
    }

    // Required on Linux (swift-corelibs-foundation has no default implementation).
    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(.failure(LarkError.transport(message: "websocket closed during handshake (code \(closeCode.rawValue))")))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        finish(.failure(error ?? LarkError.transport(message: "websocket handshake failed\(status.map { " (HTTP \($0))" } ?? "")")))
    }
}
