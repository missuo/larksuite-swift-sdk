import Foundation

/// Lifecycle state of a ``WSClient``.
public enum WSConnectionState: String, Sendable {
    case idle, connecting, connected, reconnecting, failed
}

/// Snapshot returned by ``WSClient/connectionStatus``.
public struct WSConnectionStatus: Sendable {
    public var state: WSConnectionState
    public var lastConnectTime: Date?
    public var nextConnectTime: Date?
    /// Consecutive reconnect attempts in the current loop (0 after a successful connect).
    public var reconnectAttempts: Int
}

/// Options for ``WSClient``.
public struct WSClientOptions: Sendable {
    public var appId: String
    /// Provide either `appSecret` or `clientAssertionProvider`.
    public var appSecret: String
    public var clientAssertionProvider: (any ClientAssertionProvider)?
    public var domain: LarkDomain
    public var logLevel: LarkLogLevel
    public var logger: any LarkLogger
    public var httpClient: any LarkHTTPClient
    public var webSocketConnector: any WebSocketConnector
    public var autoReconnect: Bool
    /// Overrides the WebSocket URL `host[:port]`, keeping path and query.
    public var connectionHost: String?
    /// Extra handshake headers. `Host`, `Connection`, `Upgrade` and `Sec-WebSocket-*` are rejected.
    public var connectionHeaders: [String: String]
    /// Handshake timeout in seconds (nil = no client-side timeout).
    public var handshakeTimeout: TimeInterval?
    /// Liveness watchdog in seconds: if nothing arrives within this window after a
    /// ping, the connection is dropped and re-established. nil = disabled.
    public var pingTimeout: TimeInterval?
    public var source: String?
    public var extraUserAgentTags: [String]
    /// Fires once when the first connection succeeds.
    public var onReady: (@Sendable () -> Void)?
    /// Fires when the client gives up (non-retryable error, retries exhausted, or autoReconnect disabled).
    public var onError: (@Sendable (Error) -> Void)?
    /// Fires when the client starts reconnecting after a disconnect.
    public var onReconnecting: (@Sendable () -> Void)?
    /// Fires when a reconnect succeeds.
    public var onReconnected: (@Sendable () -> Void)?

    public init(
        appId: String,
        appSecret: String = "",
        clientAssertionProvider: (any ClientAssertionProvider)? = nil,
        domain: LarkDomain = .feishu,
        logLevel: LarkLogLevel = .info,
        logger: any LarkLogger = ConsoleLarkLogger(),
        httpClient: any LarkHTTPClient = URLSessionHTTPClient(),
        webSocketConnector: any WebSocketConnector = URLSessionWebSocketConnector(),
        autoReconnect: Bool = true,
        connectionHost: String? = nil,
        connectionHeaders: [String: String] = [:],
        handshakeTimeout: TimeInterval? = nil,
        pingTimeout: TimeInterval? = nil,
        source: String? = nil,
        extraUserAgentTags: [String] = [],
        onReady: (@Sendable () -> Void)? = nil,
        onError: (@Sendable (Error) -> Void)? = nil,
        onReconnecting: (@Sendable () -> Void)? = nil,
        onReconnected: (@Sendable () -> Void)? = nil
    ) {
        self.appId = appId
        self.appSecret = appSecret
        self.clientAssertionProvider = clientAssertionProvider
        self.domain = domain
        self.logLevel = logLevel
        self.logger = logger
        self.httpClient = httpClient
        self.webSocketConnector = webSocketConnector
        self.autoReconnect = autoReconnect
        self.connectionHost = connectionHost
        self.connectionHeaders = connectionHeaders
        self.handshakeTimeout = handshakeTimeout
        self.pingTimeout = pingTimeout
        self.source = source
        self.extraUserAgentTags = extraUserAgentTags
        self.onReady = onReady
        self.onError = onError
        self.onReconnecting = onReconnecting
        self.onReconnected = onReconnected
    }
}

/// Long-connection (WebSocket) client that receives events and callbacks
/// without a public webhook URL. Self-built apps only.
///
/// ```swift
/// let dispatcher = EventDispatcher().register("im.message.receive_v1") { event in ...; return nil }
/// let ws = try WSClient(.init(appId: "cli_xxx", appSecret: "xxx"))
/// await ws.start(eventDispatcher: dispatcher)
/// await ws.waitUntilClosed()
/// ```
public actor WSClient {
    // Protocol constants
    enum FrameType: Int32 {
        case control = 0
        case data = 1
    }
    enum ErrorCode {
        static let ok = 0
        static let systemBusy = 1
        static let internalError = 1_000_040_343
    }
    static let endpointURI = "/callback/ws/endpoint"

    struct Settings {
        var connectURL: URL?
        var deviceId = ""
        var serviceId: Int32 = 0
        var pingInterval: TimeInterval = 120
        var reconnectCount = -1
        var reconnectInterval: TimeInterval = 120
        var reconnectNonce: TimeInterval = 30
    }

    enum ConnectResult {
        case ok
        case retryable
        case fatal(String)
    }

    public nonisolated let options: WSClientOptions
    nonisolated let logger: LoggerProxy
    nonisolated let userAgent: String
    nonisolated let connectionHeaders: [String: String]

    var settings = Settings()
    var dispatcher: EventDispatcher?
    var connection: (any WebSocketConnection)?
    var connectionID = 0
    var generation = 0
    var closed = false
    var isConnecting = false
    var hasEverConnected = false
    var terminalError = false
    var currentReconnectAttempts = 0
    var lastConnectTime: Date?
    var nextConnectTime: Date?
    var pingTask: Task<Void, Never>?
    var livenessTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var fragments = FragmentCache()
    var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(_ options: WSClientOptions) throws {
        if let host = options.connectionHost {
            if host.trimmingCharacters(in: .whitespaces).isEmpty || host.contains("/") || host.contains("?") {
                throw LarkError.invalidArgument("invalid websocket connection host")
            }
        }
        for name in options.connectionHeaders.keys {
            let lower = name.lowercased()
            if ["host", "connection", "upgrade"].contains(lower) || lower.hasPrefix("sec-websocket-") {
                throw LarkError.invalidArgument("invalid websocket connection headers")
            }
        }
        if options.appSecret.isEmpty && options.clientAssertionProvider == nil {
            throw LarkError.clientAssertion(
                code: ClientAssertionErrorCode.appSecretAndClientAssertionEmpty, msg: "appSecret or clientAssertionProvider is required")
        }
        self.options = options
        self.connectionHeaders = options.connectionHeaders
        self.logger = LoggerProxy(level: options.logLevel, sink: options.logger)
        self.userAgent = UserAgent.build(source: options.source, extraTags: options.extraUserAgentTags)
        if options.appId.isEmpty { logger.error("appId is needed") }
    }

    /// Convenience initialiser.
    public init(appId: String, appSecret: String, domain: LarkDomain = .feishu, logLevel: LarkLogLevel = .info) throws {
        try self.init(WSClientOptions(appId: appId, appSecret: appSecret, domain: domain, logLevel: logLevel))
    }

    // MARK: - Public API

    /// Starts receiving events. Returns after the first connection attempt; the
    /// client keeps reconnecting in the background as configured.
    public func start(eventDispatcher: EventDispatcher) async {
        let appId = options.appId
        if appId.range(of: "^cli_[0-9a-fA-F]{16}$", options: .regularExpression) == nil {
            logger.error("[ws] invalid appId: \(appId)")
            return
        }
        terminalError = false
        closed = false
        currentReconnectAttempts = 0
        dispatcher = eventDispatcher
        logger.info(
            "[ws] receive events or callbacks through persistent connection only available in self-build & Feishu app, configured in: Developer Console -> Events and Callbacks -> Mode of event/callback subscription -> Receive events/callbacks through persistent connection"
        )
        await reconnect(isStart: true)
    }

    /// Closes the connection and stops reconnecting.
    public func close(force: Bool = false) {
        closed = true
        generation += 1
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        clearLiveness()
        fragments.removeAll()
        isConnecting = false
        currentReconnectAttempts = 0
        if let c = connection {
            connectionID += 1
            c.close(force: force)
            connection = nil
        }
        logger.info("[ws] ws client closed manually\(force ? " (force)" : "")")
        let waiters = closeWaiters
        closeWaiters = []
        for w in waiters { w.resume() }
    }

    /// Suspends until ``close(force:)`` is called (handy for command-line bots).
    public func waitUntilClosed() async {
        if closed { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    /// Current lifecycle status.
    public var connectionStatus: WSConnectionStatus {
        WSConnectionStatus(
            state: computeState(), lastConnectTime: lastConnectTime, nextConnectTime: nextConnectTime,
            reconnectAttempts: currentReconnectAttempts)
    }

    /// Times of the last and next connection attempts.
    public var reconnectInfo: (lastConnectTime: Date?, nextConnectTime: Date?) { (lastConnectTime, nextConnectTime) }

    func computeState() -> WSConnectionState {
        if terminalError { return .failed }
        if isConnecting && !hasEverConnected { return .connecting }
        if isConnecting && hasEverConnected { return .reconnecting }
        if connection != nil { return .connected }
        return .idle
    }

    // MARK: - Endpoint discovery

    func pullConnectConfig() async -> ConnectResult {
        let domain = options.domain.baseURL
        var url = domain + Self.endpointURI
        var headers = ["locale": "zh", "User-Agent": userAgent, "Content-Type": "application/json; charset=utf-8"]
        var body: [String: JSONValue] = ["AppID": .string(options.appId)]
        // Mirrors node-sdk: only credential (ClientAssertion) and connection-config problems are
        // terminal; every other failure (provider/transport errors, bad proxy target...) is retried.
        do {
            if let provider = options.clientAssertionProvider {
                let aud = try LarkOAuth.extractAud(fromURL: domain)
                let assertion = try await provider.retrieveToken(aud: aud)
                guard !assertion.value.isEmpty else {
                    throw LarkError.clientAssertion(code: ClientAssertionErrorCode.tokenEmpty, msg: "client assertion token is empty")
                }
                body["AppSecret"] = ""
                body["ClientAssertion"] = .string(assertion.value)
                if let target = assertion.targetInfo {
                    url = try LarkOAuth.buildProxyURL(target, apiPath: Self.endpointURI)
                    headers[LarkOAuth.targetServiceHeader] = aud
                }
            } else {
                body["AppSecret"] = .string(options.appSecret)
            }
            guard let u = URL(string: url) else { throw LarkError.transport(message: "invalid endpoint url") }
            let resp = try await options.httpClient.send(
                LarkHTTPRequest(method: .post, url: u, headers: headers, body: try LarkJSON.encoder.encode(JSONValue.object(body)), timeout: 15))
            guard let json = try? JSONValue(data: resp.body) else {
                logger.error("[ws] endpoint returned non-JSON (HTTP \(resp.statusCode))")
                return .retryable
            }
            let code = json["code"]?.intValue ?? -1
            if code != ErrorCode.ok {
                let reason = code == ErrorCode.systemBusy ? "system busy" : (json["msg"]?.stringValue ?? "")
                logger.error("[ws] code: \(code), \(reason)")
                if code == ErrorCode.internalError { return .retryable }
                return .fatal("pullConnectConfig failed: code=\(code), msg=\(reason)")
            }
            guard let rawURL = json["data"]?["URL"]?.stringValue else { return .retryable }
            let cfg = json["data"]?["ClientConfig"]
            let connectURL: URL
            do {
                connectURL = try Self.buildConnectionURL(rawURL, host: options.connectionHost)
            } catch {
                // ConnectionConfigError in node-sdk: terminal.
                logger.error("[ws] invalid websocket connection endpoint")
                return .fatal("invalid websocket connection endpoint")
            }
            let query = URLComponents(string: rawURL)?.queryItems ?? []
            settings.connectURL = connectURL
            settings.deviceId = query.first { $0.name == "device_id" }?.value ?? ""
            settings.serviceId = Int32(query.first { $0.name == "service_id" }?.value ?? "") ?? 0
            applyClientConfig(cfg)
            logger.debug("[ws] get connect config success, ws url: \(rawURL)")
            return .ok
        } catch LarkError.clientAssertion(_, let msg) {
            logger.error("[ws] \(msg)")
            return .fatal(msg)
        } catch {
            logger.error("[ws] \(error)")
            return .retryable
        }
    }

    func applyClientConfig(_ cfg: JSONValue?) {
        guard let cfg else { return }
        if let v = cfg["PingInterval"]?.doubleValue { settings.pingInterval = v }
        if let v = cfg["ReconnectCount"]?.intValue { settings.reconnectCount = v }
        if let v = cfg["ReconnectInterval"]?.doubleValue { settings.reconnectInterval = v }
        if let v = cfg["ReconnectNonce"]?.doubleValue { settings.reconnectNonce = v }
    }

    /// Replaces only the authority, keeping the raw path/query and ws/wss scheme.
    static func buildConnectionURL(_ endpoint: String, host: String?) throws -> URL {
        guard let host else {
            guard let u = URL(string: endpoint) else { throw LarkError.invalidArgument("invalid websocket connection endpoint") }
            return u
        }
        guard let schemeEnd = endpoint.range(of: "://") else {
            throw LarkError.invalidArgument("invalid websocket connection endpoint")
        }
        let scheme = endpoint[..<schemeEnd.lowerBound]
        guard scheme == "ws" || scheme == "wss" else { throw LarkError.invalidArgument("invalid websocket connection endpoint") }
        let rest = endpoint[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        if authority.isEmpty || authority.contains("@") {
            throw LarkError.invalidArgument("invalid websocket connection endpoint")
        }
        let tail = String(rest[authorityEnd...])
        // node-sdk's pattern `^(wss?)://([^/?#]+)([^#]*)$` rejects any fragment, even an empty one.
        if tail.contains("#") { throw LarkError.invalidArgument("invalid websocket connection endpoint") }
        guard let u = URL(string: "\(scheme)://\(host)\(tail)") else {
            throw LarkError.invalidArgument("invalid websocket connection endpoint")
        }
        return u
    }

    // MARK: - Connect / reconnect

    func connect() async -> Bool {
        guard let url = settings.connectURL else { return false }
        do {
            let conn = try await openConnection(url: url)
            logger.debug("[ws] ws connect success")
            connectionID += 1
            connection = conn
            startReceiveLoop(conn, id: connectionID)
            startPingLoop(id: connectionID)
            return true
        } catch {
            logger.error("[ws] ws connect failed: \(error)")
            return false
        }
    }

    /// Opens the socket. Like node-sdk's `connect()`, the client itself owns the optional handshake
    /// watchdog, so a connector that hangs (stuck DNS / proxy / NAT path) cannot stall the client: the
    /// attempt is abandoned as a retryable failure and a connection completing later is discarded.
    nonisolated func openConnection(url: URL) async throws -> any WebSocketConnection {
        let connector = options.webSocketConnector
        let headers = connectionHeaders
        guard let timeout = options.handshakeTimeout, timeout > 0 else {
            return try await connector.connect(url: url, headers: headers, timeout: nil)
        }
        let logger = self.logger
        let attempt = HandshakeAttempt()
        return try await withCheckedThrowingContinuation { continuation in
            attempt.begin(continuation)
            let work = Task {
                do {
                    let conn = try await connector.connect(url: url, headers: headers, timeout: timeout)
                    if !attempt.finish(.success(conn)) {
                        // Lost the race with the watchdog: nobody owns this socket.
                        conn.close(force: true)
                    }
                } catch {
                    _ = attempt.finish(.failure(error))
                }
            }
            attempt.setWatchdog(
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    let ms = Int((timeout * 1000).rounded())
                    if attempt.finish(.failure(LarkError.transport(message: "handshake timeout after \(ms)ms"))) {
                        logger.error("[ws] handshake timeout after \(ms)ms")
                        work.cancel()
                    }
                })
        }
    }

    func tryConnect() async -> ConnectResult {
        lastConnectTime = Date()
        let pulled = await pullConnectConfig()
        guard case .ok = pulled else { return pulled }
        return await connect() ? .ok : .retryable
    }

    func dropConnection() {
        pingTask?.cancel()
        pingTask = nil
        clearLiveness()
        if let c = connection {
            connectionID += 1
            c.close(force: true)
            connection = nil
        }
    }

    func reconnect(isStart: Bool = false) async {
        if isConnecting && !isStart {
            logger.debug("[ws] repeat connection")
            return
        }
        isConnecting = true
        generation += 1
        let currentGeneration = generation
        reconnectTask?.cancel()
        reconnectTask = nil

        if isStart {
            dropConnection()
            let result = await tryConnect()
            isConnecting = false
            if closed {
                dropConnection()
                return
            }
            if currentGeneration != generation { return }
            switch result {
            case .ok:
                hasEverConnected = true
                options.onReady?()
                logger.info("[ws] ws client ready")
            case .fatal(let message):
                hasEverConnected = false
                terminalError = true
                options.onError?(LarkError.transport(message: message))
            case .retryable:
                logger.error("[ws] connect failed")
                await reconnect()
            }
            return
        }

        guard options.autoReconnect else {
            dropConnection()
            isConnecting = false
            if !hasEverConnected {
                terminalError = true
                options.onError?(LarkError.transport(message: "WebSocket connect failed and autoReconnect is disabled"))
            }
            return
        }

        logger.info("[ws] reconnect")
        if hasEverConnected { options.onReconnecting?() }
        dropConnection()

        let nonce = settings.reconnectNonce > 0 ? Double.random(in: 0..<settings.reconnectNonce) : 0
        nextConnectTime = Date().addingTimeInterval(nonce)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(nonce * 1_000_000_000))
            await self?.reconnectLoop(generation: currentGeneration)
        }
    }

    func reconnectLoop(generation gen: Int) async {
        var count = 0
        while !Task.isCancelled {
            guard gen == generation, !closed else { return }
            count += 1
            currentReconnectAttempts = count
            let result = await tryConnect()
            if closed {
                dropConnection()
                return
            }
            guard gen == generation else { return }
            switch result {
            case .ok:
                logger.debug("[ws] reconnect success")
                currentReconnectAttempts = 0
                if hasEverConnected {
                    options.onReconnected?()
                } else {
                    hasEverConnected = true
                    options.onReady?()
                }
                isConnecting = false
                return
            case .fatal(let message):
                isConnecting = false
                hasEverConnected = false
                terminalError = true
                options.onError?(LarkError.transport(message: message))
                return
            case .retryable:
                logger.info("[ws] unable to connect to the server after trying \(count) times")
                if settings.reconnectCount >= 0 && count >= settings.reconnectCount {
                    isConnecting = false
                    terminalError = true
                    options.onError?(LarkError.transport(message: "WebSocket reconnect exhausted after \(count) attempts"))
                    return
                }
                let interval = settings.reconnectInterval
                nextConnectTime = Date().addingTimeInterval(interval)
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 0) * 1_000_000_000))
            }
        }
    }

    // MARK: - Ping / liveness

    func startPingLoop(id: Int) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.sendPing(id: id)
                guard let interval else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
            }
        }
    }

    /// Sends a ping; returns the next interval, or nil if this connection is stale.
    func sendPing(id: Int) async -> TimeInterval? {
        guard id == connectionID, connection != nil else { return nil }
        let frame = WSFrame(
            seqID: 0, logID: 0, service: settings.serviceId, method: FrameType.control.rawValue,
            headers: [.init(key: "type", value: "ping")])
        await send(frame)
        armLiveness(id: id)
        logger.trace("[ws] ping success")
        return settings.pingInterval
    }

    func armLiveness(id: Int) {
        guard let timeout = options.pingTimeout, timeout > 0 else { return }
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.livenessExpired(id: id, timeout: timeout)
        }
    }

    func livenessExpired(id: Int, timeout: TimeInterval) async {
        guard id == connectionID else { return }
        logger.warn("[ws] no pong/inbound within \(timeout)s of last ping, terminating to trigger reconnect")
        livenessTask = nil
        await connectionLost(id: id)
    }

    func clearLiveness() {
        livenessTask?.cancel()
        livenessTask = nil
    }

    // MARK: - Receive

    func startReceiveLoop(_ conn: any WebSocketConnection, id: Int) {
        Task { [weak self] in
            while true {
                let data: Data
                do {
                    data = try await conn.receive()
                } catch {
                    await self?.connectionLost(id: id)
                    return
                }
                guard let self else { return }
                await self.received(data, id: id)
            }
        }
    }

    func connectionLost(id: Int) async {
        guard id == connectionID, !closed else { return }
        logger.debug("[ws] client closed")
        clearLiveness()
        dropConnection()
        await reconnect()
    }

    func received(_ data: Data, id: Int) async {
        guard id == connectionID else { return }
        clearLiveness()
        let frame: WSFrame
        do {
            frame = try WSFrame(serializedData: data)
        } catch {
            logger.error("[ws] failed to handle inbound frame: \(error)")
            return
        }
        switch frame.method {
        case FrameType.control.rawValue:
            handleControl(frame)
        case FrameType.data.rawValue:
            handleData(frame)
        default:
            break
        }
    }

    func handleControl(_ frame: WSFrame) {
        guard frame.header("type") == "pong", let payload = frame.payload else { return }
        logger.trace("[ws] receive pong")
        let json: JSONValue
        do {
            json = try JSONValue(data: payload)
        } catch {
            logger.error("[ws] invalid pong payload: \(error)")
            return
        }
        applyClientConfig(json)
        logger.trace("[ws] update wsConfig with pong data")
    }

    func handleData(_ frame: WSFrame) {
        let type = frame.header("type")
        guard type == "event" else { return }
        let messageId = frame.header("message_id") ?? ""
        let traceId = frame.header("trace_id") ?? ""
        let merged: Data?
        do {
            merged = try fragments.merge(
                messageId: messageId, sum: Int(frame.header("sum") ?? ""), seq: Int(frame.header("seq") ?? ""),
                traceId: traceId, data: frame.payload ?? Data(), logger: logger)
        } catch {
            logger.error("[ws] failed to merge event fragments, message_id: \(messageId); trace_id: \(traceId); error: \(error)")
            return
        }
        guard let merged else { return }
        // node-sdk parses the merged payload inside `mergeData`: invalid JSON is logged as a merge
        // failure and the frame is not acknowledged.
        let json: JSONValue
        do {
            json = try JSONValue(data: merged)
        } catch {
            logger.error("[ws] failed to merge event fragments, message_id: \(messageId); trace_id: \(traceId); error: \(error)")
            return
        }
        logger.debug(
            "[ws] receive message, message_type: event; message_id: \(messageId); trace_id: \(traceId); data: \(String(decoding: merged, as: UTF8.self))"
        )
        let dispatcher = self.dispatcher
        let logger = self.logger
        // Handle each event concurrently, like the Node SDK.
        Task { [weak self] in
            let start = Date()
            var resp: [String: JSONValue] = ["code": 200]
            do {
                if let result = try await dispatcher?.dispatch(json: json) {
                    resp["data"] = .string(Data(result.jsonString().utf8).base64EncodedString())
                }
            } catch {
                resp["code"] = 500
                logger.error("[ws] invoke event failed, message_id: \(messageId); trace_id: \(traceId); error: \(error)")
            }
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            var ack = frame
            ack.headers.append(.init(key: "biz_rt", value: String(elapsedMs)))
            ack.payload = Data(JSONValue.object(resp).jsonString().utf8)
            await self?.send(ack)
        }
    }

    func send(_ frame: WSFrame) async {
        guard let conn = connection else { return }
        do {
            try await conn.send(frame.serialized())
        } catch {
            logger.error("[ws] send data failed: \(error)")
        }
    }
}

/// Reassembles events split into several frames (`sum` / `seq` / `message_id`).
struct FragmentCache {
    struct Entry {
        var parts: [Data?]
        var traceId: String
        var created: Date
    }

    var entries: [String: Entry] = [:]
    static let expiry: TimeInterval = 10

    mutating func removeAll() { entries.removeAll() }

    /// Drops fragment sets older than ``expiry`` (node-sdk sweeps the same 10 s window on a timer).
    mutating func sweep(now: Date = Date(), logger: LoggerProxy? = nil) {
        for (k, v) in entries where now.timeIntervalSince(v.created) > Self.expiry {
            logger?.debug("\(k) event data is deleted as expired, trace_id: \(v.traceId)")
            entries[k] = nil
        }
    }

    mutating func merge(messageId: String, sum: Int?, seq: Int?, traceId: String, data: Data, logger: LoggerProxy? = nil) throws -> Data? {
        guard let sum, let seq, sum > 0, seq >= 0, seq < sum else {
            throw LarkError.invalidArgument("invalid event fragment metadata (sum: \(sum.map(String.init) ?? "nil"), seq: \(seq.map(String.init) ?? "nil"))")
        }
        let now = Date()
        sweep(now: now, logger: logger)
        if sum == 1 { return data }
        var entry = entries[messageId] ?? Entry(parts: Array(repeating: nil, count: sum), traceId: traceId, created: now)
        guard entry.parts.count == sum else {
            throw LarkError.invalidArgument(
                "invalid event fragment metadata (sum: \(sum) differs from first fragment's \(entry.parts.count), seq: \(seq))")
        }
        entry.parts[seq] = data
        if entry.parts.allSatisfy({ $0 != nil }) {
            entries[messageId] = nil
            return entry.parts.reduce(into: Data()) { $0.append($1!) }
        }
        entries[messageId] = entry
        return nil
    }
}

/// One-shot settlement shared by a handshake attempt and its watchdog.
final class HandshakeAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<any WebSocketConnection, any Error>?
    private var watchdog: Task<Void, Never>?
    private var settled = false

    func begin(_ c: CheckedContinuation<any WebSocketConnection, any Error>) {
        lock.withLock { continuation = c }
    }

    func setWatchdog(_ task: Task<Void, Never>) {
        let alreadySettled = lock.withLock { () -> Bool in
            if settled { return true }
            watchdog = task
            return false
        }
        if alreadySettled { task.cancel() }
    }

    /// Resumes the waiter once; returns false if the attempt was already settled.
    func finish(_ result: Result<any WebSocketConnection, any Error>) -> Bool {
        let pending = lock.withLock { () -> (CheckedContinuation<any WebSocketConnection, any Error>?, Task<Void, Never>?) in
            if settled { return (nil, nil) }
            settled = true
            let out = (continuation, watchdog)
            continuation = nil
            watchdog = nil
            return out
        }
        guard let c = pending.0 else { return false }
        pending.1?.cancel()
        c.resume(with: result)
        return true
    }
}
