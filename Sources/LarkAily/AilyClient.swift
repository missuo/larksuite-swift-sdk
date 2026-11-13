import Foundation
import LarkCore

// Hand-written port of node-sdk `scene/aily` (`new Aily({ client, cache })`).
// Not generated: Tools/codegen preserves this file.

extension LarkCacheKey {
    /// Cache key of the Aily session records (node-sdk `CAilySessionRecord`,
    /// `Symbol('aily-session-record')`).
    public static let ailySessionRecord = "aily-session-record"
}

/// A message returned by ``AilyClient`` (node-sdk: an element of `ailySessionAilyMessage.list`).
public typealias AilyMessage = Aily.AilySessionAilyMessageListResponseMessage

/// Outcome codes of an Aily completion (node-sdk `EExecStatus`).
///
/// node-sdk rejects with the bare number; Swift throws the matching case.
public enum AilyExecStatus: Int, Error, Sendable, CaseIterable {
    case error = -1
    case success = 0
    case expired = 1
    case cancelled = 2
    case failed = 3
    case other = 4
}

/// Parameters of ``AilyClient/Completions/create(_:options:)`` (node-sdk `ICreateParams`).
public struct AilyCompletionParams: Sendable {
    /// Your own conversation key. When set, the Aily session created for it is remembered in
    /// the session records and reused by later calls with the same key.
    public var sessionId: String?
    /// Body of the session creation (`aily_session.create`).
    public var sessionInfo: Aily.AilySessionCreateBody?
    /// Message content, sent as `content` with `content_type: "MDX"`.
    public var message: String
    /// Extra message fields (everything but `idempotent_id`, `content_type` and `content`).
    public var messageInfo: AilyMessageInfo?
    /// Aily app id (`app_id` of the run).
    public var ailyAppId: String
    /// Skill id (`skill_id` of the run).
    public var skillId: String?
    /// Extra run fields (everything but `app_id` and `skill_id`).
    public var runInfo: AilyRunInfo?

    public init(
        sessionId: String? = nil,
        sessionInfo: Aily.AilySessionCreateBody? = nil,
        message: String,
        messageInfo: AilyMessageInfo? = nil,
        ailyAppId: String,
        skillId: String? = nil,
        runInfo: AilyRunInfo? = nil
    ) {
        self.sessionId = sessionId
        self.sessionInfo = sessionInfo
        self.message = message
        self.messageInfo = messageInfo
        self.ailyAppId = ailyAppId
        self.skillId = skillId
        self.runInfo = runInfo
    }
}

/// Optional message fields (`Omit<message.create data, 'idempotent_id' | 'content_type' | 'content'>`).
public struct AilyMessageInfo: Sendable {
    public var fileIds: [String]?
    public var quoteMessageId: String?
    public var mentions: [Aily.Mention]?

    public init(fileIds: [String]? = nil, quoteMessageId: String? = nil, mentions: [Aily.Mention]? = nil) {
        self.fileIds = fileIds
        self.quoteMessageId = quoteMessageId
        self.mentions = mentions
    }
}

/// Optional run fields (`Omit<run.create data, 'app_id' | 'skill_id'>`).
public struct AilyRunInfo: Sendable {
    public var skillInput: String?
    public var metadata: String?

    public init(skillInput: String? = nil, metadata: String? = nil) {
        self.skillInput = skillInput
        self.metadata = metadata
    }
}

/// Talks to a Feishu Aily app in one call (node-sdk `Aily`).
///
/// ```swift
/// let aily = AilyClient(client: client)
/// let reply = try await aily.completions.create(.init(sessionId: chatId, message: "hello", ailyAppId: "spring_xxx__c"))
/// print(reply.content ?? "")
///
/// for try await chunk in try await aily.completions.createWithStream(.init(message: "hi", ailyAppId: "spring_xxx__c")) {
///     print(chunk.content ?? "")
/// }
/// ```
///
/// Each completion: resolves the Aily session (from the session records when `sessionId` is
/// known, otherwise `aily_session.create`), posts the message, creates a run, polls the run
/// every 500 ms until it leaves `QUEUED` / `IN_PROGRESS`, then reads the run's messages.
///
/// Errors: ``AilyExecStatus`` (`.error` when a step fails with a business error or returns no
/// id, the terminal run status otherwise, `.failed` when polling the run fails with a business
/// error); transport errors propagate as ``LarkError``.
///
/// Deviations from node-sdk:
/// - Business errors (`code != 0`) are thrown by the generated client in Swift; they are caught
///   and mapped exactly as node-sdk maps a `code != 0` response.
/// - A transport error while polling the run is rethrown; node-sdk leaves the promise pending
///   forever (the rejection escapes its `setTimeout` callback).
/// - Cancelling the calling task stops the polling with `CancellationError`.
/// - Each iteration of the ``AilyMessageStream`` keeps its own state; node-sdk shares the
///   "output started" flag across iterations of the returned iterable.
public final class AilyClient: Sendable {
    public let client: LarkClient
    /// Holds the session records (``LarkCacheKey/ailySessionRecord``). Defaults to a fresh
    /// ``AilySessionCache``, which merges on `set`.
    public let cache: any LarkCache
    public let logger: LoggerProxy
    /// Delay before each run status check (node-sdk: 500 ms).
    let pollInterval: Duration

    public convenience init(client: LarkClient, cache: (any LarkCache)? = nil) {
        self.init(client: client, cache: cache, pollInterval: .milliseconds(500))
    }

    init(client: LarkClient, cache: (any LarkCache)?, pollInterval: Duration) {
        self.client = client
        self.logger = client.logger
        self.cache = cache ?? AilySessionCache()
        self.pollInterval = pollInterval
    }

    /// node-sdk `aily.completions`.
    public var completions: Completions { Completions(aily: self) }

    public struct Completions: Sendable {
        let aily: AilyClient

        /// Sends `message` and returns the last `ASSISTANT` message of the run.
        public func create(_ params: AilyCompletionParams, options: RequestOptions = .none) async throws -> AilyMessage {
            try await aily.create(params, options: options)
        }

        /// Sends `message`, waits for the run to finish, and streams the messages produced after
        /// the sent message (partial messages included) up to the first `COMPLETED` one.
        public func createWithStream(_ params: AilyCompletionParams, options: RequestOptions = .none) async throws -> AilyMessageStream {
            try await aily.createWithStream(params, options: options)
        }

        /// Access to the `sessionId` → Aily session id records.
        public var sessionRecords: SessionRecords { SessionRecords(aily: aily) }
    }

    public struct SessionRecords: Sendable {
        let aily: AilyClient

        /// All records (`sessionId` → Aily session id). The cached value is a JSON object;
        /// scalar values are read as strings, objects / arrays are skipped, and an unreadable
        /// value yields no records.
        public func get() async -> [String: String] { await aily.getRecords() }

        /// Writes records through the cache's `set` (merged by the default ``AilySessionCache``).
        public func update(_ records: [String: String]) async { await aily.updateRecords(records) }
    }

    // MARK: - Steps

    private func getSessionId(
        sessionId: String?, payload: Aily.AilySessionCreateBody?, options: RequestOptions
    ) async throws -> String? {
        let records = await getRecords()
        if let sessionId, !sessionId.isEmpty, let existing = records[sessionId] {
            return existing
        }

        let response: LarkResponse<Aily.AilySessionCreateResponse>
        do {
            response = try await client.aily.v1.ailySession.create(body: payload ?? .init(), options: options)
        } catch LarkError.api(let e) {
            logger.error("get aily session id error \(e.msg)")
            return nil
        }
        guard response.code == 0, response.data != nil else {
            logger.error("get aily session id error \(response.msg)")
            return nil
        }
        let ailySessionId = Self.string(response.json, "data", "session", "id")
        if let sessionId, !sessionId.isEmpty, let ailySessionId {
            await updateRecords([sessionId: ailySessionId])
        }
        return ailySessionId
    }

    private struct RunRef {
        var ailySessionId: String
        var runId: String
        var messageId: String?
    }

    private func waitReply(_ params: AilyCompletionParams, options: RequestOptions) async throws -> RunRef {
        // step1: get the aily session id
        guard
            let ailySessionId = try await getSessionId(
                sessionId: params.sessionId, payload: params.sessionInfo, options: options),
            !ailySessionId.isEmpty
        else { throw AilyExecStatus.error }

        // step2: create the message and the run
        let messageBody = Aily.AilySessionAilyMessageCreateBody(
            idempotentId: String(Int64(Date().timeIntervalSince1970 * 1000)),
            contentType: .mDX,
            content: params.message,
            fileIds: params.messageInfo?.fileIds,
            quoteMessageId: params.messageInfo?.quoteMessageId,
            mentions: params.messageInfo?.mentions)
        let message: LarkResponse<Aily.AilySessionAilyMessageCreateResponse>
        do {
            message = try await client.aily.v1.ailySessionAilyMessage.create(
                ailySessionId: ailySessionId, body: messageBody, options: options)
        } catch LarkError.api(let e) {
            logger.error("create aily message error \(e.msg)")
            throw AilyExecStatus.error
        }
        guard message.code == 0, message.data != nil else {
            logger.error("create aily message error \(message.msg)")
            throw AilyExecStatus.error
        }
        let messageId = Self.string(message.json, "data", "message", "id")

        let runBody = Aily.AilySessionRunCreateBody(
            appId: params.ailyAppId,
            skillId: params.skillId,
            skillInput: params.runInfo?.skillInput,
            metadata: params.runInfo?.metadata)
        let run: LarkResponse<Aily.AilySessionRunCreateResponse>
        do {
            run = try await client.aily.v1.ailySessionRun.create(ailySessionId: ailySessionId, body: runBody, options: options)
        } catch LarkError.api(let e) {
            logger.error("create aily session run error \(e.msg)")
            throw AilyExecStatus.error
        }
        guard run.code == 0, run.data != nil else {
            logger.error("create aily session run error \(run.msg)")
            throw AilyExecStatus.error
        }
        guard let runId = Self.string(run.json, "data", "run", "id"), !runId.isEmpty else {
            logger.error("run id is empty")
            throw AilyExecStatus.error
        }

        // step3: wait for the run to complete
        let status = try await pollRun(ailySessionId: ailySessionId, runId: runId, options: options)
        if status != .success {
            logger.error("aily run error")
            throw status
        }
        return RunRef(ailySessionId: ailySessionId, runId: runId, messageId: messageId)
    }

    /// Checks the run every ``pollInterval`` (the first check also waits) until it settles.
    private func pollRun(ailySessionId: String, runId: String, options: RequestOptions) async throws -> AilyExecStatus {
        while true {
            try await Task.sleep(for: pollInterval)
            let info: LarkResponse<Aily.AilySessionRunGetResponse>
            do {
                info = try await client.aily.v1.ailySessionRun.get(ailySessionId: ailySessionId, runId: runId, options: options)
            } catch LarkError.api {
                return .failed
            }
            guard info.code == 0, info.data != nil else { return .failed }

            switch Self.string(info.json, "data", "run", "status") {
            case "QUEUED", "IN_PROGRESS": continue
            case "COMPLETED": return .success
            case "EXPIRED": return .expired
            case "CANCELLED": return .cancelled
            case "FAILED": return .failed
            default: return .other
            }
        }
    }

    func create(_ params: AilyCompletionParams, options: RequestOptions) async throws -> AilyMessage {
        let ref = try await waitReply(params, options: options)

        var reply: AilyMessage?
        let pages = client.aily.v1.ailySessionAilyMessage.listWithIterator(
            ailySessionId: ref.ailySessionId,
            params: .init(runId: ref.runId, withPartialMessage: false),
            options: options)
        for try await page in pages {
            for message in page.messages ?? [] where message.sender?.senderType == .aSSISTANT {
                reply = message
            }
        }
        guard let reply else {
            logger.error("no aily reply")
            throw AilyExecStatus.error
        }
        return reply
    }

    func createWithStream(_ params: AilyCompletionParams, options: RequestOptions) async throws -> AilyMessageStream {
        let ref = try await waitReply(params, options: options)
        let pages = client.aily.v1.ailySessionAilyMessage.listWithIterator(
            ailySessionId: ref.ailySessionId,
            params: .init(runId: ref.runId, withPartialMessage: true),
            options: options)
        return AilyMessageStream(pages: pages, messageId: ref.messageId)
    }

    // MARK: - Session records

    func getRecords() async -> [String: String] {
        guard let raw = await cache.get(LarkCacheKey.ailySessionRecord),
            let json = try? JSONValue(jsonString: raw),
            case .object(let object) = json
        else { return [:] }
        return object.compactMapValues { $0.stringValue }
    }

    func updateRecords(_ records: [String: String]) async {
        let value = JSONValue.object(records.mapValues(JSONValue.string)).jsonString()
        await cache.set(LarkCacheKey.ailySessionRecord, value: value)
    }

    /// Reads a string at `path` of the raw response body, like node-sdk's optional chaining
    /// (`res.data.session?.id`): independent of the other fields the typed models require.
    private static func string(_ json: JSONValue?, _ path: String...) -> String? {
        var cur = json
        for key in path { cur = cur?[key] }
        return cur?.stringValue
    }
}

/// The messages streamed by ``AilyClient/Completions/createWithStream(_:options:)``.
///
/// Walks the run's messages (`with_partial_message: true`): output starts after the sent
/// message is seen `COMPLETED`, then every message is yielded until one is `COMPLETED`.
public struct AilyMessageStream: AsyncSequence, Sendable {
    public typealias Element = AilyMessage

    let pages: LarkPageSequence<Aily.AilySessionAilyMessageListResponse>
    let messageId: String?

    public struct AsyncIterator: AsyncIteratorProtocol {
        var pages: LarkPageSequence<Aily.AilySessionAilyMessageListResponse>.AsyncIterator
        let messageId: String?
        var buffer: [AilyMessage] = []
        var index = 0
        var startOutput = false
        var finished = false

        public mutating func next() async throws -> AilyMessage? {
            while !finished {
                if index < buffer.count {
                    let message = buffer[index]
                    index += 1
                    if startOutput {
                        if message.status == .cOMPLETED { finished = true }
                        return message
                    } else if message.id == messageId && message.status == .cOMPLETED {
                        startOutput = true
                    }
                    continue
                }
                guard let page = try await pages.next() else {
                    finished = true
                    return nil
                }
                buffer = page.messages ?? []
                index = 0
            }
            return nil
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(pages: pages.makeAsyncIterator(), messageId: messageId)
    }
}

/// The default session-record store of ``AilyClient`` (node-sdk `SessionCache`).
///
/// Values are JSON objects; `set` merges the new object's keys into the stored one (node-sdk
/// `mergeObject`: keys whose value is `undefined` are skipped, which in JSON means absent).
/// Like node-sdk, `expiresAt` and `namespace` are ignored. A value that is not a JSON object
/// replaces the stored value.
public actor AilySessionCache: LarkCache {
    private var sessions: [String: String] = [:]

    public init() {}

    public func get(_ key: String, namespace: String?) async -> String? {
        sessions[key]
    }

    @discardableResult
    public func set(_ key: String, value: String, expiresAt: Date?, namespace: String?) async -> Bool {
        guard case .object(let incoming)? = try? JSONValue(jsonString: value) else {
            sessions[key] = value
            return true
        }
        var merged: [String: JSONValue] = [:]
        if let existing = sessions[key], case .object(let current)? = try? JSONValue(jsonString: existing) {
            merged = current
        }
        merged.merge(incoming) { _, new in new }
        sessions[key] = JSONValue.object(merged).jsonString()
        return true
    }
}
