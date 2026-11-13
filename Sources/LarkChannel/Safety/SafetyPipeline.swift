import Foundation
import LarkCore

/// The channel's safety layer (node-sdk `SafetyPipeline`). Three tiers:
/// - ``pushMessage(_:)``: stale + dedup + policy + lock + batch + per-chat queue
/// - ``pushAction(_:scope:_:)``: dedup + lock + queue (card actions, comments)
/// - ``pushLight(_:_:)``: dedup only (reactions)
final class SafetyPipeline: Sendable {
    typealias OnReject = @Sendable (RejectEvent) async -> Void
    typealias OnMessage = @Sendable (NormalizedMessage) async throws -> Void

    let seenCache: SeenCache
    let lock: ProcessingLock
    let policy: PolicyGate
    let manager: ChatPipelineManager
    let staleWindow: Int
    let queueEnabled: Bool
    let logger: LoggerProxy
    let onReject: OnReject
    let onMessage: OnMessage

    init(
        config: SafetyConfig?, policy: PolicyConfig?, cache: any LarkCache, botIdentity: BotIdentity? = nil,
        logger: LoggerProxy, onReject: @escaping OnReject, onMessage: @escaping OnMessage
    ) {
        self.logger = logger
        self.onReject = onReject
        self.onMessage = onMessage
        self.staleWindow = config?.staleMessageWindowMs ?? SafetyDefaults.staleMs
        self.queueEnabled = config?.chatQueue?.enabled ?? true
        self.seenCache = SeenCache(
            cache: cache, ttlMs: config?.dedup?.ttl, maxMemEntries: config?.dedup?.maxEntries,
            sweepMs: config?.dedup?.sweepIntervalMs)
        self.lock = ProcessingLock()
        self.policy = PolicyGate(policy, bot: botIdentity)
        self.manager = ChatPipelineManager(config: BatchConfig.resolve(config))
    }

    // MARK: Tier 1 — IM messages

    func pushMessage(_ msg: NormalizedMessage) async {
        if isStale(msg.createTime, windowMs: staleWindow) {
            logger.debug("safety: drop stale message \(msg.messageId)")
            return
        }
        if await seenCache.has(msg.messageId) {
            logger.debug("safety: drop duplicate message \(msg.messageId)")
            return
        }
        let decision = policy.evaluate(msg)
        if !decision.allowed {
            await onReject(
                RejectEvent(messageId: msg.messageId, chatId: msg.chatId, senderId: msg.senderId, reason: decision.reason ?? .groupNotAllowed))
            return
        }
        if !lock.acquire(msg.messageId) {
            logger.debug("safety: drop in-flight message \(msg.messageId)")
            return
        }

        let onMessage = self.onMessage
        let logger = self.logger
        let seen = self.seenCache
        let lock = self.lock
        let dispatchHandler: FlushHandler = { batch in
            do {
                try await onMessage(batch.message)
            } catch {
                logger.error("safety: message handler threw \(error)")
            }
            for id in batch.sourceIds {
                await seen.add(id)
                lock.release(id)
            }
        }

        if queueEnabled {
            await manager.push(msg.chatId, msg, dispatchHandler)
        } else {
            // Queueing disabled: fire-and-forget, no batching either.
            Task { await dispatchHandler(BatchedDispatch(message: msg, sourceIds: [msg.messageId])) }
        }
    }

    // MARK: Tier 2 — card actions & comments

    func pushAction(_ eventId: String, scope: String, _ handler: @escaping @Sendable () async throws -> Void) async {
        if await seenCache.has(eventId) {
            logger.debug("safety: drop duplicate action \(eventId)")
            return
        }
        if !lock.acquire(eventId) {
            logger.debug("safety: drop in-flight action \(eventId)")
            return
        }
        let logger = self.logger
        let seen = self.seenCache
        let lock = self.lock
        let task: @Sendable () async -> Void = {
            do {
                try await handler()
            } catch {
                logger.error("safety: action handler threw \(error)")
            }
            await seen.add(eventId)
            lock.release(eventId)
        }
        if queueEnabled {
            _ = try? await manager.run(scope, task)
        } else {
            await task()
        }
    }

    // MARK: Tier 3 — reactions

    func pushLight(_ eventId: String, _ handler: @Sendable () async throws -> Void) async {
        if await seenCache.has(eventId) { return }
        await seenCache.add(eventId)
        do {
            try await handler()
        } catch {
            logger.warn("safety: light handler threw \(error)")
        }
    }

    // MARK: Runtime config

    func updatePolicy(_ partial: PolicyConfig) { policy.updateConfig(partial) }
    func getPolicy() -> PolicyConfig { policy.config }
    func setBotIdentity(_ bot: BotIdentity) { policy.setBotIdentity(bot) }

    func dispose() async {
        await manager.dispose()
        await seenCache.dispose()
        lock.dispose()
    }
}
