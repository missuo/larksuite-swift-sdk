import Foundation
import LarkCore

/// Defaults of the safety layer (node-sdk `safety/types.ts`).
enum SafetyDefaults {
    static let dedupTTLMs = 12 * 3_600_000
    static let dedupMaxEntries = 5000
    static let dedupSweepIntervalMs = 5 * 60_000
    static let dedupNamespace = "channel:seen"
    static let staleMs = 30 * 60_000
    static let lockTTLMs = 5 * 60_000
}

/// Debounce / batching settings for IM messages (node-sdk `BatchConfig`).
struct BatchConfig: Sendable, Equatable {
    var delayMs: Int
    var longThresholdChars: Int
    var longDelayMs: Int
    var maxMessages: Int
    var maxChars: Int

    static let `default` = BatchConfig(delayMs: 600, longThresholdChars: 1000, longDelayMs: 2000, maxMessages: 8, maxChars: 4000)

    static func resolve(_ cfg: SafetyConfig?) -> BatchConfig {
        let t = cfg?.batch?.text
        let d = BatchConfig.default
        return BatchConfig(
            delayMs: t?.delayMs ?? d.delayMs,
            longThresholdChars: t?.longThresholdChars ?? d.longThresholdChars,
            longDelayMs: t?.longDelayMs ?? d.longDelayMs,
            maxMessages: t?.maxMessages ?? d.maxMessages,
            maxChars: t?.maxChars ?? d.maxChars)
    }
}

/// `isStale`: true when `createTimeMs` is older than `windowMs` (0 / invalid → false).
func isStale(_ createTimeMs: Int, windowMs: Int = SafetyDefaults.staleMs) -> Bool {
    if createTimeMs == 0 { return false }
    return nowMs() - Double(createTimeMs) > Double(windowMs)
}

/// Insertion-ordered `[String: Double]` with O(1) amortised "oldest" eviction
/// (the JS `Map` semantics the node-sdk caches rely on).
struct OrderedExpiryMap {
    private var entries: [String: (expireAt: Double, stamp: UInt64)] = [:]
    private var order: [UInt64: String] = [:]
    private var nextStamp: UInt64 = 0
    private var oldestStamp: UInt64 = 0

    var count: Int { entries.count }

    func get(_ key: String) -> Double? { entries[key]?.expireAt }
    func has(_ key: String) -> Bool { entries[key] != nil }

    /// `map.set(k, v)` — keeps the original position when the key exists.
    mutating func set(_ key: String, _ value: Double) {
        if let e = entries[key] {
            entries[key] = (value, e.stamp)
            return
        }
        entries[key] = (value, nextStamp)
        order[nextStamp] = key
        nextStamp += 1
    }

    mutating func delete(_ key: String) {
        guard let e = entries.removeValue(forKey: key) else { return }
        order[e.stamp] = nil
    }

    /// The first key in insertion order.
    mutating func firstKey() -> String? {
        while oldestStamp < nextStamp {
            if let k = order[oldestStamp] { return k }
            oldestStamp += 1
        }
        return nil
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        oldestStamp = nextStamp
    }

    /// Keys in insertion order.
    var keysInOrder: [String] {
        order.sorted { $0.key < $1.key }.map(\.value)
    }

    mutating func removeExpired(now: Double) {
        for (k, v) in entries where v.expireAt <= now { delete(k) }
    }
}

/// Two-tier dedup cache: in-memory LRU + an injectable long-term ``LarkCache``
/// (node-sdk `SeenCache`).
actor SeenCache {
    private var memory = OrderedExpiryMap()
    private let cache: any LarkCache
    private let ttlMs: Double
    private let maxMem: Int
    private let ns: String
    private let sweeper = Locked<Task<Void, Never>?>(nil)

    init(cache: any LarkCache, ttlMs: Int? = nil, maxMemEntries: Int? = nil, sweepMs: Int? = nil, namespace: String? = nil) {
        self.cache = cache
        self.ttlMs = Double(ttlMs ?? SafetyDefaults.dedupTTLMs)
        self.maxMem = maxMemEntries ?? SafetyDefaults.dedupMaxEntries
        self.ns = namespace ?? SafetyDefaults.dedupNamespace
        let interval = Double(sweepMs ?? SafetyDefaults.dedupSweepIntervalMs)
        let task = Task { [weak self] in
            while !Task.isCancelled {
                await sleepMs(interval)
                if Task.isCancelled { return }
                await self?.sweep()
            }
        }
        sweeper.withLock { $0 = task }
    }

    deinit { sweeper.withLock { $0?.cancel() } }

    func has(_ id: String) async -> Bool {
        let now = nowMs()
        if let exp = memory.get(id), exp > now {
            // Refresh LRU position.
            memory.delete(id)
            memory.set(id, exp)
            return true
        }
        if let hit = await cache.get(id, namespace: ns), !hit.isEmpty {
            memory.set(id, now + ttlMs)
            evictIfNeeded()
            return true
        }
        return false
    }

    func add(_ id: String) async {
        let expireAt = nowMs() + ttlMs
        memory.set(id, expireAt)
        evictIfNeeded()
        _ = await cache.set(id, value: "1", expiresAt: Date(timeIntervalSince1970: expireAt / 1000), namespace: ns)
    }

    /// Whether `id` is in the memory tier (for tests).
    func memoryContains(_ id: String) -> Bool { memory.has(id) }

    private func evictIfNeeded() {
        while memory.count > maxMem {
            guard let first = memory.firstKey() else { break }
            memory.delete(first)
        }
    }

    func sweep() {
        memory.removeExpired(now: nowMs())
    }

    func dispose() {
        sweeper.withLock {
            $0?.cancel()
            $0 = nil
        }
        memory.removeAll()
    }
}

/// Short-TTL in-memory lock preventing concurrent processing of one event
/// (node-sdk `ProcessingLock`).
final class ProcessingLock: Sendable {
    private let locks = Locked(OrderedExpiryMap())
    private let ttlMs: Double
    private let sweeper: Locked<Task<Void, Never>?> = Locked(nil)

    init(ttlMs: Int = SafetyDefaults.lockTTLMs, sweepMs: Int = 60_000) {
        self.ttlMs = Double(ttlMs)
        let locks = self.locks
        let interval = Double(sweepMs)
        sweeper.withLock {
            $0 = Task {
                while !Task.isCancelled {
                    await sleepMs(interval)
                    if Task.isCancelled { return }
                    let now = nowMs()
                    locks.withLock { $0.removeExpired(now: now) }
                }
            }
        }
    }

    deinit { sweeper.withLock { $0?.cancel() } }

    /// True if acquired; false if already held and not expired.
    func acquire(_ id: String) -> Bool {
        let now = nowMs()
        return locks.withLock { m in
            if let exp = m.get(id), exp > now { return false }
            m.set(id, now + ttlMs)
            return true
        }
    }

    func release(_ id: String) {
        locks.withLock { $0.delete(id) }
    }

    func dispose() {
        sweeper.withLock {
            $0?.cancel()
            $0 = nil
        }
        locks.withLock { $0.removeAll() }
    }
}

/// Group / DM policy (node-sdk `PolicyGate`).
final class PolicyGate: Sendable {
    struct Decision: Sendable, Equatable {
        var allowed: Bool
        var reason: RejectReason?
        static let allow = Decision(allowed: true, reason: nil)
        static func deny(_ r: RejectReason) -> Decision { Decision(allowed: false, reason: r) }
    }

    private let state: Locked<(cfg: PolicyConfig, bot: BotIdentity?)>

    init(_ cfg: PolicyConfig?, bot: BotIdentity? = nil) {
        state = Locked((cfg ?? PolicyConfig(), bot))
    }

    func evaluate(_ msg: NormalizedMessage) -> Decision {
        let cfg = state.withLock { $0.cfg }
        if msg.chatType == .group { return evaluateGroup(msg, cfg) }
        return evaluateDm(msg, cfg)
    }

    private func evaluateGroup(_ msg: NormalizedMessage, _ cfg: PolicyConfig) -> Decision {
        if let allow = cfg.groupAllowlist, !allow.isEmpty, !allow.contains(msg.chatId) { return .deny(.groupNotAllowed) }
        if (cfg.requireMention ?? true) && !msg.mentionedBot { return .deny(.noMention) }
        if msg.mentionAll && !(cfg.respondToMentionAll ?? false) { return .deny(.mentionAllBlocked) }
        return .allow
    }

    private func evaluateDm(_ msg: NormalizedMessage, _ cfg: PolicyConfig) -> Decision {
        let mode = cfg.dmMode ?? .open
        if mode == .disabled { return .deny(.dmDisabled) }
        if mode == .allowlist, !(cfg.dmAllowlist ?? []).contains(msg.senderId) { return .deny(.senderNotAllowed) }
        // 'pair' is reserved upstream and treated as open.
        return .allow
    }

    func updateConfig(_ partial: PolicyConfig) { state.withLock { $0.cfg = $0.cfg.merging(partial) } }
    var config: PolicyConfig { state.withLock { $0.cfg } }
    func setBotIdentity(_ bot: BotIdentity) { state.withLock { $0.bot = bot } }
    var botIdentity: BotIdentity? { state.withLock { $0.bot } }
}
