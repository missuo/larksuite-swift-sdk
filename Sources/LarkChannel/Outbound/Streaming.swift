import Foundation
import LarkCore

/// What the stream controllers need from the sender (lets tests stub it,
/// like node-sdk's rollover tests do).
protocol StreamingSender: Sendable {
    var config: OutboundConfig { get }
    var logger: LoggerProxy { get }
    func sendOneWithFallback(_ args: RawSendArgs) async throws -> String
    func patchCard(_ messageId: String, _ card: OrderedJSON) async throws
    func createCardInstance(_ spec: OrderedJSON) async throws -> String
    func sendCardByReference(to: String, idType: ReceiveIdType, cardId: String, opts: SendOptions) async throws -> String
    func updateCardElementContent(cardId: String, elementId: String, content: String, sequence: Int) async throws
    func finishStreamingCard(cardId: String, sequence: Int, summary: String?) async throws
}

/// Port of node-sdk `streaming/update-queue.ts`: a FIFO that serialises async updates.
actor UpdateQueue {
    private var tail: Task<Void, Never> = Task {}

    func enqueue<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let prev = tail
        let task = Task<T, any Error> {
            await prev.value
            return try await op()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Waits for everything enqueued so far.
    func drain() async {
        await tail.value
    }
}

/// Port of node-sdk `streaming/throttle.ts`: fires when `ms` elapsed since the
/// last fire OR `chars` characters accumulated; `flushNow` always fires once
/// more after any in-flight fire.
actor Throttle {
    let ms: Double
    let chars: Int
    private var fire: (@Sendable () async throws -> Void)?
    private var pendingChars = 0
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    private var inFlight: Task<Void, any Error>?
    private var lastFireAt: Double = 0
    private let onTimerError: (@Sendable (any Error) -> Void)?

    init(ms: Int, chars: Int, onTimerError: (@Sendable (any Error) -> Void)? = nil) {
        self.ms = Double(ms)
        self.chars = chars
        self.onTimerError = onTimerError
    }

    /// Sets the fire callback (separate from `init` so it can capture its owner).
    func setFire(_ fire: @escaping @Sendable () async throws -> Void) { self.fire = fire }

    /// Accumulates characters and fires now, schedules a fire, or does nothing.
    func note(_ deltaChars: Int) {
        let (sum, overflow) = pendingChars.addingReportingOverflow(deltaChars)
        pendingChars = overflow ? Int.max : sum
        if pendingChars >= chars {
            fireSoon(0)
            return
        }
        if timer == nil {
            let elapsed = nowMs() - lastFireAt
            fireSoon(max(0, ms - elapsed))
        }
    }

    private func fireSoon(_ delay: Double) {
        timer?.cancel()
        timerGeneration += 1
        let gen = timerGeneration
        timer = Task { [weak self] in
            await sleepMs(delay)
            await self?.timerFired(gen)
        }
    }

    private func timerFired(_ gen: Int) async {
        guard gen == timerGeneration, timer != nil else { return }
        timer = nil
        do {
            try await doFire()
        } catch {
            onTimerError?(error)
        }
    }

    /// Force-flushes: waits for an in-flight fire, then fires once more.
    func flushNow() async throws {
        if timer != nil {
            timer?.cancel()
            timer = nil
            timerGeneration += 1
        }
        if let f = inFlight {
            _ = try? await f.value
            if inFlight == f { inFlight = nil }
        }
        try await doFire()
    }

    private func doFire() async throws {
        if inFlight != nil {
            // Someone else is firing; capture the latest state afterwards.
            fireSoon(ms)
            return
        }
        pendingChars = 0
        lastFireAt = nowMs()
        let fire = self.fire
        let task = Task<Void, any Error> { try await fire?() }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        try await task.value
    }

    func dispose() {
        timer?.cancel()
        timer = nil
        timerGeneration += 1
    }
}

// MARK: - Markdown stream

/// Port of node-sdk `streaming/markdown-stream.ts`: streaming markdown via a
/// CardKit card with `streaming_mode` (native typewriter effect), rolling
/// over to a new card when the element would exceed `streamMaxElementChars`.
actor MarkdownStreamSession: MarkdownStreamController {
    static let defaultThrottleMs = 100
    static let defaultThrottleChars = 50
    static let defaultInitial = "Thinking..."
    static let defaultEmpty = "(no content)"
    static let initialSummary = "[Generating...]"
    static let summaryMaxChars = 50
    static let errorFooter = "\n\n— _(Generation interrupted)_"
    static let defaultMaxElementChars = 30000
    static let elementId = "stream_md"

    private let sender: any StreamingSender
    private let to: String
    private let idType: ReceiveIdType
    private let opts: SendOptions
    private let maxChars: Int
    private let throttle: Throttle
    private let queue = UpdateQueue()

    /// Content of the current card's markdown element.
    private var content = ""
    /// Full upstream text (kept separately so accumulated producers merge after rollover).
    private var fullAccumulated = ""
    private var _messageId = ""
    private var cardId = ""
    private var sequence = 0
    private var started = false
    private var streamingFailed = false
    /// Message ids of every rollover card after the head.
    private(set) var rolloverMessageIds: [String] = []
    private var fireInstalled = false

    init(sender: any StreamingSender, to: String, idType: ReceiveIdType, opts: SendOptions) {
        self.sender = sender
        self.to = to
        self.idType = idType
        self.opts = opts
        let cfg = sender.config
        self.throttle = Throttle(
            ms: cfg.streamThrottleMs ?? Self.defaultThrottleMs, chars: cfg.streamThrottleChars ?? Self.defaultThrottleChars)
        self.maxChars = cfg.streamMaxElementChars ?? Self.defaultMaxElementChars
    }

    var messageId: String { _messageId }

    private func installFire() async {
        if fireInstalled { return }
        fireInstalled = true
        await throttle.setFire { [weak self] in await self?.pushContent() }
    }

    func append(_ chunk: String) async throws {
        if chunk.isEmpty { return }
        try await ensureStarted()
        let merged = MarkdownTools.mergeStreamingText(fullAccumulated, chunk)
        let delta = JS.slice(merged, JS.length(fullAccumulated))
        fullAccumulated = merged
        content += delta
        await throttle.note(JS.length(chunk))
    }

    func setContent(_ full: String) async throws {
        try await ensureStarted()
        fullAccumulated = full
        content = full
        await throttle.note(9_007_199_254_740_991)  // Number.MAX_SAFE_INTEGER
    }

    func run(_ producer: MarkdownStreamProducer) async throws -> SendResult {
        await installFire()
        try await ensureStarted()
        do {
            try await producer(self)
        } catch {
            await failTerminal()
            throw error
        }
        await completeTerminal()
        return SendResult(messageId: _messageId)
    }

    // MARK: internals

    static func truncateSummary(_ text: String, max: Int = summaryMaxChars) -> String {
        if text.isEmpty { return "" }
        let cleaned = JS.trim(JS.replace(text, whitespaceRun, with: " "))
        return JS.length(cleaned) <= max ? cleaned : JS.slice(cleaned, 0, max - 1) + "…"
    }

    private static let whitespaceRun = JS.regex("[\(JS.ws)]+")

    /// Initial card JSON for a streaming markdown reply.
    static func buildStreamingCard(_ initialText: String) -> OrderedJSON {
        .obj([
            "schema": "2.0",
            "config": .obj([
                "streaming_mode": true,
                "summary": .obj(["content": .string(initialSummary)]),
                "streaming_config": .obj([
                    "print_frequency_ms": .obj(["default": 70]),
                    "print_step": .obj(["default": 1]),
                    "print_strategy": "fast",
                ]),
            ]),
            "body": .obj([
                "elements": [
                    .obj(["tag": "markdown", "element_id": .string(elementId), "content": .string(initialText)])
                ]
            ]),
        ])
    }

    private func ensureStarted() async throws {
        if started { return }
        started = true
        let initial = sender.config.streamInitialText ?? Self.defaultInitial
        let spec = Self.buildStreamingCard(initial.isEmpty ? "..." : initial)
        cardId = try await sender.createCardInstance(spec)
        _messageId = try await sender.sendCardByReference(to: to, idType: idType, cardId: cardId, opts: opts)
    }

    private func pushContent() async {
        if cardId.isEmpty || streamingFailed { return }
        _ = try? await queue.enqueue { [self] in await self.pushTask() }
    }

    private func pushTask() async {
        if streamingFailed { return }
        do {
            try await pushSnapshot()
        } catch {
            streamingFailed = true
            sender.logger.warn("[stream] update failed \(error)")
        }
    }

    private func nextSequence() -> Int {
        sequence += 1
        return sequence
    }

    /// Rolls over until the content fits, then pushes the latest card. Runs inside a queue task.
    private func pushSnapshot() async throws {
        while JS.length(content) > maxChars {
            try await rollover()
        }
        let snapshot = content.isEmpty ? "..." : content
        try await sender.updateCardElementContent(cardId: cardId, elementId: Self.elementId, content: snapshot, sequence: nextSequence())
    }

    struct RolloverError: Error, CustomStringConvertible {
        var description: String { "rollover: content not splittable below limit" }
    }

    /// Finalises the current card with the head and starts a fresh card for the tail.
    private func rollover() async throws {
        let chunks = MarkdownTools.splitWithCodeFences(content, limit: maxChars)
        if chunks.count < 2 { throw RolloverError() }
        let head = chunks[0]
        let tail = chunks.dropFirst().joined(separator: "\n")

        try await sender.updateCardElementContent(cardId: cardId, elementId: Self.elementId, content: head, sequence: nextSequence())
        do {
            try await sender.finishStreamingCard(cardId: cardId, sequence: nextSequence(), summary: Self.truncateSummary(head))
        } catch {
            // best effort — Feishu auto-closes after 10min
        }
        let spec = Self.buildStreamingCard(tail.isEmpty ? "..." : tail)
        let newCardId = try await sender.createCardInstance(spec)
        let newMessageId = try await sender.sendCardByReference(to: to, idType: idType, cardId: newCardId, opts: opts)
        cardId = newCardId
        content = tail
        sequence = 0
        rolloverMessageIds.append(newMessageId)
    }

    private func emptyTerminalUpdate() async {
        try? await sender.updateCardElementContent(
            cardId: cardId, elementId: Self.elementId, content: Self.defaultEmpty, sequence: nextSequence())
    }

    private func completeTerminal() async {
        try? await throttle.flushNow()
        await queue.drain()
        if cardId.isEmpty { return }

        if content.isEmpty && !streamingFailed {
            _ = try? await queue.enqueue { [self] in await self.emptyTerminalUpdate() }
            await queue.drain()
        }
        do {
            try await sender.finishStreamingCard(
                cardId: cardId, sequence: nextSequence(), summary: Self.truncateSummary(content.isEmpty ? Self.defaultEmpty : content))
        } catch {
            sender.logger.warn("[stream] finishStreamingCard failed \(error)")
        }
    }

    private func failurePush() async {
        try? await pushSnapshot()
    }

    private func failTerminal() async {
        await throttle.dispose()
        if cardId.isEmpty { return }
        content += Self.errorFooter
        _ = try? await queue.enqueue { [self] in await self.failurePush() }
        await queue.drain()
        try? await sender.finishStreamingCard(cardId: cardId, sequence: nextSequence(), summary: Self.truncateSummary(content))
    }
}

// MARK: - Card stream

/// Port of node-sdk `streaming/card-stream.ts`: the producer drives full card
/// updates, applied with throttled, serialised `im.v1.message.patch` calls.
actor CardStreamSession: CardStreamController {
    private let sender: any StreamingSender
    private let to: String
    private let idType: ReceiveIdType
    private let opts: SendOptions
    private let throttle: Throttle
    private let queue = UpdateQueue()
    private var _current: JSONValue
    private var _messageId = ""

    init(sender: any StreamingSender, to: String, idType: ReceiveIdType, opts: SendOptions, initial: JSONValue) {
        self.sender = sender
        self.to = to
        self.idType = idType
        self.opts = opts
        self._current = initial
        let cfg = sender.config
        let logger = sender.logger
        self.throttle = Throttle(
            ms: cfg.streamThrottleMs ?? MarkdownStreamSession.defaultThrottleMs,
            chars: cfg.streamThrottleChars ?? MarkdownStreamSession.defaultThrottleChars,
            onTimerError: { logger.warn("[stream] card patch failed \($0)") })
    }

    var messageId: String { _messageId }
    var current: JSONValue { _current }

    func update(_ next: JSONValue) async {
        _current = next
        await throttle.note(JS.length(OrderedJSON(next).stringify()))
    }

    func update(_ transform: @Sendable (JSONValue) -> JSONValue) async {
        await update(transform(_current))
    }

    func run(_ producer: CardStreamProducer) async throws -> SendResult {
        await throttle.setFire { [weak self] in try await self?.patch() }
        _messageId = try await sender.sendOneWithFallback(
            RawSendArgs(
                to: to, idType: idType, msgType: "interactive", content: OrderedJSON(_current), replyTo: opts.replyTo,
                replyInThread: opts.replyInThread))
        do {
            try await producer(self)
        } catch {
            await failTerminal()
            throw error
        }
        try await throttle.flushNow()
        await queue.drain()
        return SendResult(messageId: _messageId)
    }

    private func patch() async throws {
        if _messageId.isEmpty { return }
        let snapshot = OrderedJSON(_current)
        let id = _messageId
        let sender = self.sender
        try await queue.enqueue { try await sender.patchCard(id, snapshot) }
    }

    private func failTerminal() async {
        await throttle.dispose()
        let withFooter = Self.appendErrorFooter(OrderedJSON(_current))
        let id = _messageId
        let sender = self.sender
        _ = try? await queue.enqueue { try? await sender.patchCard(id, withFooter) }
        await queue.drain()
    }

    /// `{ ...card, elements: [...card.elements, footerNote] }`.
    static func appendErrorFooter(_ card: OrderedJSON) -> OrderedJSON {
        var elements = card["elements"]?.arrayValue ?? []
        elements.append(
            .obj(["tag": "note", "elements": [.obj(["tag": "plain_text", "content": "⚠️ 生成中断"])]]))
        var out: OrderedJSON
        switch card {
        case .object: out = card
        case .array(let items):
            out = .object(items.enumerated().map { .init(key: String($0.offset), value: $0.element) })
        case .string(let s):
            out = .object(Array(s.utf16).enumerated().map { .init(key: String($0.offset), value: .string(String(decoding: [$0.element], as: UTF16.self))) })
        default: out = .object([])
        }
        out["elements"] = .array(elements)
        return out
    }
}
