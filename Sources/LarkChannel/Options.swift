import Foundation
import LarkCore

/// Channel configuration (node-sdk `LarkChannelOptions`).
public struct LarkChannelOptions: Sendable {
    /// How events reach the channel.
    public enum Transport: String, Sendable {
        /// Long connection (default): ``LarkChannel/connect()`` opens a ``WSClient``.
        case websocket
        /// Webhook: plug ``LarkChannel/dispatcher`` (or ``LarkChannel/handleWebhook(_:)``) into your HTTP server.
        case webhook
    }

    public var appId: String
    public var appSecret: String
    public var transport: Transport
    public var webhook: WebhookOptions?
    public var safety: SafetyConfig?
    public var policy: PolicyConfig?
    public var outbound: OutboundConfig?
    public var logger: (any LarkLogger)?
    public var logLevel: LarkLogLevel?
    /// Long-term tier of the dedup cache (default: ``DefaultLarkCache/shared``, like node's `internalCache`).
    public var cache: (any LarkCache)?
    public var domain: LarkDomain
    /// HTTP transport (node-sdk `httpInstance`).
    public var httpClient: (any LarkHTTPClient)?
    /// Caller tag appended to the User-Agent as `source/<name>`.
    public var source: String?
    /// Client-only WebSocket settings forwarded to the ``WSClient``.
    public var wsConfig: WSConfigOverrides?
    /// Maximum time (ms) to wait for each WebSocket handshake attempt. `nil` = no timeout.
    public var handshakeTimeoutMs: Int?
    /// WebSocket transport for the long connection (Swift counterpart of node's `agent`:
    /// use it for proxies or custom TLS). Defaults to `URLSessionWebSocketConnector`.
    public var webSocketConnector: (any WebSocketConnector)?
    /// Attach the raw (flattened) event payload as `raw` on every normalized event.
    public var includeRawEvent: Bool?
    /// Deprecated alias of ``includeRawEvent``.
    @available(*, deprecated, renamed: "includeRawEvent")
    public var includeRawInMessage: Bool? {
        get { _includeRawInMessage }
        set { _includeRawInMessage = newValue }
    }
    var _includeRawInMessage: Bool?

    public init(
        appId: String,
        appSecret: String,
        transport: Transport = .websocket,
        webhook: WebhookOptions? = nil,
        safety: SafetyConfig? = nil,
        policy: PolicyConfig? = nil,
        outbound: OutboundConfig? = nil,
        logger: (any LarkLogger)? = nil,
        logLevel: LarkLogLevel? = nil,
        cache: (any LarkCache)? = nil,
        domain: LarkDomain = .feishu,
        httpClient: (any LarkHTTPClient)? = nil,
        source: String? = nil,
        wsConfig: WSConfigOverrides? = nil,
        handshakeTimeoutMs: Int? = nil,
        webSocketConnector: (any WebSocketConnector)? = nil,
        includeRawEvent: Bool? = nil
    ) {
        self.appId = appId
        self.appSecret = appSecret
        self.transport = transport
        self.webhook = webhook
        self.safety = safety
        self.policy = policy
        self.outbound = outbound
        self.logger = logger
        self.logLevel = logLevel
        self.cache = cache
        self.domain = domain
        self.httpClient = httpClient
        self.source = source
        self.wsConfig = wsConfig
        self.handshakeTimeoutMs = handshakeTimeoutMs
        self.webSocketConnector = webSocketConnector
        self.includeRawEvent = includeRawEvent
    }
}

/// Client-only WebSocket settings (node-sdk `WSConfigOverrides`).
public struct WSConfigOverrides: Sendable {
    /// Seconds. Liveness watchdog after each ping; `nil` disables it.
    public var pingTimeout: Double?
    public init(pingTimeout: Double? = nil) { self.pingTimeout = pingTimeout }
}

/// Webhook verification settings (node-sdk `WebhookOptions`; the Express/Koa
/// `adapter` option has no Swift counterpart — use ``LarkChannel/handleWebhook(_:)``).
public struct WebhookOptions: Sendable {
    public var verificationToken: String?
    public var encryptKey: String?
    public init(verificationToken: String? = nil, encryptKey: String? = nil) {
        self.verificationToken = verificationToken
        self.encryptKey = encryptKey
    }
}

/// Safety layer configuration (node-sdk `SafetyConfig`).
public struct SafetyConfig: Sendable {
    public struct Dedup: Sendable {
        /// Milliseconds (default 12h).
        public var ttl: Int?
        /// In-memory entries (default 5000).
        public var maxEntries: Int?
        /// Milliseconds (default 5min).
        public var sweepIntervalMs: Int?
        public init(ttl: Int? = nil, maxEntries: Int? = nil, sweepIntervalMs: Int? = nil) {
            self.ttl = ttl
            self.maxEntries = maxEntries
            self.sweepIntervalMs = sweepIntervalMs
        }
    }

    public struct ChatQueue: Sendable {
        /// Per-chat serialization + batching (default true).
        public var enabled: Bool?
        public init(enabled: Bool? = nil) { self.enabled = enabled }
    }

    public struct Batch: Sendable {
        public struct Text: Sendable {
            public var delayMs: Int?
            public var longThresholdChars: Int?
            public var longDelayMs: Int?
            public var maxMessages: Int?
            public var maxChars: Int?
            public init(delayMs: Int? = nil, longThresholdChars: Int? = nil, longDelayMs: Int? = nil, maxMessages: Int? = nil, maxChars: Int? = nil) {
                self.delayMs = delayMs
                self.longThresholdChars = longThresholdChars
                self.longDelayMs = longDelayMs
                self.maxMessages = maxMessages
                self.maxChars = maxChars
            }
        }

        /// Accepted for parity with node-sdk, which does not use it yet.
        public struct Media: Sendable {
            public var delayMs: Int?
            public var maxItems: Int?
            public init(delayMs: Int? = nil, maxItems: Int? = nil) {
                self.delayMs = delayMs
                self.maxItems = maxItems
            }
        }

        public var text: Text?
        public var media: Media?
        public init(text: Text? = nil, media: Media? = nil) {
            self.text = text
            self.media = media
        }
    }

    public var dedup: Dedup?
    public var chatQueue: ChatQueue?
    public var batch: Batch?
    /// Messages older than this (ms) are dropped (default 30min).
    public var staleMessageWindowMs: Int?

    public init(dedup: Dedup? = nil, chatQueue: ChatQueue? = nil, batch: Batch? = nil, staleMessageWindowMs: Int? = nil) {
        self.dedup = dedup
        self.chatQueue = chatQueue
        self.batch = batch
        self.staleMessageWindowMs = staleMessageWindowMs
    }
}

/// Who may talk to the bot (node-sdk `PolicyConfig`).
public struct PolicyConfig: Sendable, Equatable {
    public enum DMMode: String, Sendable {
        case open, allowlist, pair, disabled
    }

    /// Only these chats are served (empty / nil = all).
    public var groupAllowlist: [String]?
    public var dmMode: DMMode?
    public var dmAllowlist: [String]?
    /// Group messages must mention the bot (default true).
    public var requireMention: Bool?
    /// Respond to `@all` (default false).
    public var respondToMentionAll: Bool?

    public init(
        groupAllowlist: [String]? = nil, dmMode: DMMode? = nil, dmAllowlist: [String]? = nil, requireMention: Bool? = nil,
        respondToMentionAll: Bool? = nil
    ) {
        self.groupAllowlist = groupAllowlist
        self.dmMode = dmMode
        self.dmAllowlist = dmAllowlist
        self.requireMention = requireMention
        self.respondToMentionAll = respondToMentionAll
    }

    /// `{ ...self, ...partial }` — non-nil fields of `partial` win.
    public func merging(_ partial: PolicyConfig) -> PolicyConfig {
        PolicyConfig(
            groupAllowlist: partial.groupAllowlist ?? groupAllowlist,
            dmMode: partial.dmMode ?? dmMode,
            dmAllowlist: partial.dmAllowlist ?? dmAllowlist,
            requireMention: partial.requireMention ?? requireMention,
            respondToMentionAll: partial.respondToMentionAll ?? respondToMentionAll)
    }
}

/// Outbound configuration (node-sdk `OutboundConfig`).
public struct OutboundConfig: Sendable {
    /// Markdown → post conversion.
    public enum MarkdownConverter: Sendable {
        case builtin
        /// Returns the post body to send.
        case custom(@Sendable (String) -> JSONValue)
    }

    /// SSRF guard for URL media sources (node-sdk `boolean | { allowlist }`).
    public enum SSRFGuard: Sendable {
        case enabled
        case disabled
        /// Enabled; these hostnames skip the public-IP check.
        case allowlist([String])
    }

    public struct Retry: Sendable {
        /// Default 3.
        public var maxAttempts: Int?
        /// Default 500 ms.
        public var baseDelayMs: Int?
        public init(maxAttempts: Int? = nil, baseDelayMs: Int? = nil) {
            self.maxAttempts = maxAttempts
            self.baseDelayMs = baseDelayMs
        }
    }

    /// Max characters per text/markdown message (default 3500).
    public var textChunkLimit: Int?
    public var markdownConverter: MarkdownConverter?
    /// Default 100 ms.
    public var streamThrottleMs: Int?
    /// Default 50 characters.
    public var streamThrottleChars: Int?
    /// Placeholder shown before the first streamed chunk (default `Thinking...`).
    public var streamInitialText: String?
    /// Per-card markdown element cap before rolling over to a new card (default 30000).
    public var streamMaxElementChars: Int?
    public var ssrfGuard: SSRFGuard?
    /// Restricts local file media sources to these directories.
    public var allowedFileDirs: [String]?
    public var retry: Retry?
    /// DNS resolver used by the SSRF guard (Swift addition; defaults to `getaddrinfo`).
    public var hostResolver: (any HostResolver)?

    public init(
        textChunkLimit: Int? = nil,
        markdownConverter: MarkdownConverter? = nil,
        streamThrottleMs: Int? = nil,
        streamThrottleChars: Int? = nil,
        streamInitialText: String? = nil,
        streamMaxElementChars: Int? = nil,
        ssrfGuard: SSRFGuard? = nil,
        allowedFileDirs: [String]? = nil,
        retry: Retry? = nil,
        hostResolver: (any HostResolver)? = nil
    ) {
        self.textChunkLimit = textChunkLimit
        self.markdownConverter = markdownConverter
        self.streamThrottleMs = streamThrottleMs
        self.streamThrottleChars = streamThrottleChars
        self.streamInitialText = streamInitialText
        self.streamMaxElementChars = streamMaxElementChars
        self.ssrfGuard = ssrfGuard
        self.allowedFileDirs = allowedFileDirs
        self.retry = retry
        self.hostResolver = hostResolver
    }
}
