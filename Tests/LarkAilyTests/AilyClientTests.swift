import Foundation
import Testing
@testable import LarkAily
@testable import LarkCore

// Ports node-sdk scene/aily/__tests__/session-cache.ts and covers scene/aily/client.ts
// (`Aily.completions`) end to end against a mock Open Platform.

// MARK: - Test doubles

/// Routes requests by `"METHOD /path"`. Each route answers its queued responses in order and
/// keeps repeating the last one.
private final class AilyMockHTTP: LarkHTTPClient, @unchecked Sendable {
    enum Reply {
        case json(JSONValue, status: Int = 200)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var routes: [String: [Reply]] = [:]
    private var _requests: [LarkHTTPRequest] = []

    func on(_ method: HTTPMethod, _ path: String, _ replies: Reply...) {
        lock.withLock { routes["\(method.rawValue) \(path)"] = replies }
    }

    /// API requests, excluding the SDK's tenant token fetch.
    var requests: [LarkHTTPRequest] {
        lock.withLock { _requests.filter { !$0.url.path.hasSuffix("tenant_access_token/internal") } }
    }

    func requests(_ method: HTTPMethod, _ path: String) -> [LarkHTTPRequest] {
        requests.filter { $0.method == method && $0.url.path == path }
    }

    func send(_ request: LarkHTTPRequest) async throws -> LarkHTTPResponse {
        if request.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
            lock.withLock { _requests.append(request) }
            return Self.response(["code": 0, "tenant_access_token": "t-123", "expire": 7200], status: 200)
        }
        let reply: Reply? = lock.withLock {
            _requests.append(request)
            let key = "\(request.method.rawValue) \(request.url.path)"
            guard var queue = routes[key], !queue.isEmpty else { return nil }
            let r = queue[0]
            if queue.count > 1 { queue.removeFirst() }
            routes[key] = queue
            return r
        }
        switch reply {
        case .json(let body, let status)?: return Self.response(body, status: status)
        case .failure(let e)?: throw e
        case nil:
            let msg = "no route \(request.method.rawValue) \(request.url.path)"
            return Self.response(["code": 404, "msg": .string(msg)], status: 404)
        }
    }

    static func response(_ body: JSONValue, status: Int) -> LarkHTTPResponse {
        LarkHTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.jsonString().utf8))
    }
}

private final class CaptureLogger: LarkLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func log(level: LarkLogLevel, message: String) { lock.withLock { _lines.append("[\(level.label)] \(message)") } }
    var lines: [String] { lock.withLock { _lines } }
}

private let sessionsPath = "/open-apis/aily/v1/sessions"
private let messagesPath = "/open-apis/aily/v1/sessions/ses_1/messages"
private let runsPath = "/open-apis/aily/v1/sessions/ses_1/runs"
private let runPath = "/open-apis/aily/v1/sessions/ses_1/runs/run_1"

private func ok(_ data: JSONValue) -> AilyMockHTTP.Reply { .json(["code": 0, "msg": "success", "data": data]) }
private func bizError(_ code: Int, _ msg: String) -> AilyMockHTTP.Reply { .json(["code": .number(Double(code)), "msg": .string(msg)]) }
private func runStatus(_ status: String) -> AilyMockHTTP.Reply { ok(["run": ["id": "run_1", "status": .string(status)]]) }

private func message(_ id: String, _ sender: String, _ status: String = "COMPLETED", content: String? = nil) -> JSONValue {
    var o: [String: JSONValue] = ["id": .string(id), "sender": ["sender_type": .string(sender)], "status": .string(status)]
    if let content { o["content"] = .string(content) }
    return .object(o)
}

private func page(_ messages: [JSONValue], next: String? = nil) -> AilyMockHTTP.Reply {
    var data: [String: JSONValue] = ["messages": .array(messages), "has_more": .bool(next != nil)]
    if let next { data["page_token"] = .string(next) }
    return ok(.object(data))
}

/// A mock where every step succeeds: session `ses_1`, message `msg_1`, run `run_1`
/// (QUEUED → IN_PROGRESS → COMPLETED), and one page of messages.
private func happyHTTP() -> AilyMockHTTP {
    let http = AilyMockHTTP()
    http.on(.post, sessionsPath, ok(["session": ["id": "ses_1"]]))
    http.on(.post, messagesPath, ok(["message": ["id": "msg_1"]]))
    http.on(.post, runsPath, ok(["run": ["id": "run_1", "status": "QUEUED"]]))
    http.on(.get, runPath, runStatus("QUEUED"), runStatus("IN_PROGRESS"), runStatus("COMPLETED"))
    http.on(.get, messagesPath, page([message("msg_1", "USER"), message("reply_1", "ASSISTANT", content: "hi there")]))
    return http
}

private func makeAily(
    _ http: AilyMockHTTP,
    cache: (any LarkCache)? = nil,
    logger: CaptureLogger = CaptureLogger(),
    pollInterval: Duration = .milliseconds(1)
) throws -> AilyClient {
    let client = try LarkClient(
        LarkConfiguration(appId: "cli_test", appSecret: "secret", logLevel: .error, logger: logger, cache: DefaultLarkCache(), httpClient: http))
    return AilyClient(client: client, cache: cache, pollInterval: pollInterval)
}

private func query(_ req: LarkHTTPRequest) -> [String: String] {
    var out: [String: String] = [:]
    for item in URLComponents(url: req.url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
    return out
}

private func body(_ req: LarkHTTPRequest?) throws -> JSONValue {
    try JSONValue(data: try #require(req?.body))
}

private func expectStatus(_ expected: AilyExecStatus, _ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("expected \(expected), nothing was thrown")
    } catch let status as AilyExecStatus {
        #expect(status == expected)
    } catch {
        Issue.record("expected \(expected), got \(error)")
    }
}

/// Parent suite so `swift test --filter AilyClientTests` selects every case below.
@Suite enum AilyClientTests {}

extension AilyClientTests {
    // MARK: - Session cache (node: scene/aily/__tests__/session-cache.ts)

    @Suite struct SessionCacheTests {
        @Test func workRight() async throws {
            let sessionCache = AilySessionCache()

            await sessionCache.set("test", value: #"{"a":1}"#)
            #expect(try JSONValue(jsonString: try #require(await sessionCache.get("test"))) == ["a": 1])

            // `{ a: undefined }` serialises to `{}`: nothing is overwritten.
            await sessionCache.set("test", value: "{}")
            #expect(try JSONValue(jsonString: try #require(await sessionCache.get("test"))) == ["a": 1])

            await sessionCache.set("test", value: #"{"a":2,"b":1}"#)
            #expect(try JSONValue(jsonString: try #require(await sessionCache.get("test"))) == ["a": 2, "b": 1])
        }

        @Test func ignoresExpiryAndNamespaceLikeNode() async throws {
            let cache = AilySessionCache()
            await cache.set("k", value: #"{"x":"1"}"#, expiresAt: Date(timeIntervalSinceNow: -60), namespace: "ns1")
            #expect(await cache.get("k", namespace: "ns2") == #"{"x":"1"}"#)
            #expect(await cache.get("missing") == nil)
        }

        @Test func nullValuesOverwriteAndNonObjectsReplace() async throws {
            let cache = AilySessionCache()
            await cache.set("k", value: #"{"a":1,"b":2}"#)
            await cache.set("k", value: #"{"a":null}"#)  // mergeObject only skips undefined
            #expect(try JSONValue(jsonString: try #require(await cache.get("k"))) == ["a": nil, "b": 2])
            await cache.set("k", value: "plain")
            #expect(await cache.get("k") == "plain")
            await cache.set("k", value: #"{"c":3}"#)
            #expect(try JSONValue(jsonString: try #require(await cache.get("k"))) == ["c": 3])
        }
    }

    // MARK: - completions.create

    @Suite struct CreateTests {
        @Test func createsSessionMessageRunPollsAndReturnsTheAssistantReply() async throws {
            let http = happyHTTP()
            let aily = try makeAily(http)
            let before = Int64(Date().timeIntervalSince1970 * 1000)
            let reply = try await aily.completions.create(.init(
                sessionInfo: .init(channelContext: "{}", metadata: "meta"),
                message: "hello",
                messageInfo: .init(fileIds: ["file_1"], quoteMessageId: "q_1"),
                ailyAppId: "spring_app",
                skillId: "skill_1",
                runInfo: .init(skillInput: "{\"k\":1}", metadata: "run-meta")))
            let after = Int64(Date().timeIntervalSince1970 * 1000)

            #expect(reply.id == "reply_1")
            #expect(reply.content == "hi there")
            #expect(reply.sender?.senderType == .aSSISTANT)

            let reqs = http.requests
            #expect(reqs.map { "\($0.method.rawValue) \($0.url.path)" } == [
                "POST \(sessionsPath)", "POST \(messagesPath)", "POST \(runsPath)",
                "GET \(runPath)", "GET \(runPath)", "GET \(runPath)", "GET \(messagesPath)",
            ])
            #expect(reqs.allSatisfy { $0.headers["Authorization"] == "Bearer t-123" })

            #expect(try body(reqs[0]) == ["channel_context": "{}", "metadata": "meta"])

            let msg = try body(reqs[1])
            #expect(msg["content"] == "hello")
            #expect(msg["content_type"] == "MDX")
            #expect(msg["file_ids"] == ["file_1"])
            #expect(msg["quote_message_id"] == "q_1")
            #expect(msg["mentions"] == nil)
            let idempotent = try #require(msg["idempotent_id"]?.stringValue.flatMap { Int64($0) })  // `${Date.now()}`
            #expect(idempotent >= before && idempotent <= after)
            #expect(msg["idempotent_id"]?.stringValue == String(idempotent))

            #expect(try body(reqs[2]) == ["app_id": "spring_app", "skill_id": "skill_1", "skill_input": "{\"k\":1}", "metadata": "run-meta"])

            #expect(query(reqs[6]) == ["run_id": "run_1", "with_partial_message": "false"])
        }

        @Test func minimalParamsOmitOptionalFields() async throws {
            let http = happyHTTP()
            _ = try await makeAily(http).completions.create(.init(message: "hi", ailyAppId: "spring_app"))
            #expect(try body(http.requests(.post, sessionsPath).first) == [:])
            #expect(try body(http.requests(.post, runsPath).first) == ["app_id": "spring_app"])
            let msg = try body(http.requests(.post, messagesPath).first)
            #expect(Set(msg.objectValue?.keys.map { $0 } ?? []) == ["content", "content_type", "idempotent_id"])
        }

        @Test func returnsTheLastAssistantMessageAcrossPages() async throws {
            let http = happyHTTP()
            http.on(
                .get, messagesPath,
                page([message("msg_1", "USER"), message("a1", "ASSISTANT"), message("a2", "ASSISTANT")], next: "p2"),
                page([message("a3", "ASSISTANT"), message("u2", "USER")]))
            let reply = try await makeAily(http).completions.create(.init(message: "hi", ailyAppId: "app"))
            #expect(reply.id == "a3")
            let lists = http.requests(.get, messagesPath)
            #expect(lists.count == 2)
            #expect(query(lists[1]) == ["run_id": "run_1", "with_partial_message": "false", "page_token": "p2"])
        }

        @Test func throwsErrorWhenThereIsNoAssistantReply() async throws {
            let http = happyHTTP()
            http.on(.get, messagesPath, page([message("msg_1", "USER")]))
            let logger = CaptureLogger()
            let aily = try makeAily(http, logger: logger)
            await expectStatus(.error) { _ = try await aily.completions.create(.init(message: "hi", ailyAppId: "app")) }
            #expect(logger.lines.contains("[error] no aily reply"))
        }

        @Test func forwardsRequestOptionsToEveryCall() async throws {
            let http = happyHTTP()
            _ = try await makeAily(http).completions.create(
                .init(message: "hi", ailyAppId: "app"), options: .userAccessToken("u-abc"))
            let reqs = http.requests
            #expect(reqs.count == 7)
            #expect(reqs.allSatisfy { $0.headers["Authorization"] == "Bearer u-abc" })
        }
    }

    // MARK: - Session records

    @Suite struct SessionRecordTests {
        @Test func rememberAndReuseTheAilySessionForASessionId() async throws {
            let http = happyHTTP()
            let aily = try makeAily(http)
            _ = try await aily.completions.create(.init(sessionId: "chat_1", message: "one", ailyAppId: "app"))
            #expect(await aily.completions.sessionRecords.get() == ["chat_1": "ses_1"])

            _ = try await aily.completions.create(.init(sessionId: "chat_1", message: "two", ailyAppId: "app"))
            #expect(http.requests(.post, sessionsPath).count == 1)
            #expect(http.requests(.post, messagesPath).count == 2)

            // The default cache stores the records under the node key as a JSON object.
            let raw = try #require(await aily.cache.get(LarkCacheKey.ailySessionRecord))
            #expect(try JSONValue(jsonString: raw) == ["chat_1": "ses_1"])
            #expect(LarkCacheKey.ailySessionRecord == "aily-session-record")
        }

        @Test func withoutSessionIdEveryCallCreatesASessionAndNothingIsRecorded() async throws {
            let http = happyHTTP()
            let aily = try makeAily(http)
            _ = try await aily.completions.create(.init(message: "one", ailyAppId: "app"))
            _ = try await aily.completions.create(.init(sessionId: "", message: "two", ailyAppId: "app"))
            #expect(http.requests(.post, sessionsPath).count == 2)
            #expect(await aily.completions.sessionRecords.get().isEmpty)
        }

        @Test func updatedRecordsAreUsedAndMerged() async throws {
            let http = AilyMockHTTP()
            let other = "/open-apis/aily/v1/sessions/ses_known"
            http.on(.post, other + "/messages", ok(["message": ["id": "msg_1"]]))
            http.on(.post, other + "/runs", ok(["run": ["id": "run_9"]]))
            http.on(.get, other + "/runs/run_9", runStatus("COMPLETED"))
            http.on(.get, other + "/messages", page([message("r", "ASSISTANT")]))
            let aily = try makeAily(http)

            await aily.completions.sessionRecords.update(["chat_a": "ses_known"])
            await aily.completions.sessionRecords.update(["chat_b": "ses_b"])
            #expect(await aily.completions.sessionRecords.get() == ["chat_a": "ses_known", "chat_b": "ses_b"])

            let reply = try await aily.completions.create(.init(sessionId: "chat_a", message: "hi", ailyAppId: "app"))
            #expect(reply.id == "r")
            #expect(http.requests(.post, sessionsPath).isEmpty)
        }

        @Test func aCustomCacheReceivesPlainSetCalls() async throws {
            // A non-merging cache (like node's default client cache) is replaced on each update.
            let cache = DefaultLarkCache()
            let aily = try makeAily(happyHTTP(), cache: cache)
            await aily.completions.sessionRecords.update(["a": "1"])
            await aily.completions.sessionRecords.update(["b": "2"])
            #expect(await aily.completions.sessionRecords.get() == ["b": "2"])
            #expect(try JSONValue(jsonString: try #require(await cache.get("aily-session-record"))) == ["b": "2"])
        }

        @Test func unreadableRecordsAreEmpty() async throws {
            let cache = DefaultLarkCache()
            await cache.set(LarkCacheKey.ailySessionRecord, value: "not json")
            let aily = try makeAily(happyHTTP(), cache: cache)
            #expect(await aily.completions.sessionRecords.get().isEmpty)
            await cache.set(LarkCacheKey.ailySessionRecord, value: #"{"a":"x","n":1,"o":{}}"#)
            // Scalars are read as strings; objects and arrays cannot be session ids and are skipped.
            #expect(await aily.completions.sessionRecords.get() == ["a": "x", "n": "1"])
        }
    }

    // MARK: - Failure paths

    @Suite struct FailureTests {
        @Test func sessionCreationBusinessErrorThrowsError() async throws {
            let http = happyHTTP()
            http.on(.post, sessionsPath, bizError(2_320_001, "invalid app"))
            let logger = CaptureLogger()
            let aily = try makeAily(http, logger: logger)
            await expectStatus(.error) { _ = try await aily.completions.create(.init(sessionId: "c", message: "hi", ailyAppId: "app")) }
            #expect(http.requests.count == 1)
            #expect(logger.lines.contains("[error] get aily session id error invalid app"))
            #expect(await aily.completions.sessionRecords.get().isEmpty)
        }

        @Test func sessionWithoutIdOrDataThrowsError() async throws {
            let cases: [(AilyMockHTTP.Reply, [String: String])] = [
                (ok(["session": [:]]), [:]),
                // node-sdk records `{[sessionId]: ''}` before failing on the empty id.
                (ok(["session": ["id": ""]]), ["c": ""]),
                (.json(["code": 0, "msg": "ok"]), [:]),  // no `data`
            ]
            for (reply, records) in cases {
                let http = happyHTTP()
                http.on(.post, sessionsPath, reply)
                let aily = try makeAily(http)
                await expectStatus(.error) { _ = try await aily.completions.create(.init(sessionId: "c", message: "hi", ailyAppId: "app")) }
                #expect(http.requests.count == 1)
                #expect(await aily.completions.sessionRecords.get() == records)
            }
        }

        @Test func aRecordedEmptySessionIdFailsWithoutCreatingASession() async throws {
            let http = happyHTTP()
            let aily = try makeAily(http)
            await aily.completions.sessionRecords.update(["c": ""])
            await expectStatus(.error) { _ = try await aily.completions.create(.init(sessionId: "c", message: "hi", ailyAppId: "app")) }
            #expect(http.requests.isEmpty)
        }

        @Test func messageCreationBusinessErrorThrowsError() async throws {
            let http = happyHTTP()
            http.on(.post, messagesPath, bizError(99_991_400, "rate limited"))
            let logger = CaptureLogger()
            let aily = try makeAily(http, logger: logger)
            await expectStatus(.error) { _ = try await aily.completions.create(.init(message: "hi", ailyAppId: "app")) }
            #expect(http.requests.count == 2)
            #expect(logger.lines.contains("[error] create aily message error rate limited"))
        }

        @Test func runCreationBusinessErrorThrowsError() async throws {
            let http = happyHTTP()
            http.on(.post, runsPath, bizError(2_320_002, "bad skill"))
            let logger = CaptureLogger()
            let aily = try makeAily(http, logger: logger)
            await expectStatus(.error) { _ = try await aily.completions.create(.init(message: "hi", ailyAppId: "app")) }
            #expect(http.requests.count == 3)
            #expect(logger.lines.contains("[error] create aily session run error bad skill"))
        }

        @Test func emptyRunIdThrowsError() async throws {
            for reply in [ok(["run": [:]]), ok(["run": ["id": ""]])] {
                let http = happyHTTP()
                http.on(.post, runsPath, reply)
                let logger = CaptureLogger()
                let aily = try makeAily(http, logger: logger)
                await expectStatus(.error) { _ = try await aily.completions.create(.init(message: "hi", ailyAppId: "app")) }
                #expect(http.requests.count == 3)
                #expect(logger.lines.contains("[error] run id is empty"))
            }
        }

        @Test(arguments: [
            ("EXPIRED", AilyExecStatus.expired), ("CANCELLED", .cancelled), ("FAILED", .failed),
            ("REQUIRES_MESSAGE", .other), ("SOMETHING_NEW", .other),
        ])
        func terminalRunStatusesAreThrown(status: String, expected: AilyExecStatus) async throws {
            let http = happyHTTP()
            http.on(.get, runPath, runStatus("IN_PROGRESS"), runStatus(status))
            let logger = CaptureLogger()
            let aily = try makeAily(http, logger: logger)
            await expectStatus(expected) { _ = try await aily.completions.create(.init(message: "hi", ailyAppId: "app")) }
            #expect(http.requests(.get, runPath).count == 2)
            #expect(http.requests(.get, messagesPath).isEmpty)
            #expect(logger.lines.contains("[error] aily run error"))
        }

        @Test func runWithoutStatusIsOther() async throws {
            let http = happyHTTP()
            http.on(.get, runPath, ok(["run": ["id": "run_1"]]))
            await expectStatus(.other) { _ = try await makeAily(http).completions.create(.init(message: "hi", ailyAppId: "app")) }
        }

        @Test func runPollingBusinessErrorIsFailed() async throws {
            let http = happyHTTP()
            http.on(.get, runPath, runStatus("QUEUED"), bizError(500, "internal"))
            await expectStatus(.failed) { _ = try await makeAily(http).completions.create(.init(message: "hi", ailyAppId: "app")) }
            let noData = happyHTTP()
            noData.on(.get, runPath, .json(["code": 0, "msg": "ok"]))
            await expectStatus(.failed) { _ = try await makeAily(noData).completions.create(.init(message: "hi", ailyAppId: "app")) }
        }

        @Test func transportErrorsPropagate() async throws {
            let http = happyHTTP()
            http.on(.get, runPath, runStatus("QUEUED"), .failure(URLError(.timedOut)))
            await #expect {
                _ = try await makeAily(http).completions.create(.init(message: "hi", ailyAppId: "app"))
            } throws: { error in
                if case LarkError.transport = error { return true }
                return false
            }
            let session = happyHTTP()
            session.on(.post, sessionsPath, .failure(URLError(.notConnectedToInternet)))
            await #expect(throws: LarkError.self) {
                _ = try await makeAily(session).completions.create(.init(message: "hi", ailyAppId: "app"))
            }
        }

        @Test func cancellingTheTaskStopsPolling() async throws {
            let http = happyHTTP()
            http.on(.get, runPath, runStatus("IN_PROGRESS"))
            let aily = try makeAily(http)
            let task = Task { try await aily.completions.create(.init(message: "hi", ailyAppId: "app")) }
            for _ in 0..<2000 where http.requests(.get, runPath).count < 3 { try await Task.sleep(for: .milliseconds(1)) }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            let polls = http.requests(.get, runPath).count
            try await Task.sleep(for: .milliseconds(20))
            #expect(http.requests(.get, runPath).count == polls)
        }

        @Test func pollsEveryInterval() async throws {
            #expect(try makeAily(happyHTTP(), pollInterval: .milliseconds(500)).pollInterval == .milliseconds(500))
            let client = try LarkClient(LarkConfiguration(appId: "cli", appSecret: "s", logLevel: .fatal, httpClient: AilyMockHTTP()))
            #expect(AilyClient(client: client).pollInterval == .milliseconds(500))  // node: setTimeout(..., 500)

            let http = happyHTTP()
            let clock = ContinuousClock()
            let start = clock.now
            _ = try await makeAily(http, pollInterval: .milliseconds(30)).completions.create(.init(message: "hi", ailyAppId: "app"))
            // Three status checks, each preceded by the delay.
            #expect(clock.now - start >= .milliseconds(90))
        }
    }

    // MARK: - completions.createWithStream

    @Suite struct StreamTests {
        @Test func streamsMessagesAfterTheSentMessageUntilOneCompletes() async throws {
            let http = happyHTTP()
            http.on(
                .get, messagesPath,
                page(
                    [
                        message("old", "ASSISTANT"),
                        message("msg_1", "USER", "IN_PROGRESS"),
                        message("msg_1", "USER", "COMPLETED"),
                        message("a1", "ASSISTANT", "IN_PROGRESS", content: "Hel"),
                    ], next: "p2"),
                page([
                    message("a1", "ASSISTANT", "IN_PROGRESS", content: "Hello"),
                    message("a1", "ASSISTANT", "COMPLETED", content: "Hello!"),
                    message("after", "ASSISTANT", "COMPLETED"),
                ], next: "p3"),
                page([message("never", "ASSISTANT")]))
            let stream = try await makeAily(http).completions.createWithStream(.init(message: "hi", ailyAppId: "app"))
            var chunks: [String] = []
            for try await chunk in stream { chunks.append("\(chunk.id ?? "")|\(chunk.status?.rawValue ?? "")|\(chunk.content ?? "")") }
            #expect(chunks == ["a1|IN_PROGRESS|Hel", "a1|IN_PROGRESS|Hello", "a1|COMPLETED|Hello!"])

            let lists = http.requests(.get, messagesPath)
            #expect(lists.count == 2)  // stops before fetching p3
            #expect(query(lists[0]) == ["run_id": "run_1", "with_partial_message": "true"])
            #expect(query(lists[1])["page_token"] == "p2")
        }

        @Test func waitsForTheRunBeforeReturningTheStream() async throws {
            let http = happyHTTP()
            _ = try await makeAily(http).completions.createWithStream(.init(message: "hi", ailyAppId: "app"))
            #expect(http.requests(.get, runPath).count == 3)
            #expect(http.requests(.get, messagesPath).isEmpty)  // listing is lazy
        }

        @Test func yieldsNothingWhenTheSentMessageNeverCompletes() async throws {
            let http = happyHTTP()
            http.on(.get, messagesPath, page([message("msg_1", "USER", "IN_PROGRESS"), message("a1", "ASSISTANT")]))
            let stream = try await makeAily(http).completions.createWithStream(.init(message: "hi", ailyAppId: "app"))
            var count = 0
            for try await _ in stream { count += 1 }
            #expect(count == 0)
        }

        @Test func streamEndsWithThePagesWhenNothingCompletes() async throws {
            let http = happyHTTP()
            http.on(.get, messagesPath, page([message("msg_1", "USER"), message("a1", "ASSISTANT", "IN_PROGRESS")]))
            let stream = try await makeAily(http).completions.createWithStream(.init(message: "hi", ailyAppId: "app"))
            var ids: [String?] = []
            for try await m in stream { ids.append(m.id) }
            #expect(ids == ["a1"])
        }

        @Test func streamFailuresUseTheSameErrors() async throws {
            let http = happyHTTP()
            http.on(.get, runPath, runStatus("EXPIRED"))
            await expectStatus(.expired) { _ = try await makeAily(http).completions.createWithStream(.init(message: "hi", ailyAppId: "app")) }

            let listing = happyHTTP()
            listing.on(.get, messagesPath, bizError(1_000, "list failed"))
            let stream = try await makeAily(listing).completions.createWithStream(.init(message: "hi", ailyAppId: "app"))
            await #expect(throws: LarkError.self) { for try await _ in stream {} }
        }
    }
}

