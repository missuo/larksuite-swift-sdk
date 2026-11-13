import Foundation
import LarkCore

/// A merged batch of messages and the ids it was built from.
struct BatchedDispatch: Sendable {
    var message: NormalizedMessage
    var sourceIds: [String]
}

typealias FlushHandler = @Sendable (BatchedDispatch) async -> Void

/// Per-scope pipeline: debounced batching of IM messages plus strict
/// serialisation of all work (node-sdk `ChatPipeline`).
actor ChatPipeline {
    private let config: BatchConfig
    private let serialOnly: Bool
    private var buffer: [NormalizedMessage] = []
    private var bufferChars = 0
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    private var tail: Task<Void, Never> = Task {}
    private var pendingHandler: FlushHandler?

    init(config: BatchConfig, serialOnly: Bool) {
        self.config = config
        self.serialOnly = serialOnly
    }

    /// Buffers a message for batched dispatch.
    func push(_ msg: NormalizedMessage, _ handler: @escaping FlushHandler) {
        buffer.append(msg)
        bufferChars += JS.length(msg.content)
        if pendingHandler == nil { pendingHandler = handler }

        if buffer.count >= config.maxMessages || bufferChars >= config.maxChars {
            clearTimer()
            enqueueFlush()
            return
        }
        if config.delayMs <= 0 || serialOnly {
            clearTimer()
            enqueueFlush()
            return
        }
        clearTimer()
        let delay = bufferChars >= config.longThresholdChars ? config.longDelayMs : config.delayMs
        timerGeneration += 1
        let gen = timerGeneration
        timer = Task { [weak self] in
            await sleepMs(Double(delay))
            await self?.timerFired(gen)
        }
    }

    private func timerFired(_ gen: Int) {
        guard gen == timerGeneration, timer != nil else { return }
        timer = nil
        enqueueFlush()
    }

    /// Runs a one-shot task after any pending batch and previous tasks.
    func run<T: Sendable>(_ task: @escaping @Sendable () async throws -> T) async throws -> T {
        if !buffer.isEmpty {
            clearTimer()
            enqueueFlush()
        }
        let prev = tail
        let next = Task<T, any Error> {
            await prev.value
            return try await task()
        }
        tail = Task { _ = try? await next.value }
        return try await next.value
    }

    func flushNow() async {
        if !buffer.isEmpty {
            clearTimer()
            enqueueFlush()
        }
        await tail.value
    }

    func isIdle() -> Bool { buffer.isEmpty && timer == nil }

    func dispose() {
        clearTimer()
        buffer = []
        pendingHandler = nil
    }

    private func clearTimer() {
        if let t = timer {
            t.cancel()
            timer = nil
            timerGeneration += 1
        }
    }

    private func enqueueFlush() {
        if buffer.isEmpty { return }
        let batch = buffer
        let handler = pendingHandler
        buffer = []
        bufferChars = 0
        pendingHandler = nil
        guard let handler else { return }

        let dispatch = BatchedDispatch(message: Self.mergeBatch(batch), sourceIds: batch.map(\.messageId))
        let prev = tail
        tail = Task {
            await prev.value
            await handler(dispatch)
        }
    }

    /// Merges a batch (same chat) into one message: latest metadata, joined
    /// content, de-duplicated resources and mentions.
    static func mergeBatch(_ batch: [NormalizedMessage]) -> NormalizedMessage {
        if batch.count == 1 { return batch[0] }
        var merged = batch[batch.count - 1]
        merged.content = batch.map(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
        merged.resources = dedup(batch.flatMap(\.resources)) { $0.fileKey }
        merged.mentions = dedup(batch.flatMap(\.mentions)) { $0.openId ?? $0.key }
        merged.mentionAll = batch.contains { $0.mentionAll }
        merged.mentionedBot = batch.contains { $0.mentionedBot }
        return merged
    }

    private static func dedup<T>(_ items: [T], _ key: (T) -> String?) -> [T] {
        var seen = Set<String>()
        var out: [T] = []
        for item in items {
            guard let k = key(item) else {
                out.append(item)
                continue
            }
            if seen.contains(k) { continue }
            seen.insert(k)
            out.append(item)
        }
        return out
    }
}

/// Routes work to one ``ChatPipeline`` per scope (node-sdk `ChatPipelineManager`).
actor ChatPipelineManager {
    private let config: BatchConfig
    private var pipelines: [String: ChatPipeline] = [:]

    init(config: BatchConfig) { self.config = config }

    func push(_ scope: String, _ msg: NormalizedMessage, _ handler: @escaping FlushHandler) async {
        await getOrCreate(scope, serialOnly: false).push(msg, handler)
    }

    func pipeline(_ scope: String, serialOnly: Bool) -> ChatPipeline { getOrCreate(scope, serialOnly: serialOnly) }

    private func getOrCreate(_ scope: String, serialOnly: Bool) -> ChatPipeline {
        if let p = pipelines[scope] { return p }
        let p = ChatPipeline(config: config, serialOnly: serialOnly)
        pipelines[scope] = p
        return p
    }

    func flushAll() async {
        let all = Array(pipelines.values)
        await withTaskGroup(of: Void.self) { group in
            for p in all { group.addTask { await p.flushNow() } }
        }
    }

    func dispose() async {
        await flushAll()
        for p in pipelines.values { await p.dispose() }
        pipelines.removeAll()
    }
}

extension ChatPipelineManager {
    /// Runs `task` serialised within `scope` (after any pending batch there).
    nonisolated func run<T: Sendable>(_ scope: String, _ task: @escaping @Sendable () async throws -> T) async throws -> T {
        let p = await pipeline(scope, serialOnly: true)
        return try await p.run(task)
    }
}
