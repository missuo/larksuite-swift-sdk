import Foundation

/// Value a handler returns to the platform (e.g. a ``CardActionResponse``).
/// Return `nil` for plain events.
public typealias LarkEventResult = (any Encodable & Sendable)?

/// Event handler signature.
public typealias LarkEventHandler = @Sendable (LarkEvent) async throws -> LarkEventResult

/// Credentials used to verify and decrypt one webhook request.
public struct WebhookCredentials: Sendable {
    public var encryptKey: String
    public var verificationToken: String
    public init(encryptKey: String, verificationToken: String) {
        self.encryptKey = encryptKey
        self.verificationToken = verificationToken
    }
}

/// Resolves credentials per webhook request (rotation, multi-tenant setups...).
public typealias WebhookCredentialsProvider = @Sendable () async throws -> WebhookCredentials

/// An incoming webhook request, independent of the HTTP framework.
public struct WebhookRequest: Sendable {
    /// Request headers (any case).
    public var headers: [String: String]
    /// Raw request body.
    public var body: Data

    public init(headers: [String: String], body: Data) {
        var h: [String: String] = [:]
        for (k, v) in headers { h[k.lowercased()] = v }
        self.headers = h
        self.body = body
    }
}

/// A response to send back for a webhook request.
public struct WebhookResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int = 200, headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    static func json(_ value: JSONValue, status: Int = 200) -> WebhookResponse {
        WebhookResponse(statusCode: status, body: Data(value.jsonString().utf8))
    }
}

/// Verifies, decrypts and parses webhook payloads (port of the Node SDK `RequestHandle`).
public struct RequestHandle: Sendable {
    public let encryptKey: String
    public let verificationToken: String
    let cipher: AESCipher?
    let logger: LoggerProxy

    public init(encryptKey: String, verificationToken: String, logger: LoggerProxy = LoggerProxy()) {
        self.encryptKey = encryptKey
        self.verificationToken = verificationToken
        self.cipher = encryptKey.isEmpty ? nil : AESCipher(encryptKey)
        self.logger = logger
    }

    /// Decodes and (if needed) decrypts a body into JSON.
    public func decryptBody(_ json: JSONValue) throws -> JSONValue {
        guard let encrypted = json["encrypt"]?.stringValue else { return json }
        guard let cipher else {
            throw LarkError.verificationFailed("encrypted payload received but encryptKey is not configured")
        }
        let plain = try cipher.decrypt(encrypted)
        var inner = try JSONValue(jsonString: plain)
        // Keep any unencrypted top-level fields (mirrors `{...decrypted, ...rest}`).
        for (k, v) in json.objectValue ?? [:] where k != "encrypt" { inner[k] = v }
        return inner
    }

    /// Checks event signature / verification token.
    public func isEventValid(_ request: WebhookRequest, json: JSONValue) -> Bool {
        if encryptKey.isEmpty {
            if verificationToken.isEmpty { return true }
            guard case .object = json else { return false }
            let token: JSONValue?
            if json["schema"] != nil || json["header"] != nil {
                token = json["header"]?["token"]
            } else {
                // An encrypted body without an encrypt key carries no top-level token and fails here.
                token = json["token"]
            }
            return Self.isVerificationTokenValid(token, verificationToken)
        }
        guard let ts = request.headers["x-lark-request-timestamp"], let nonce = request.headers["x-lark-request-nonce"],
            let signature = request.headers["x-lark-signature"]
        else { return false }
        let content = ts + nonce + encryptKey + String(decoding: request.body, as: UTF8.self)
        return LarkDigest.constantTimeEquals(LarkDigest.sha256Hex(content), signature)
    }

    /// Checks legacy card callback signatures.
    public func isCardValid(_ request: WebhookRequest, json: JSONValue) -> Bool {
        if json["encrypt"] != nil || json["schema"] != nil { return isEventValid(request, json: json) }
        if verificationToken.isEmpty { return true }
        guard let ts = request.headers["x-lark-request-timestamp"], let nonce = request.headers["x-lark-request-nonce"],
            let signature = request.headers["x-lark-signature"]
        else { return false }
        let content = ts + nonce + verificationToken + String(decoding: request.body, as: UTF8.self)
        return LarkDigest.constantTimeEquals(LarkDigest.sha1Hex(content), signature)
    }

    /// Handles the URL verification handshake. Returns the challenge response
    /// if this request is a challenge, `nil` otherwise.
    public func challengeResponse(for json: JSONValue) throws -> JSONValue? {
        let target = try decryptBody(json)
        guard target["type"] == .string("url_verification") else { return nil }
        if !verificationToken.isEmpty && !Self.isVerificationTokenValid(target["token"], verificationToken) {
            throw LarkError.verificationFailed("invalid verification token")
        }
        return Self.challengeBody(target)
    }

    /// `{ challenge: data.challenge }`; a missing challenge is omitted, like `undefined` in JSON.stringify.
    static func challengeBody(_ data: JSONValue) -> JSONValue {
        var out: [String: JSONValue] = [:]
        if let c = data["challenge"] { out["challenge"] = c }
        return .object(out)
    }

    /// Port of `isVerificationTokenValid`: only non-empty JSON strings are compared (no coercion of
    /// numbers, booleans, objects or arrays), in constant time.
    static func isVerificationTokenValid(_ token: JSONValue?, _ expected: String) -> Bool {
        guard case .string(let received)? = token, !received.isEmpty, !expected.isEmpty else { return false }
        return LarkDigest.constantTimeEquals(received, expected)
    }
}

/// Thread-safe handler registry shared by the dispatchers.
final class HandlerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: LarkEventHandler] = [:]

    func set(_ key: String, _ h: @escaping LarkEventHandler) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let existed = handlers[key] != nil
        handlers[key] = h
        return existed
    }

    func remove(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return handlers.removeValue(forKey: key) != nil
    }

    func get(_ key: String) -> LarkEventHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[key]
    }

    var keys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(handlers.keys)
    }
}

/// Routes events to registered handlers.
///
/// ```swift
/// let dispatcher = EventDispatcher()
///     .register("im.message.receive_v1") { event in
///         let msg = try event.decode(IM.MessageReceiveV1Event.self)
///         return nil
///     }
/// ```
public final class EventDispatcher: Sendable {
    public static let appTicketEvent = "app_ticket"

    public let encryptKey: String
    public let verificationToken: String
    public let credentialsProvider: WebhookCredentialsProvider?
    public let cache: any LarkCache
    public let logger: LoggerProxy
    let registry = HandlerRegistry()
    let staticHandle: RequestHandle

    public init(
        encryptKey: String = "",
        verificationToken: String = "",
        credentialsProvider: WebhookCredentialsProvider? = nil,
        cache: any LarkCache = DefaultLarkCache.shared,
        logLevel: LarkLogLevel = .info,
        logger: any LarkLogger = ConsoleLarkLogger()
    ) {
        self.encryptKey = encryptKey
        self.verificationToken = verificationToken
        self.credentialsProvider = credentialsProvider
        self.cache = cache
        self.logger = LoggerProxy(level: logLevel, sink: logger)
        self.staticHandle = RequestHandle(encryptKey: encryptKey, verificationToken: verificationToken, logger: self.logger)
        registerAppTicketHandler()
        self.logger.info("event-dispatch is ready")
    }

    private func registerAppTicketHandler() {
        let cache = self.cache
        let logger = self.logger
        _ = registry.set(Self.appTicketEvent) { event in
            if let ticket = event.payload["app_ticket"]?.stringValue, let appId = event.payload["app_id"]?.stringValue {
                _ = await cache.set(LarkCacheKey.appTicket, value: ticket, expiresAt: nil, namespace: appId)
                logger.debug("set app ticket")
            } else {
                logger.warn("response not include app ticket")
            }
            return nil
        }
    }

    // MARK: Registration

    /// Registers a handler. Re-registering a key replaces the previous handler (with a warning).
    @discardableResult
    public func register(_ eventType: String, _ handler: @escaping LarkEventHandler) -> Self {
        if registry.set(eventType, handler), eventType != Self.appTicketEvent {
            logger.warn(
                "\(eventType) handle is already registered and has been replaced, call unregister('\(eventType)') first to replace it explicitly"
            )
        }
        logger.debug("register \(eventType) handle")
        return self
    }

    /// Registers a handler that receives the flattened payload decoded as `T`.
    @discardableResult
    public func register<T: Decodable & Sendable>(
        _ eventType: String, as type: T.Type,
        _ handler: @escaping @Sendable (T, LarkEvent) async throws -> LarkEventResult
    ) -> Self {
        register(eventType) { event in try await handler(try event.decode(T.self), event) }
    }

    /// Registers a handler for a typed event key.
    @discardableResult
    public func register<T>(_ key: LarkEventKey<T>, _ handler: @escaping @Sendable (T, LarkEvent) async throws -> LarkEventResult) -> Self {
        register(key.name, as: T.self, handler)
    }

    /// Removes handlers. Removing `app_ticket` stops caching pushed app tickets.
    @discardableResult
    public func unregister(_ eventTypes: String...) -> Self {
        for key in eventTypes {
            if registry.remove(key) {
                logger.debug("unregister \(key) handle")
                if key == Self.appTicketEvent {
                    logger.warn(
                        "the built-in app_ticket handle is unregistered, pushed app tickets are no longer cached and every app_access_token request of an ISV app will miss the cache and trigger an app_ticket resend"
                    )
                }
            } else {
                logger.debug("no \(key) handle to unregister")
            }
        }
        return self
    }

    /// Registered event types.
    public var registeredEventTypes: [String] { registry.keys.sorted() }

    // MARK: Dispatch

    func handle() async throws -> RequestHandle {
        guard let provider = credentialsProvider else { return staticHandle }
        do {
            let c = try await provider()
            return RequestHandle(encryptKey: c.encryptKey, verificationToken: c.verificationToken, logger: logger)
        } catch {
            // Provider failures may contain secrets; discard the details.
            throw LarkError.verificationFailed("webhook credentials provider failed")
        }
    }

    /// Dispatches an already-trusted payload (used by the long connection).
    /// Returns the handler result encoded as JSON.
    public func dispatch(json: JSONValue) async throws -> JSONValue? {
        let body = try staticHandle.decryptBody(json)
        return try await dispatch(event: LarkEvent(body: body))
    }

    /// Dispatches a parsed event.
    public func dispatch(event: LarkEvent) async throws -> JSONValue? {
        guard let handler = registry.get(event.type) else {
            logger.warn("no \(event.type) handle")
            // Same value the Node SDK returns to the platform.
            return .string("no \(event.type) event handle")
        }
        let result = try await handler(event)
        logger.debug("execute \(event.type) handle")
        guard let result else { return nil }
        if let j = result as? JSONValue { return j }
        return try JSONValue(encoding: result)
    }

    /// Verifies and dispatches a webhook request.
    ///
    /// - Returns: the handler result, or `nil` when verification fails or there is no result.
    public func invoke(_ request: WebhookRequest, needCheck: Bool = true) async throws -> JSONValue? {
        let handle = needCheck ? try await handle() : staticHandle
        let json = try JSONValue(data: request.body)
        if needCheck && !handle.isEventValid(request, json: json) {
            logger.warn("verification failed event")
            return nil
        }
        let body = try handle.decryptBody(json)
        return try await dispatch(event: LarkEvent(body: body))
    }

    /// Full webhook handling: challenge, verification, dispatch and response encoding.
    /// Plug this into any HTTP server (Vapor, Hummingbird, SwiftNIO...).
    public func handleWebhook(_ request: WebhookRequest, autoChallenge: Bool = false) async -> WebhookResponse {
        await WebhookAdapter.handle(request, autoChallenge: autoChallenge, logger: logger, resolveHandle: { try await self.handle() }) {
            handle, json in
            if !handle.isEventValid(request, json: json) {
                self.logger.warn("verification failed event")
                return nil
            }
            return try await self.dispatch(event: LarkEvent(body: try handle.decryptBody(json)))
        }
    }
}

/// Handles legacy (HTTP) card action callbacks.
///
/// New-style `card.action.trigger` callbacks can be registered on ``EventDispatcher``
/// instead (they also work over the long connection).
public final class CardActionHandler: Sendable {
    public let encryptKey: String
    public let verificationToken: String
    public let credentialsProvider: WebhookCredentialsProvider?
    public let cache: any LarkCache
    public let logger: LoggerProxy
    let cardHandler: LarkEventHandler
    let registry = HandlerRegistry()
    let staticHandle: RequestHandle

    public init(
        encryptKey: String = "",
        verificationToken: String = "",
        credentialsProvider: WebhookCredentialsProvider? = nil,
        cache: any LarkCache = DefaultLarkCache.shared,
        logLevel: LarkLogLevel = .info,
        logger: any LarkLogger = ConsoleLarkLogger(),
        handler: @escaping LarkEventHandler
    ) {
        self.encryptKey = encryptKey
        self.verificationToken = verificationToken
        self.credentialsProvider = credentialsProvider
        self.cache = cache
        self.logger = LoggerProxy(level: logLevel, sink: logger)
        self.cardHandler = handler
        self.staticHandle = RequestHandle(encryptKey: encryptKey, verificationToken: verificationToken, logger: self.logger)
        let cache = self.cache
        let log = self.logger
        _ = registry.set(EventDispatcher.appTicketEvent) { event in
            if let ticket = event.payload["app_ticket"]?.stringValue, let appId = event.payload["app_id"]?.stringValue {
                _ = await cache.set(LarkCacheKey.appTicket, value: ticket, expiresAt: nil, namespace: appId)
                log.debug("set app ticket")
            }
            return nil
        }
        self.logger.info("card-action-handle is ready")
    }

    func handle() async throws -> RequestHandle {
        guard let provider = credentialsProvider else { return staticHandle }
        do {
            let c = try await provider()
            return RequestHandle(encryptKey: c.encryptKey, verificationToken: c.verificationToken, logger: logger)
        } catch {
            throw LarkError.verificationFailed("webhook credentials provider failed")
        }
    }

    func run(_ handle: RequestHandle, _ request: WebhookRequest, _ json: JSONValue) async -> JSONValue? {
        guard handle.isCardValid(request, json: json) else {
            logger.warn("verification failed event")
            return nil
        }
        do {
            let event = LarkEvent(body: try handle.decryptBody(json))
            let h = registry.get(event.type) ?? cardHandler
            guard let result = try await h(event) else { return nil }
            if let j = result as? JSONValue { return j }
            return try JSONValue(encoding: result)
        } catch {
            logger.error("card handler failed: \(error)")
            return nil
        }
    }

    /// Verifies and handles a card callback; returns the handler result.
    public func invoke(_ request: WebhookRequest) async throws -> JSONValue? {
        let handle = try await handle()
        return await run(handle, request, try JSONValue(data: request.body))
    }

    /// Full webhook handling (challenge, verification, dispatch, response).
    public func handleWebhook(_ request: WebhookRequest, autoChallenge: Bool = false) async -> WebhookResponse {
        await WebhookAdapter.handle(request, autoChallenge: autoChallenge, logger: logger, resolveHandle: { try await self.handle() }) {
            handle, json in await self.run(handle, request, json)
        }
    }
}

/// Framework-agnostic webhook glue (port of `adaptDefault`).
public enum WebhookAdapter {
    static func handle(
        _ request: WebhookRequest,
        autoChallenge: Bool,
        logger: LoggerProxy,
        resolveHandle: () async throws -> RequestHandle,
        invoke: (RequestHandle, JSONValue) async throws -> JSONValue?
    ) async -> WebhookResponse {
        let handle: RequestHandle
        do {
            handle = try await resolveHandle()
        } catch {
            return .json(["msg": "webhook verification failed"], status: 403)
        }
        guard let json = try? JSONValue(data: request.body) else {
            return .json(["msg": "invalid body"], status: 400)
        }
        if autoChallenge {
            do {
                if json["encrypt"] != nil && handle.encryptKey.isEmpty {
                    throw LarkError.verificationFailed("auto-challenge need encryptKey")
                }
                if let challenge = try handle.challengeResponse(for: json) {
                    return .json(challenge)
                }
            } catch {
                return .json(["msg": "webhook verification failed"], status: 403)
            }
        }
        do {
            let value = try await invoke(handle, json)
            // node: `res.end(JSON.stringify(value))` — an undefined result yields an empty body.
            guard let value else { return WebhookResponse(statusCode: 200, body: Data()) }
            return .json(value)
        } catch {
            logger.error("webhook handler failed: \(error)")
            return .json(["msg": "internal error"], status: 500)
        }
    }

    /// Validates a URL-verification request and returns its challenge response
    /// (port of `generateChallenge`).
    public static func generateChallenge(body: JSONValue, encryptKey: String, verificationToken: String = "") throws -> (
        isChallenge: Bool, challenge: JSONValue
    ) {
        if body["encrypt"] != nil && encryptKey.isEmpty {
            throw LarkError.invalidArgument("auto-challenge need encryptKey, please check for missing in dispatcher")
        }
        let handle = RequestHandle(encryptKey: encryptKey, verificationToken: verificationToken)
        if let c = try handle.challengeResponse(for: body) { return (true, c) }
        return (false, RequestHandle.challengeBody(try handle.decryptBody(body)))
    }
}
