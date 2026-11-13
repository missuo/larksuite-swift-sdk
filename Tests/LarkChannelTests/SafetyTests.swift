import Foundation
import Testing
@testable import LarkChannel
@testable import LarkCore

/// Ports of node-sdk `safety/__tests__/*.test.ts`.
@Suite struct SafetyTests {
    static func msg(_ id: String, _ content: String, chatId: String = "oc_test", chatType: ChatType = .group) -> NormalizedMessage {
        NormalizedMessage(
            messageId: id, chatId: chatId, chatType: chatType, senderId: "ou_alice", content: content, rawContentType: "text",
            createTime: Int(Date().timeIntervalSince1970 * 1000))
    }

    static func cfg(delayMs: Int = 600, maxMessages: Int = 8, maxChars: Int = 4000) -> BatchConfig {
        var c = BatchConfig.default
        c.delayMs = delayMs
        c.maxMessages = maxMessages
        c.maxChars = maxChars
        return c
    }

    // MARK: chat-pipeline.test.ts — push (batching)

    @Test func singleMessageFlushesAfterDebounce() async throws {
        let flushes = Recorder<BatchedDispatch>()
        let p = ChatPipeline(config: Self.cfg(delayMs: 300), serialOnly: false)
        await p.push(Self.msg("m1", "hello")) { flushes.append($0) }
        await sleepMillis(20)
        #expect(flushes.count == 0)
        #expect(await eventually { flushes.count == 1 })
        let f = try #require(flushes.items.first)
        #expect(f.sourceIds == ["m1"])
        #expect(f.message.content == "hello")
    }

    @Test func rapidMessagesMergeIntoOneBatch() async throws {
        let flushes = Recorder<BatchedDispatch>()
        // A generous debounce so that slow CI machines still push all three before it fires.
        let p = ChatPipeline(config: Self.cfg(delayMs: 500), serialOnly: false)
        for (id, text) in [("m1", "hello"), ("m2", "world"), ("m3", "foo")] {
            await p.push(Self.msg(id, text)) { flushes.append($0) }
        }
        #expect(await eventually { flushes.count == 1 })
        await sleepMillis(50)
        #expect(flushes.count == 1)
        let f = try #require(flushes.items.first)
        #expect(f.sourceIds == ["m1", "m2", "m3"])
        #expect(f.message.content == "hello\n\nworld\n\nfoo")
    }

    @Test func capsForceFlush() async {
        let byCount = Recorder<BatchedDispatch>()
        let p = ChatPipeline(config: Self.cfg(delayMs: 10_000, maxMessages: 2), serialOnly: false)
        await p.push(Self.msg("m1", "a")) { byCount.append($0) }
        await p.push(Self.msg("m2", "b")) { byCount.append($0) }
        #expect(await eventually { byCount.count == 1 })

        let byChars = Recorder<BatchedDispatch>()
        let p2 = ChatPipeline(config: Self.cfg(delayMs: 10_000, maxChars: 5), serialOnly: false)
        await p2.push(Self.msg("m1", "hello")) { byChars.append($0) }
        #expect(await eventually { byChars.count == 1 })
    }

    @Test func serialOnlyFlushesImmediately() async {
        let flushes = Recorder<BatchedDispatch>()
        let p = ChatPipeline(config: Self.cfg(delayMs: 1000), serialOnly: true)
        await p.push(Self.msg("m1", "a")) { flushes.append($0) }
        #expect(await eventually { flushes.count == 1 })
    }

    @Test func longBufferUsesLongDelay() async {
        let flushes = Recorder<BatchedDispatch>()
        var c = Self.cfg(delayMs: 20)
        c.longThresholdChars = 3
        c.longDelayMs = 600
        let p = ChatPipeline(config: c, serialOnly: false)
        await p.push(Self.msg("m1", "long")) { flushes.append($0) }
        await sleepMillis(60)
        #expect(flushes.count == 0)
        #expect(await eventually { flushes.count == 1 })
    }

    // MARK: chat-pipeline.test.ts — serialization

    @Test func handlersInSamePipelineRunOneAtATime() async throws {
        let order = Recorder<String>()
        let p = ChatPipeline(config: Self.cfg(delayMs: 10), serialOnly: false)
        let slow: @Sendable (String, Int) -> FlushHandler = { id, ms in
            { _ in
                order.append("\(id)-start")
                await sleepMillis(ms)
                order.append("\(id)-end")
            }
        }
        await p.push(Self.msg("m1", "a"), slow("m1", 40))
        await sleepMillis(30)
        await p.push(Self.msg("m2", "b"), slow("m2", 20))
        #expect(await eventually { order.items.contains("m2-end") })
        let o = order.items
        let m1Start = try #require(o.firstIndex(of: "m1-start"))
        let m1End = try #require(o.firstIndex(of: "m1-end"))
        let m2Start = try #require(o.firstIndex(of: "m2-start"))
        #expect(m1Start < m1End)
        #expect(m1End < m2Start)
    }

    @Test func runTasksSerializeWithPendingBatch() async throws {
        let order = Recorder<String>()
        let p = ChatPipeline(config: Self.cfg(delayMs: 30), serialOnly: false)
        await p.push(Self.msg("m1", "a")) { _ in
            await sleepMillis(50)
            order.append("batch")
        }
        try await p.run { order.append("direct") }
        #expect(order.items == ["batch", "direct"])
        #expect(await p.isIdle())
    }

    // MARK: chat-pipeline.test.ts — manager

    @Test func differentScopesRunInParallel() async throws {
        let mgr = ChatPipelineManager(config: Self.cfg(delayMs: 10))
        let order = Recorder<String>()
        async let a: Void = mgr.run("A") {
            await sleepMillis(50)
            order.append("A")
        }
        async let b: Void = mgr.run("B") {
            await sleepMillis(10)
            order.append("B")
        }
        _ = try await (a, b)
        #expect(order.items == ["B", "A"])
    }

    @Test func sameScopeSerializesAcrossPushAndRun() async throws {
        let mgr = ChatPipelineManager(config: Self.cfg(delayMs: 10))
        let order = Recorder<String>()
        await mgr.push("A", Self.msg("m1", "a")) { _ in
            await sleepMillis(30)
            order.append("push")
        }
        try await mgr.run("A") { order.append("run") }
        #expect(order.items == ["push", "run"])
    }

    @Test func mergeBatchDedupsResourcesAndMentions() {
        var a = Self.msg("m1", "a")
        a.resources = [ResourceDescriptor(type: .image, fileKey: "k1")]
        a.mentions = [MentionInfo(key: "@_1", openId: "ou_1"), MentionInfo(key: "@_x")]
        var b = Self.msg("m2", "")
        b.resources = [ResourceDescriptor(type: .image, fileKey: "k1"), ResourceDescriptor(type: .file, fileKey: "k2")]
        b.mentions = [MentionInfo(key: "@_other", openId: "ou_1"), MentionInfo(key: "@_x")]
        b.mentionedBot = true
        var c = Self.msg("m3", "c")
        c.mentionAll = true
        let m = ChatPipeline.mergeBatch([a, b, c])
        #expect(m.messageId == "m3")
        #expect(m.content == "a\n\nc")
        #expect(m.resources.map(\.fileKey) == ["k1", "k2"])
        #expect(m.mentions.map(\.key) == ["@_1", "@_x"])
        #expect(m.mentionAll && m.mentionedBot)
    }

    // MARK: dedup-cache.test.ts

    @Test func seenCacheBasics() async {
        let dedup = SeenCache(cache: DefaultLarkCache())
        #expect(await dedup.has("m1") == false)
        await dedup.add("m1")
        #expect(await dedup.has("m1"))
        #expect(await dedup.has("m2") == false)
        await dedup.dispose()
    }

    @Test func seenCacheFallsThroughToLongTermTier() async {
        let cache = DefaultLarkCache()
        _ = await cache.set("m1", value: "1", expiresAt: Date().addingTimeInterval(60), namespace: "channel:seen")
        let dedup = SeenCache(cache: cache)
        #expect(await dedup.has("m1"))
        #expect(await dedup.memoryContains("m1"))
        #expect(await dedup.has("m1"))
        await dedup.dispose()
    }

    @Test func seenCacheWritesLongTermTierWithTTL() async {
        let cache = DefaultLarkCache()
        let dedup = SeenCache(cache: cache, ttlMs: 50)
        await dedup.add("m1")
        #expect(await cache.get("m1", namespace: "channel:seen") == "1")
        await sleepMillis(80)
        #expect(await dedup.has("m1") == false)
        await dedup.dispose()
    }

    @Test func seenCacheEvictsOldest() async {
        let dedup = SeenCache(cache: DefaultLarkCache(), maxMemEntries: 3)
        for id in ["a", "b", "c", "d"] { await dedup.add(id) }
        #expect(await dedup.memoryContains("a") == false)
        #expect(await dedup.memoryContains("d"))
        // A hit refreshes the LRU position.
        _ = await dedup.has("b")
        await dedup.add("e")
        #expect(await dedup.memoryContains("b"))
        #expect(await dedup.memoryContains("c") == false)
        await dedup.dispose()
    }

    struct BrokenCache: LarkCache {
        func get(_ key: String, namespace: String?) async -> String? { nil }
        func set(_ key: String, value: String, expiresAt: Date?, namespace: String?) async -> Bool { false }
    }

    @Test func seenCacheToleratesCacheFailures() async {
        let dedup = SeenCache(cache: BrokenCache())
        await dedup.add("m1")
        #expect(await dedup.has("m1"))
        await dedup.dispose()
    }

    @Test func seenCacheSweeperRemovesExpired() async {
        let dedup = SeenCache(cache: BrokenCache(), ttlMs: 10, sweepMs: 20)
        await dedup.add("m1")
        #expect(await eventually { await dedup.memoryContains("m1") == false })
        await dedup.dispose()
    }

    // MARK: policy-gate.test.ts

    @Test func policyGroupRules() {
        #expect(PolicyGate(.init(groupAllowlist: ["oc_ok"], requireMention: false)).evaluate(Self.msg("x", "hi", chatId: "oc_other")) == .deny(.groupNotAllowed))
        var mentioned = Self.msg("x", "hi", chatId: "oc_ok")
        mentioned.mentionedBot = true
        #expect(PolicyGate(.init(groupAllowlist: ["oc_ok"], requireMention: true)).evaluate(mentioned).allowed)
        #expect(PolicyGate(.init()).evaluate(Self.msg("x", "hi")) == .deny(.noMention))
        #expect(PolicyGate(.init(requireMention: false)).evaluate(Self.msg("x", "hi")).allowed)
        var all = Self.msg("x", "hi")
        all.mentionAll = true
        #expect(PolicyGate(.init(requireMention: false)).evaluate(all) == .deny(.mentionAllBlocked))
        #expect(PolicyGate(.init(requireMention: false, respondToMentionAll: true)).evaluate(all).allowed)
        #expect(PolicyGate(.init(requireMention: false)).evaluate(Self.msg("x", "hi", chatId: "oc_anything")).allowed)
        #expect(PolicyGate(nil).evaluate(Self.msg("x", "hi")) == .deny(.noMention))
    }

    @Test func policyDmRules() {
        #expect(PolicyGate(.init()).evaluate(Self.msg("x", "hi", chatType: .p2p)).allowed)
        #expect(PolicyGate(.init(dmMode: .disabled)).evaluate(Self.msg("x", "hi", chatType: .p2p)) == .deny(.dmDisabled))
        #expect(PolicyGate(.init(dmMode: .allowlist, dmAllowlist: ["ou_bob"])).evaluate(Self.msg("x", "hi", chatType: .p2p)) == .deny(.senderNotAllowed))
        #expect(PolicyGate(.init(dmMode: .allowlist, dmAllowlist: ["ou_alice"])).evaluate(Self.msg("x", "hi", chatType: .p2p)).allowed)
        #expect(PolicyGate(.init(dmMode: .pair)).evaluate(Self.msg("x", "hi", chatType: .p2p)).allowed)
        // Anything that is not `group` follows the DM rules (like node).
        #expect(PolicyGate(.init(dmMode: .disabled)).evaluate(Self.msg("x", "hi", chatType: "topic_group")) == .deny(.dmDisabled))
    }

    @Test func policyRuntimeUpdate() {
        let g = PolicyGate(.init(requireMention: false))
        #expect(g.evaluate(Self.msg("x", "hi")).allowed)
        g.updateConfig(.init(requireMention: true))
        #expect(!g.evaluate(Self.msg("x", "hi")).allowed)
        g.updateConfig(.init(dmMode: .open))
        #expect(g.config == PolicyConfig(dmMode: .open, requireMention: true))
        g.setBotIdentity(BotIdentity(openId: "ou_b", name: "B"))
        #expect(g.botIdentity?.openId == "ou_b")
    }

    // MARK: processing-lock.test.ts

    @Test func processingLock() async {
        let lock = ProcessingLock()
        #expect(lock.acquire("m1"))
        #expect(!lock.acquire("m1"))
        lock.release("m1")
        #expect(lock.acquire("m1"))
        #expect(lock.acquire("m2"))
        #expect(!lock.acquire("m2"))
        lock.release("unknown")
        lock.dispose()
        #expect(lock.acquire("m1"))

        let short = ProcessingLock(ttlMs: 50)
        #expect(short.acquire("m1"))
        #expect(!short.acquire("m1"))
        await sleepMillis(80)
        #expect(short.acquire("m1"))
        short.dispose()
    }

    // MARK: push-action-dedup.test.ts

    static func pipeline(queue: Bool = false) -> SafetyPipeline {
        SafetyPipeline(
            config: SafetyConfig(chatQueue: .init(enabled: queue)), policy: nil, cache: DefaultLarkCache(),
            logger: LoggerProxy(level: .fatal, sink: SilentLarkLogger()), onReject: { _ in }, onMessage: { _ in })
    }

    @Test func distinctEventIdsBothExecute() async {
        let p = Self.pipeline()
        let calls = Recorder<Int>()
        await p.pushAction(#"card:m1:u1:button||{"cmd":"A"}"#, scope: "chat1") { calls.append(1) }
        await p.pushAction(#"card:m1:u1:button||{"cmd":"B"}"#, scope: "chat1") { calls.append(1) }
        #expect(calls.count == 2)
    }

    @Test func repeatedEventIdIsDeduped() async {
        let p = Self.pipeline()
        let calls = Recorder<Int>()
        let key = #"card:m2:u1:button||{"cmd":"A"}"#
        await p.pushAction(key, scope: "chat2") { calls.append(1) }
        await p.pushAction(key, scope: "chat2") { calls.append(1) }
        #expect(calls.count == 1)
    }

    @Test func throwingActionStillCommitsAndReleases() async {
        let p = Self.pipeline(queue: true)
        struct Boom: Error {}
        await p.pushAction("k", scope: "s") { throw Boom() }
        #expect(await p.seenCache.memoryContains("k"))
        #expect(p.lock.acquire("k"))
    }

    @Test func pushLightDedups() async {
        let p = Self.pipeline()
        let calls = Recorder<Int>()
        await p.pushLight("rx") { calls.append(1) }
        await p.pushLight("rx") { calls.append(1) }
        #expect(calls.count == 1)
    }

    @Test func pushMessageDropsStaleDuplicateAndRejected() async {
        let rejects = Recorder<RejectEvent>()
        let messages = Recorder<NormalizedMessage>()
        let p = SafetyPipeline(
            config: SafetyConfig(chatQueue: .init(enabled: false), staleMessageWindowMs: 60_000), policy: PolicyConfig(dmMode: .disabled),
            cache: DefaultLarkCache(), logger: LoggerProxy(level: .fatal, sink: SilentLarkLogger()),
            onReject: { rejects.append($0) }, onMessage: { messages.append($0) })
        var stale = Self.msg("old", "x", chatType: .p2p)
        stale.createTime -= 120_000
        await p.pushMessage(stale)
        await p.pushMessage(Self.msg("dm", "x", chatType: .p2p))
        #expect(rejects.items.map(\.reason) == [.dmDisabled])
        p.updatePolicy(PolicyConfig(dmMode: .open))
        await p.pushMessage(Self.msg("dm", "x", chatType: .p2p))
        #expect(await eventually { messages.count == 1 })
        #expect(await eventually { await p.seenCache.memoryContains("dm") })
        await p.pushMessage(Self.msg("dm", "x", chatType: .p2p))
        await sleepMillis(30)
        #expect(messages.count == 1)
        await p.dispose()
    }

    // MARK: stale-detector.test.ts

    @Test func staleDetector() {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        #expect(!isStale(now))
        #expect(!isStale(now - 60_000))
        #expect(isStale(now - 31 * 60_000))
        #expect(isStale(now - 60 * 60_000))
        #expect(isStale(now - 10_000, windowMs: 5_000))
        #expect(!isStale(now - 4_000, windowMs: 5_000))
        #expect(!isStale(0))
    }

    @Test func batchConfigResolution() {
        #expect(BatchConfig.resolve(nil) == BatchConfig(delayMs: 600, longThresholdChars: 1000, longDelayMs: 2000, maxMessages: 8, maxChars: 4000))
        let c = BatchConfig.resolve(SafetyConfig(batch: .init(text: .init(delayMs: 1, maxChars: 9))))
        #expect(c.delayMs == 1 && c.maxChars == 9 && c.maxMessages == 8)
    }
}
