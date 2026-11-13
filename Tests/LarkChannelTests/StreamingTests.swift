import Foundation
import Testing
@testable import LarkChannel
@testable import LarkCore

/// Stub of the sender surface used by the stream controllers (node test's `makeStubSender`).
final class StubStreamingSender: StreamingSender, @unchecked Sendable {
    let config: OutboundConfig
    let logger: LoggerProxy
    let log = CapturingLogger()
    private let lock = NSLock()
    private var cardCounter = 0
    private var messageCounter = 0
    private(set) var created: [OrderedJSON] = []
    private(set) var sentByReference: [String] = []
    struct Update { var cardId: String; var content: String; var sequence: Int }
    struct Finish { var cardId: String; var sequence: Int; var summary: String? }
    struct Snapshot { var created: Int; var sent: Int; var updates: [Update]; var finished: [Finish] }
    private(set) var updates: [Update] = []
    private(set) var finished: [Finish] = []
    private(set) var patches: [(String, OrderedJSON)] = []
    private let updateImpl: (@Sendable (Int) throws -> Void)?

    init(cap: Int = 1000, throttleMs: Int = 0, throttleChars: Int = 1, updateImpl: (@Sendable (Int) throws -> Void)? = nil) {
        self.config = OutboundConfig(streamThrottleMs: throttleMs, streamThrottleChars: throttleChars, streamMaxElementChars: cap)
        self.logger = LoggerProxy(level: .trace, sink: log)
        self.updateImpl = updateImpl
    }

    func sendOneWithFallback(_ args: RawSendArgs) async throws -> String {
        lock.withLock {
            messageCounter += 1
            return "om_\(messageCounter)"
        }
    }

    func patchCard(_ messageId: String, _ card: OrderedJSON) async throws {
        lock.withLock { patches.append((messageId, card)) }
    }

    func createCardInstance(_ spec: OrderedJSON) async throws -> String {
        lock.withLock {
            created.append(spec)
            cardCounter += 1
            return "card_\(cardCounter)"
        }
    }

    func sendCardByReference(to: String, idType: ReceiveIdType, cardId: String, opts: SendOptions) async throws -> String {
        lock.withLock {
            sentByReference.append(cardId)
            messageCounter += 1
            return "om_\(messageCounter)"
        }
    }

    func updateCardElementContent(cardId: String, elementId: String, content: String, sequence: Int) async throws {
        let n = lock.withLock {
            updates.append(Update(cardId: cardId, content: content, sequence: sequence))
            return updates.count
        }
        try updateImpl?(n)
    }

    func finishStreamingCard(cardId: String, sequence: Int, summary: String?) async throws {
        lock.withLock { finished.append(Finish(cardId: cardId, sequence: sequence, summary: summary)) }
    }

    var snapshot: Snapshot {
        lock.withLock { Snapshot(created: created.count, sent: sentByReference.count, updates: updates, finished: finished) }
    }
}

/// Port of node-sdk `outbound/__tests__/markdown-stream-rollover.test.ts`, plus
/// throttle / update-queue / card-stream unit tests.
@Suite struct StreamingTests {
    static func session(_ s: StubStreamingSender) -> MarkdownStreamSession {
        MarkdownStreamSession(sender: s, to: "oc_x", idType: .chatId, opts: SendOptions())
    }

    @Test func contentUnderCapUsesSingleCard() async throws {
        let s = StubStreamingSender(cap: 1000)
        _ = try await Self.session(s).run { c in try await c.append("hello world") }
        let snap = s.snapshot
        #expect(snap.created == 1)
        #expect(snap.sent == 1)
        #expect(snap.finished.count == 1)
        #expect(snap.updates.count >= 1)
        #expect(snap.updates.last?.content == "hello world")
    }

    @Test func contentOverCapRollsOver() async throws {
        let s = StubStreamingSender(cap: 100)
        _ = try await Self.session(s).run { c in
            try await c.append((0..<20).map { "paragraph \($0)" }.joined(separator: "\n"))
        }
        let snap = s.snapshot
        #expect(snap.created >= 2)
        #expect(snap.sent == snap.created)
        #expect(snap.finished.count == snap.created)
        #expect(snap.finished.first?.cardId == "card_1")
        #expect(snap.finished.last?.cardId == "card_\(snap.created)")
    }

    @Test func messageIdIsTheHeadCard() async throws {
        let s = StubStreamingSender(cap: 50)
        let session = Self.session(s)
        let r = try await session.run { c in try await c.append(String(repeating: "a", count: 80) + "\n" + String(repeating: "b", count: 80)) }
        #expect(r.messageId == "om_1")
        #expect(await session.messageId == "om_1")
        #expect(await session.rolloverMessageIds.isEmpty == false)
    }

    @Test func manySmallAppendsRollOver() async throws {
        let s = StubStreamingSender(cap: 200)
        _ = try await Self.session(s).run { c in
            for i in 0..<50 { try await c.append("line \(i)\n") }
        }
        #expect(s.snapshot.created >= 2)
    }

    @Test func updateFailureMarksStreamingFailedAndRunResolves() async throws {
        let s = StubStreamingSender(cap: 1000) { n in
            if n == 1 { throw LarkChannelError(.formatError, "230099 element exceeds the limit") }
        }
        let r = try await Self.session(s).run { c in
            try await c.append("first chunk")
            try await c.append("second chunk")
        }
        #expect(r.messageId == "om_1")
        #expect(s.log.count(.warn) >= 1)
        #expect(s.log.lines.contains { $0.1.hasPrefix("[stream] update failed") })
        // After the failure no further element updates are pushed.
        #expect(s.snapshot.updates.count == 1)
    }

    @Test func producerFailureAppendsFooterOnLatestCard() async throws {
        let s = StubStreamingSender(cap: 100)
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            _ = try await Self.session(s).run { c in
                try await c.append(String(repeating: "x", count: 80) + "\n" + String(repeating: "y", count: 50))
                throw Failure()
            }
        }
        let snap = s.snapshot
        let last = try #require(snap.updates.last)
        #expect(last.cardId == "card_\(snap.created)")
        #expect(last.content.contains("Generation interrupted"))
    }

    @Test func accumulatedProducerSurvivesRollover() async throws {
        let s = StubStreamingSender(cap: 100)
        _ = try await Self.session(s).run { c in
            let a = String(repeating: "a", count: 60), b = String(repeating: "b", count: 60), c2 = String(repeating: "c", count: 60)
            try await c.append(a)
            try await c.append(a + "\n" + b)
            try await c.append(a + "\n" + b + "\n" + c2)
        }
        let last = try #require(s.snapshot.updates.last).content
        #expect(last.contains(String(repeating: "c", count: 10)))
        #expect(last.components(separatedBy: String(repeating: "a", count: 10)).count - 1 <= 1)
    }

    @Test func truncateSummaryAndStreamingCard() {
        #expect(MarkdownStreamSession.truncateSummary("") == "")
        #expect(MarkdownStreamSession.truncateSummary("  a \n\t b  ") == "a b")
        #expect(MarkdownStreamSession.truncateSummary(String(repeating: "x", count: 60)) == String(repeating: "x", count: 49) + "…")
        #expect(
            MarkdownStreamSession.buildStreamingCard("Thinking...").stringify()
                == #"{"schema":"2.0","config":{"streaming_mode":true,"summary":{"content":"[Generating...]"},"streaming_config":{"print_frequency_ms":{"default":70},"print_step":{"default":1},"print_strategy":"fast"}},"body":{"elements":[{"tag":"markdown","element_id":"stream_md","content":"Thinking..."}]}}"#)
    }

    // MARK: Card stream

    @Test func cardStreamPatchesThrottledAndFooterOnFailure() async throws {
        let s = StubStreamingSender(throttleMs: 1_000_000, throttleChars: 1_000_000_000)
        let session = CardStreamSession(sender: s, to: "oc_x", idType: .chatId, opts: SendOptions(), initial: ["v": 0])
        let r = try await session.run { c in
            await c.update(["v": 1])
            await c.update { cur in ["v": .number((cur["v"]?.doubleValue ?? 0) + 1)] }
            #expect(await c.current == ["v": 2])
        }
        #expect(r.messageId == "om_1")
        // The first note schedules an immediate fire (lastFireAt starts at 0, as in node). In
        // node the producer above only awaits microtasks, so the terminal flush always wins the
        // race; in Swift the timer is a concurrent task and may also fire. Either way the last
        // patch is the final state and nothing else is patched (the 1000 s interval never elapses).
        let patches = s.patches.map { $0.1.stringify() }
        #expect(patches.last == #"{"v":2}"#)
        #expect((1...2).contains(patches.count))
        #expect(patches.allSatisfy { [#"{"v":1}"#, #"{"v":2}"#].contains($0) })

        let s2 = StubStreamingSender(throttleMs: 1_000_000, throttleChars: 1_000_000_000)
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            _ = try await CardStreamSession(sender: s2, to: "oc_x", idType: .chatId, opts: SendOptions(), initial: ["elements": [["tag": "div"]]])
                .run { c in
                    await c.update(["header": ["t": 1], "elements": [["tag": "img"]]])
                    throw Failure()
                }
        }
        // The terminal patch carries the error footer; at most one earlier (immediate-fire) patch
        // with the plain update may precede it (see above).
        let patches2 = s2.patches.map { $0.1.stringify() }
        #expect(
            patches2.last
                == #"{"elements":[{"tag":"img"},{"tag":"note","elements":[{"tag":"plain_text","content":"⚠️ 生成中断"}]}],"header":{"t":1}}"#)
        #expect(patches2.dropLast().allSatisfy { $0 == #"{"elements":[{"tag":"img"}],"header":{"t":1}}"# })
        #expect((1...2).contains(patches2.count))
    }

    @Test func appendErrorFooterShapes() {
        #expect(CardStreamSession.appendErrorFooter(.null).stringify() == #"{"elements":[{"tag":"note","elements":[{"tag":"plain_text","content":"⚠️ 生成中断"}]}]}"#)
        #expect(CardStreamSession.appendErrorFooter(["a", "b"]).keys == ["0", "1", "elements"])
    }

    // MARK: Throttle / UpdateQueue

    /// Like node, `lastFireAt` starts at 0, so the first note fires on the next tick.
    @Test func throttleFirstNoteFiresImmediatelyThenOnCharThreshold() async throws {
        let fires = Recorder<Int>()
        let t = Throttle(ms: 10_000, chars: 5)
        await t.setFire { fires.append(1) }
        await t.note(1)
        #expect(await eventually { fires.count == 1 })
        await t.note(2)  // within the interval, below the char threshold: timer scheduled
        await sleepMillis(30)
        #expect(fires.count == 1)
        await t.note(3)  // 5 chars accumulated → fire now
        #expect(await eventually { fires.count == 2 })
        await t.dispose()
    }

    @Test func throttleWaitsForTheRemainingInterval() async throws {
        let fires = Recorder<Double>()
        let t = Throttle(ms: 80, chars: 1_000)
        await t.setFire { fires.append(Date().timeIntervalSince1970) }
        // Lower bound of the throttle's internal "last fire" time (the first callback may be
        // recorded late on a slow machine, so it is not a reliable reference point).
        let beforeFirst = Date().timeIntervalSince1970
        await t.note(1)
        #expect(await eventually { fires.count == 1 })
        await t.note(1)
        await t.note(1)  // timer already scheduled
        #expect(await eventually { fires.count == 2 })
        let second = try #require(fires.items.dropFirst().first)
        #expect(second - beforeFirst >= 0.075)
        await sleepMillis(120)
        #expect(fires.count == 2)
    }

    @Test func throttleFlushNowFiresAgainAfterInFlight() async throws {
        let fires = Recorder<Int>()
        let gate = Locked(false)
        let t = Throttle(ms: 1_000_000, chars: 1)
        await t.setFire {
            fires.append(1)
            while !gate.current { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        await t.note(1)  // fires soon, blocks on the gate
        #expect(await eventually { fires.count == 1 })
        let flush = Task { try await t.flushNow() }
        await sleepMillis(20)
        gate.withLock { $0 = true }
        try await flush.value
        #expect(fires.count == 2)
    }

    @Test func throttleDisposeCancelsPendingTimer() async throws {
        let fires = Recorder<Int>()
        let t = Throttle(ms: 30, chars: 1_000)
        await t.setFire { fires.append(1) }
        await t.note(1)
        #expect(await eventually { fires.count == 1 })
        await t.note(1)  // scheduled ~30 ms out
        await t.dispose()
        await sleepMillis(80)
        #expect(fires.count == 1)
    }

    @Test func updateQueueSerializesInOrder() async throws {
        let q = UpdateQueue()
        let order = Recorder<String>()
        async let a: Void = q.enqueue {
            await sleepMillis(30)
            order.append("a")
        }
        await sleepMillis(5)
        async let b: Void = q.enqueue { order.append("b") }
        _ = try await (a, b)
        #expect(order.items == ["a", "b"])
        struct Failure: Error {}
        await #expect(throws: Failure.self) { try await q.enqueue { throw Failure() } }
        let after = try await q.enqueue { 42 }
        #expect(after == 42)
        await q.drain()
    }
}
