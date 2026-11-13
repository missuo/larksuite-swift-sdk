// Port of node-sdk `channel/` (high-level bot channel).
import Foundation
import LarkCardKit
import LarkCore
import LarkIM

/// A typed channel event name (node-sdk `EventName` / `EventMap`).
///
/// ```swift
/// channel.on(.message) { msg in try await channel.send(msg.chatId, .markdown("echo: \(msg.content)")) }
/// channel.on(.reconnected) { _ in print("back online") }
/// ```
public struct LarkChannelEvent<Payload: Sendable>: Sendable, Hashable {
    public let name: String
    init(_ name: String) { self.name = name }
}

extension LarkChannelEvent where Payload == NormalizedMessage {
    /// Inbound IM messages that passed the safety pipeline (possibly batched).
    public static var message: Self { .init("message") }
}

extension LarkChannelEvent where Payload == RejectEvent {
    /// Messages rejected by the policy gate.
    public static var reject: Self { .init("reject") }
}

extension LarkChannelEvent where Payload == CardActionEvent {
    public static var cardAction: Self { .init("cardAction") }
}

extension LarkChannelEvent where Payload == ReactionEvent {
    public static var reaction: Self { .init("reaction") }
}

extension LarkChannelEvent where Payload == BotAddedEvent {
    public static var botAdded: Self { .init("botAdded") }
}

extension LarkChannelEvent where Payload == CommentEvent {
    public static var comment: Self { .init("comment") }
}

extension LarkChannelEvent where Payload == LarkChannelError {
    /// Errors raised while handling inbound events.
    public static var error: Self { .init("error") }
}

extension LarkChannelEvent where Payload == Void {
    /// The long connection dropped and is reconnecting.
    public static var reconnecting: Self { .init("reconnecting") }
    /// The long connection is back.
    public static var reconnected: Self { .init("reconnected") }
}

/// Removes a handler registered with ``LarkChannel/on(_:_:)`` (only if it was not replaced since).
public typealias Unsubscribe = @Sendable () -> Void

/// Several handlers at once (node-sdk `channel.on({ message, reject, ... })`).
public struct LarkChannelHandlers: Sendable {
    public var message: (@Sendable (NormalizedMessage) async throws -> Void)?
    public var reject: (@Sendable (RejectEvent) async throws -> Void)?
    public var cardAction: (@Sendable (CardActionEvent) async throws -> Void)?
    public var reaction: (@Sendable (ReactionEvent) async throws -> Void)?
    public var botAdded: (@Sendable (BotAddedEvent) async throws -> Void)?
    public var comment: (@Sendable (CommentEvent) async throws -> Void)?
    public var error: (@Sendable (LarkChannelError) async throws -> Void)?
    public var reconnecting: (@Sendable () async throws -> Void)?
    public var reconnected: (@Sendable () async throws -> Void)?

    public init(
        message: (@Sendable (NormalizedMessage) async throws -> Void)? = nil,
        reject: (@Sendable (RejectEvent) async throws -> Void)? = nil,
        cardAction: (@Sendable (CardActionEvent) async throws -> Void)? = nil,
        reaction: (@Sendable (ReactionEvent) async throws -> Void)? = nil,
        botAdded: (@Sendable (BotAddedEvent) async throws -> Void)? = nil,
        comment: (@Sendable (CommentEvent) async throws -> Void)? = nil,
        error: (@Sendable (LarkChannelError) async throws -> Void)? = nil,
        reconnecting: (@Sendable () async throws -> Void)? = nil,
        reconnected: (@Sendable () async throws -> Void)? = nil
    ) {
        self.message = message
        self.reject = reject
        self.cardAction = cardAction
        self.reaction = reaction
        self.botAdded = botAdded
        self.comment = comment
        self.error = error
        self.reconnecting = reconnecting
        self.reconnected = reconnected
    }
}

/// High-level bot channel over the Lark / Feishu Open Platform
/// (port of node-sdk `LarkChannel`).
///
/// - Inbound: IM messages are normalized (`content` rendered as markdown-ish
///   text, mentions resolved, resources extracted), deduplicated, filtered by
///   policy, serialised and batched per chat, then delivered to `.message`.
///   Card actions, reactions, bot-added and doc comments get their own events.
/// - Outbound: ``send(_:_:options:)`` (text / markdown / post / media / card /
///   share / sticker with chunking, retry and fallbacks) and
///   ``stream(_:_:options:)`` (streaming markdown and cards).
///
/// ```swift
/// let channel = try createLarkChannel(.init(appId: "cli_xxx", appSecret: "xxx"))
/// channel.on(.message) { msg in
///     _ = try await channel.send(msg.chatId, .markdown("**echo** \(msg.content)"), options: .init(replyTo: msg.messageId))
/// }
/// try await channel.connect()
/// ```
///
/// Differences from node-sdk:
/// - Event handlers are `async throws` closures and are always awaited by the
///   channel (node fires `reject` / `botAdded` / `error` / `reconnecting`
///   synchronously without awaiting a returned promise).
/// - ``dispatcher`` is public so webhook deployments can route requests to it
///   (or call ``handleWebhook(_:)``); node keeps it private and relies on adaptors.
public final class LarkChannel: Sendable {
    /// The underlying API client (extra User-Agent tag `channel`).
    public let rawClient: LarkClient
    /// Event dispatcher with the channel's handlers (registered on ``connect()``).
    public let dispatcher: EventDispatcher

    let options: LarkChannelOptions
    let logger: LoggerProxy
    let api: ChannelAPI
    let sender: OutboundSender
    let safety: SafetyPipeline

    private struct HandlerEntry {
        var id: UInt64
        var fn: any Sendable
    }

    private struct State {
        var botIdentity: BotIdentity?
        var wsClient: WSClient?
        var connectTask: Task<Void, any Error>?
        var connected = false
        var handlers: [String: HandlerEntry] = [:]
        var nextHandlerId: UInt64 = 0
    }

    private let state = Locked(State())

    public init(_ options: LarkChannelOptions) throws {
        self.options = options
        let sink = options.logger ?? ConsoleLarkLogger()
        let level = options.logLevel ?? .info
        self.logger = LoggerProxy(level: level, sink: sink)
        let cache = options.cache ?? DefaultLarkCache.shared

        self.rawClient = try LarkClient(
            LarkConfiguration(
                appId: options.appId, appSecret: options.appSecret, domain: options.domain, logLevel: level, logger: sink,
                cache: cache, httpClient: options.httpClient ?? URLSessionHTTPClient(), source: options.source,
                extraUserAgentTags: ["channel"]))

        self.dispatcher = EventDispatcher(
            encryptKey: options.webhook?.encryptKey ?? "", verificationToken: options.webhook?.verificationToken ?? "",
            cache: cache, logLevel: level, logger: sink)

        self.api = ChannelAPI(client: rawClient)
        self.sender = OutboundSender(api: api, config: options.outbound ?? OutboundConfig(), logger: logger)

        let stateRef = state
        let log = logger
        self.safety = SafetyPipeline(
            config: options.safety, policy: options.policy, cache: cache, logger: logger,
            onReject: { evt in
                if let h = Self.handler(stateRef, LarkChannelEvent<RejectEvent>.reject) {
                    do { try await h(evt) } catch { log.warn("channel: reject handler threw \(error)") }
                }
            },
            onMessage: { merged in
                if let h = Self.handler(stateRef, LarkChannelEvent<NormalizedMessage>.message) { try await h(merged) }
            })
    }

    // MARK: State accessors

    /// The bot's identity, resolved by ``connect()``.
    public var botIdentity: BotIdentity? {
        get { state.withLock { $0.botIdentity } }
        set { state.withLock { $0.botIdentity = newValue } }
    }

    /// The long-connection client (nil before ``connect()`` or under the webhook transport).
    public var rawWsClient: WSClient? { state.withLock { $0.wsClient } }

    // MARK: Lifecycle

    /// Resolves the bot identity, wires the event handlers and (for the
    /// WebSocket transport) waits for the first handshake (15 s timeout).
    /// Concurrent calls share one attempt; a failed attempt can be retried.
    public func connect() async throws {
        let task: Task<Void, any Error> = state.withLock { s in
            if let t = s.connectTask { return t }
            let t = Task { try await self.doConnect() }
            s.connectTask = t
            return t
        }
        do {
            try await task.value
        } catch {
            state.withLock { s in
                if s.connectTask == task { s.connectTask = nil }
            }
            throw error
        }
    }

    private func doConnect() async throws {
        let bot = try await fetchBotIdentity()
        botIdentity = bot
        safety.setBotIdentity(bot)
        registerDispatcherHandlers()
        if options.transport == .websocket {
            try await connectWebSocket(timeoutMs: 15000)
        }
        state.withLock { $0.connected = true }
    }

    /// Starts the ``WSClient`` and resolves on its first `onReady`; rejects on
    /// `onError` or after `timeoutMs`.
    func connectWebSocket(timeoutMs: Int) async throws {
        let settled = Locked(false)
        let timer = Locked<Task<Void, Never>?>(nil)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let settle: @Sendable (Result<Void, any Error>) -> Void = { result in
                let first = settled.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                timer.withLock { $0?.cancel() }
                cont.resume(with: result)
            }
            timer.withLock {
                $0 = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    if Task.isCancelled { return }
                    settle(.failure(LarkChannelError(.notConnected, "WebSocket handshake did not complete within \(timeoutMs)ms")))
                }
            }
            let stateRef = state
            let ws: WSClient
            do {
                ws = try WSClient(
                    WSClientOptions(
                        appId: options.appId, appSecret: options.appSecret, domain: options.domain,
                        logLevel: options.logLevel ?? .info, logger: options.logger ?? ConsoleLarkLogger(),
                        httpClient: options.httpClient ?? URLSessionHTTPClient(),
                        webSocketConnector: options.webSocketConnector ?? URLSessionWebSocketConnector(),
                        autoReconnect: true,
                        handshakeTimeout: options.handshakeTimeoutMs.map { Double($0) / 1000 },
                        pingTimeout: options.wsConfig?.pingTimeout,
                        source: options.source, extraUserAgentTags: ["channel"],
                        onReady: { settle(.success(())) },
                        onError: { err in
                            settle(
                                .failure(
                                    LarkChannelError(.notConnected, "WebSocket connect failed: \(Self.errorMessage(err))", cause: err)))
                        },
                        onReconnecting: {
                            Task { await Self.fireVoid(stateRef, LarkChannelEvent<Void>.reconnecting) }
                        },
                        onReconnected: {
                            Task { await Self.fireVoid(stateRef, LarkChannelEvent<Void>.reconnected) }
                        }))
            } catch {
                settle(.failure(LarkChannelError(.notConnected, "WebSocket connect failed: \(Self.errorMessage(error))", cause: error)))
                return
            }
            state.withLock { $0.wsClient = ws }
            let dispatcher = self.dispatcher
            Task { await ws.start(eventDispatcher: dispatcher) }
        }
    }

    /// Closes the long connection and flushes / disposes the safety layer.
    public func disconnect() async {
        let (connected, ws) = state.withLock { ($0.connected, $0.wsClient) }
        guard connected else { return }
        if let ws { await ws.close() }
        await safety.dispose()
        state.withLock {
            $0.connected = false
            $0.connectTask = nil
        }
    }

    /// Snapshot of the WebSocket lifecycle; nil before ``connect()`` or under the webhook transport.
    public func getConnectionStatus() async -> WSConnectionStatus? {
        guard let ws = rawWsClient else { return nil }
        return await ws.connectionStatus
    }

    /// Verifies and dispatches a webhook request (webhook transport).
    public func handleWebhook(_ request: WebhookRequest, autoChallenge: Bool = false) async -> WebhookResponse {
        await dispatcher.handleWebhook(request, autoChallenge: autoChallenge)
    }

    // MARK: Event subscription

    /// Registers the handler for `event`, replacing (with a warning) any previous one.
    @discardableResult
    public func on<P>(_ event: LarkChannelEvent<P>, _ handler: @escaping @Sendable (P) async throws -> Void) -> Unsubscribe {
        let name = event.name
        let (id, replaced) = state.withLock { s -> (UInt64, Bool) in
            let replaced = s.handlers[name] != nil
            s.nextHandlerId += 1
            s.handlers[name] = HandlerEntry(id: s.nextHandlerId, fn: handler)
            return (s.nextHandlerId, replaced)
        }
        if replaced { logger.warn("channel: handler for \"\(name)\" is being overwritten") }
        let stateRef = state
        return {
            stateRef.withLock { s in
                if s.handlers[name]?.id == id { s.handlers[name] = nil }
            }
        }
    }

    /// Registers several handlers; the returned closure removes all of them.
    @discardableResult
    public func on(_ handlers: LarkChannelHandlers) -> Unsubscribe {
        var unsubs: [Unsubscribe] = []
        if let h = handlers.message { unsubs.append(on(.message, h)) }
        if let h = handlers.reject { unsubs.append(on(.reject, h)) }
        if let h = handlers.cardAction { unsubs.append(on(.cardAction, h)) }
        if let h = handlers.reaction { unsubs.append(on(.reaction, h)) }
        if let h = handlers.botAdded { unsubs.append(on(.botAdded, h)) }
        if let h = handlers.comment { unsubs.append(on(.comment, h)) }
        if let h = handlers.error { unsubs.append(on(.error, h)) }
        if let h = handlers.reconnecting { unsubs.append(on(.reconnecting) { _ in try await h() }) }
        if let h = handlers.reconnected { unsubs.append(on(.reconnected) { _ in try await h() }) }
        let all = unsubs
        return { for u in all { u() } }
    }

    private static func handler<P>(_ state: Locked<State>, _ event: LarkChannelEvent<P>) -> (@Sendable (P) async throws -> Void)? {
        state.withLock { $0.handlers[event.name]?.fn } as? @Sendable (P) async throws -> Void
    }

    func handler<P>(_ event: LarkChannelEvent<P>) -> (@Sendable (P) async throws -> Void)? {
        Self.handler(state, event)
    }

    private static func fireVoid(_ state: Locked<State>, _ event: LarkChannelEvent<Void>) async {
        if let h = handler(state, event) { try? await h(()) }
    }

    // MARK: Outbound

    /// Sends a message to a chat (`oc_`), user (`ou_` / `on_` / user id) or email.
    public func send(_ to: String, _ input: SendInput, options: SendOptions = SendOptions()) async throws -> SendResult {
        try await sender.send(to, input, options)
    }

    /// Streams a reply (markdown typewriter card, or a patched card).
    public func stream(_ to: String, _ input: StreamInput, options: SendOptions = SendOptions()) async throws -> SendResult {
        try await sender.stream(to, input, options)
    }

    // MARK: Low-level

    /// Replaces a card message (`im.v1.message.patch`).
    public func updateCard(_ messageId: String, card: JSONValue) async throws {
        try await sender.patchCard(messageId, OrderedJSON(card))
    }

    /// Edits a sent text message (`im.v1.message.update`, `msg_type: text`).
    /// Use ``updateCard(_:card:)`` for cards.
    public func editMessage(_ messageId: String, text: String) async throws {
        try await api.messageUpdate(messageId: messageId, msgType: "text", content: OrderedJSON.obj(["text": .string(text)]).stringify())
    }

    /// Recalls a message (`im.v1.message.delete`).
    public func recallMessage(_ messageId: String) async throws {
        try await api.messageDelete(messageId: messageId)
    }

    /// Adds an emoji reaction and returns its `reaction_id`.
    public func addReaction(_ messageId: String, emojiType: String) async throws -> String {
        let r = try await api.reactionCreate(messageId: messageId, emojiType: emojiType)
        guard let rid = r.data?["reaction_id"]?.stringValue ?? r.json?["reaction_id"]?.stringValue, !rid.isEmpty else {
            throw LarkChannelError(.unknown, "messageReaction.create returned no reaction_id")
        }
        return rid
    }

    /// Removes a reaction by id (only the bot's own reactions can be removed).
    public func removeReaction(_ messageId: String, reactionId: String) async throws {
        try await api.reactionDelete(messageId: messageId, reactionId: reactionId)
    }

    /// Removes the bot's reaction with `emojiType` (lists reactions filtered by
    /// emoji, picks `operator_type == app`). Returns false when none was found.
    public func removeReactionByEmoji(_ messageId: String, emojiType: String) async throws -> Bool {
        let r = try await api.reactionList(messageId: messageId, reactionType: emojiType, pageSize: 50)
        let items = r.data?["items"]?.arrayValue ?? []
        guard let mine = items.first(where: { $0["operator"]?["operator_type"]?.stringValue == "app" }),
            let rid = mine["reaction_id"]?.stringValue, !rid.isEmpty
        else { return false }
        try await removeReaction(messageId, reactionId: rid)
        return true
    }

    /// Downloads an image (`im.v1.image.get`) or file (`im.v1.file.get`).
    public func downloadResource(_ fileKey: String, type: ResourceType) async throws -> Data {
        switch type {
        case .image: return try await api.imageGet(imageKey: fileKey).data
        case .file: return try await api.fileGet(fileKey: fileKey).data
        }
    }

    /// Chat details (`im.v1.chat.get`).
    public func getChatInfo(_ chatId: String) async throws -> ChatInfo {
        let r = try await api.chatGet(chatId: chatId)
        let d = OrderedJSON(r.data ?? .object([:]))
        return ChatInfo(
            chatId: chatId,
            name: JS.optionalString(d["name"]),
            description: JS.optionalString(d["description"]),
            chatType: ChatType(rawValue: JS.optionalString(d["chat_mode"]) ?? "group"),
            ownerId: JS.optionalString(d["owner_id"]),
            memberCount: JS.parseIntValue(JS.optionalString(d["user_count"])))
    }

    /// The chat's mode (`p2p`, `group`, `topic`; unknown → `group`). Not cached.
    public func getChatMode(_ chatId: String) async throws -> ChatMode {
        let r = try await api.chatGet(chatId: chatId)
        switch r.data?["chat_mode"]?.stringValue {
        case "p2p": return .p2p
        case "topic": return .topic
        default: return .group
        }
    }

    // MARK: Runtime config

    /// Merges `partial` into the policy (non-nil fields win); takes effect immediately.
    public func updatePolicy(_ partial: PolicyConfig) { safety.updatePolicy(partial) }

    public func getPolicy() -> PolicyConfig { safety.getPolicy() }

    // MARK: Internals

    struct PlainError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    static func errorMessage(_ e: any Error) -> String {
        if let c = e as? LarkChannelError { return c.message }
        if case .transport(let m)? = e as? LarkError { return m }
        return "\(e)"
    }

    /// `GET /open-apis/bot/v3/info`; failures are classified (auth → permission_denied,
    /// rate limit / timeout keep their codes, the rest → not_connected).
    func fetchBotIdentity() async throws -> BotIdentity {
        let lastError: any Error
        do {
            let r = try await api.botInfo()
            if let openId = JS.optionalString(OrderedJSON(r)[path: "bot", "open_id"]), !openId.isEmpty {
                return BotIdentity(openId: openId, name: JS.optionalString(OrderedJSON(r)[path: "bot", "app_name"]) ?? "bot")
            }
            lastError = PlainError(message: "bot/v3/info response missing open_id: \(JS.slice(OrderedJSON(r).stringify(), 0, 200))")
        } catch {
            lastError = error
        }
        let classified = classifyError(lastError)
        let code: LarkChannelError.Code = classified.code == .unknown ? .notConnected : classified.code
        throw LarkChannelError(
            code, "could not resolve bot identity via /open-apis/bot/v3/info — required for channel to function", cause: lastError)
    }

    /// Registers the dispatcher handlers (called by ``connect()``).
    func registerDispatcherHandlers() {
        let api = self.api
        let logger = self.logger
        let includeRaw = options.includeRawEvent ?? options._includeRawInMessage ?? false
        let normalizeOptions = NormalizeOptions(
            botIdentity: botIdentity, stripBotMentions: true, includeRaw: includeRaw,
            fetchSubMessages: { mid in
                // `im.v1.message.get` returns the parent and every descendant (with `upper_message_id`).
                do {
                    let r = try await api.messageGet(messageId: mid)
                    return (r.data?["items"]?.arrayValue ?? []).map(ApiMessageItem.init(json:))
                } catch {
                    logger.warn("channel: fetchSubMessages failed \(error)")
                    return []
                }
            })

        dispatcher.register("im.message.receive_v1") { [weak self] event in
            guard let self else { return nil }
            do {
                let msg = try await normalize(event.payload, options: normalizeOptions)
                await self.safety.pushMessage(msg)
            } catch {
                await self.emitError(error)
            }
            return nil
        }

        // Card clicks: dedup + lock + queue by chat. The key includes the
        // action identity so different buttons on one card do not collide.
        dispatcher.register("card.action.trigger") { [weak self] event in
            guard let self, let evt = normalizeCardAction(event.payload, includeRaw: includeRaw) else { return nil }
            let key = "card:\(evt.messageId):\(evt.operator.openId):\(Self.cardActionId(evt.action))"
            await self.safety.pushAction(key, scope: evt.chatId) {
                if let h = self.handler(.cardAction) { try await h(evt) }
            }
            return nil
        }

        for (type, action) in [("im.message.reaction.created_v1", ReactionAction.added), ("im.message.reaction.deleted_v1", .removed)] {
            dispatcher.register(type) { [weak self] event in
                guard let self, let evt = normalizeReaction(event.payload, action: action, includeRaw: includeRaw) else { return nil }
                await self.safety.pushLight(Self.reactionKey(evt)) {
                    if let h = self.handler(.reaction) { try await h(evt) }
                }
                return nil
            }
        }

        // Bot added: direct fire, no safety.
        dispatcher.register("im.chat.member.bot.added_v1") { [weak self] event in
            guard let self, let evt = normalizeBotAdded(event.payload, includeRaw: includeRaw) else { return nil }
            do {
                if let h = self.handler(.botAdded) { try await h(evt) }
            } catch {
                await self.emitError(error)
            }
            return nil
        }

        // Doc comments: dedup + lock + queue by file; replyId keeps thread replies apart.
        dispatcher.register("drive.notice.comment_add_v1") { [weak self] event in
            guard let self, let evt = normalizeComment(event.payload, includeRaw: includeRaw) else { return nil }
            await self.safety.pushAction("comment:\(evt.fileToken):\(evt.commentId):\(evt.replyId ?? "")", scope: evt.fileToken) {
                if let h = self.handler(.comment) { try await h(evt) }
            }
            return nil
        }
    }

    func emitError(_ e: any Error) async {
        let err = (e as? LarkChannelError) ?? LarkChannelError(.unknown, Self.errorMessage(e), cause: e)
        if let h = handler(.error) {
            try? await h(err)
        } else {
            logger.error("channel: unhandled error \(err)")
        }
    }

    static func reactionKey(_ evt: ReactionEvent) -> String {
        "rx:\(evt.messageId):\(evt.operator.openId):\(evt.emojiType):\(evt.action.rawValue):\(evt.actionTime ?? 0)"
    }

    /// `tag|name|option|value` (value serialised, clamped to 128 UTF-16 units).
    static func cardActionId(_ action: CardActionEvent.Action) -> String {
        let serialized: String
        switch action.value {
        case .string(let s)?: serialized = s
        case .none, .some(.null): serialized = "\"\""
        case .some(let v): serialized = OrderedJSON(v).stringify()
        }
        let valuePart = JS.length(serialized) > 128 ? JS.slice(serialized, 0, 128) : serialized
        return "\(action.tag)|\(action.name ?? "")|\(action.option ?? "")|\(valuePart)"
    }
}

/// Creates a channel (node-sdk `createLarkChannel`).
public func createLarkChannel(_ options: LarkChannelOptions) throws -> LarkChannel {
    try LarkChannel(options)
}
