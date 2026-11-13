import Foundation
import Testing
@testable import LarkChannel
@testable import LarkCore

/// Ports of node-sdk `outbound/__tests__/{routing,errors,retry,sender-fallback}.test.ts`
/// and byte-level wire comparisons against node-sdk's `OutboundSender`.
@Suite struct OutboundTests {
    // MARK: routing.test.ts

    @Test func routingDetectsReceiveIdType() throws {
        #expect(try detectReceiveIdType("oc_abcdef") == .chatId)
        #expect(try detectReceiveIdType("ou_12345") == .openId)
        #expect(try detectReceiveIdType("on_xyz") == .unionId)
        #expect(try detectReceiveIdType("alice@example.com") == .email)
        #expect(try detectReceiveIdType("u_plain123") == .userId)
        #expect(try detectReceiveIdType("some_internal_id") == .userId)
        #expect(throws: LarkError.self) { try detectReceiveIdType("") }
    }

    // MARK: errors.test.ts

    static func api(_ code: Int, status: Int) -> LarkError {
        .api(LarkAPIError(code: code, msg: "code \(code)", httpStatus: status, logId: nil, headers: [:], body: Data()))
    }

    static func http(_ status: Int, body: String = "") -> LarkError {
        .http(statusCode: status, headers: [:], body: Data(body.utf8))
    }

    struct Plain: Error, CustomStringConvertible { var description: String }

    @Test func classifyErrorBasics() {
        let orig = LarkChannelError(.rateLimited, "too many")
        let passed = classifyError(orig)
        #expect(passed.code == .rateLimited && passed.message == "too many")
        #expect(classifyError(Self.http(429)).code == .rateLimited)
        #expect(classifyError(Self.http(403)).code == .permissionDenied)
        #expect(classifyError(Self.http(400)).code == .formatError)
        #expect(classifyError(Self.http(404)).code == .targetRevoked)
        #expect(classifyError(Self.api(230020, status: 200)).code == .targetRevoked)
        #expect(classifyError(SSRFBlockedError(message: "ssrf_blocked: 10.0.0.1")).code == .ssrfBlocked)
        #expect(classifyError(Plain(description: "ssrf_blocked: x")).code == .ssrfBlocked)
        #expect(classifyError(URLError(.timedOut)).code == .sendTimeout)
        #expect(classifyError(Plain(description: "Request Timeout")).code == .sendTimeout)
        #expect(classifyError(Plain(description: "mystery")).code == .unknown)
    }

    @Test func classifyErrorCodePrecedenceAndMessages() {
        // Business codes win over HTTP status.
        #expect(classifyError(Self.api(230017, status: 400)).code == .targetRevoked)
        #expect(classifyError(Self.api(99991400, status: 400)).code == .permissionDenied)
        #expect(classifyError(Self.api(230001, status: 200)).code == .formatError)
        #expect(classifyError(Self.api(230099, status: 400)).code == .formatError)
        #expect(classifyError(Self.api(1, status: 200)).code == .unknown)
        // Message: response msg || response message || error message.
        #expect(classifyError(Self.api(230020, status: 400)).message == "code 230020")
        #expect(classifyError(Self.http(500, body: #"{"message":"boom"}"#)).message == "boom")
        #expect(classifyError(Self.http(429, body: #"{"code":99991401}"#)).code == .permissionDenied)
        let ctx = classifyError(Plain(description: "x"), context: .init(to: "oc_1", attempt: 2)).context
        #expect(ctx == .init(to: "oc_1", attempt: 2))
    }

    @Test func errorPredicateHelpers() {
        #expect(isRetryable(.init(.rateLimited, "")))
        #expect(isRetryable(.init(.unknown, "")))
        #expect(!isRetryable(.init(.formatError, "")))
        #expect(!isRetryable(.init(.permissionDenied, "")))
        #expect(!isRetryable(.init(.sendTimeout, "")))
        #expect(isFormatError(.init(.formatError, "")))
        #expect(!isFormatError(.init(.rateLimited, "")))
        #expect(isReplyTargetGone(.init(.targetRevoked, "")))
        #expect(!isReplyTargetGone(.init(.unknown, "")))
    }

    // MARK: retry.test.ts

    @Test func retryReturnsFirstSuccess() async throws {
        let calls = Recorder<Int>()
        let r = try await retry { attempt in
            calls.append(attempt)
            return "ok"
        }
        #expect(r == "ok")
        #expect(calls.items == [1])
    }

    @Test func retryRetriesRetryableErrors() async throws {
        let calls = Recorder<Int>()
        let r = try await retry(maxAttempts: 3, baseDelayMs: 1) { attempt in
            calls.append(attempt)
            if calls.count < 2 { throw LarkChannelError(.rateLimited, "limited") }
            return "ok"
        }
        #expect(r == "ok")
        #expect(calls.count == 2)
    }

    @Test func retryGivesUpAfterMaxAttempts() async throws {
        let calls = Recorder<Int>()
        do {
            _ = try await retry(maxAttempts: 3, baseDelayMs: 1) { (a: Int) -> String in
                calls.append(a)
                throw LarkChannelError(.rateLimited, "nope")
            }
            Issue.record("expected throw")
        } catch let e as LarkChannelError {
            #expect(e.code == .rateLimited)
        }
        #expect(calls.count == 3)
    }

    @Test(arguments: [LarkChannelError.Code.formatError, .sendTimeout])
    func retryDoesNotRetryBusinessErrors(_ code: LarkChannelError.Code) async throws {
        let calls = Recorder<Int>()
        do {
            _ = try await retry(maxAttempts: 5, baseDelayMs: 1) { (a: Int) -> String in
                calls.append(a)
                throw LarkChannelError(code, "bad")
            }
        } catch let e as LarkChannelError {
            #expect(e.code == code)
        }
        #expect(calls.count == 1)
    }

    @Test func retryBacksOffExponentially() async throws {
        let stamps = Recorder<Double>()
        _ = try? await retry(maxAttempts: 3, baseDelayMs: 40) { (_: Int) -> String in
            stamps.append(Date().timeIntervalSince1970 * 1000)
            throw LarkChannelError(.unknown, "x")
        }
        let s = stamps.items
        #expect(s.count == 3)
        #expect(s[1] - s[0] >= 35)  // 40 * 3^0
        #expect(s[2] - s[1] >= 110)  // 40 * 3^1
    }

    // MARK: sender-fallback.test.ts

    static let fast = OutboundConfig(retry: .init(maxAttempts: 1, baseDelayMs: 0))

    static func senderChannel(_ handler: @escaping @Sendable (LarkHTTPRequest, Int) -> LarkHTTPResponse) throws -> (LarkChannel, MockHTTPClient) {
        let counter = Locked(0)
        let http = TestSupport.http { req in
            let n = counter.withLock { $0 += 1; return $0 }
            return handler(req, n)
        }
        return (try TestSupport.channel(http: http, outbound: fast), http)
    }

    static func ok(_ id: String) -> LarkHTTPResponse { MockHTTPClient.json(["code": 0, "data": ["message_id": .string(id)]]) }

    @Test func revokedReplyTargetRetriesAsCreate() async throws {
        let (ch, http) = try Self.senderChannel { req, _ in
            req.url.path.hasSuffix("/reply") ? TestSupport.apiError(code: 230020, status: 404) : Self.ok("om_new")
        }
        let r = try await ch.send("oc_abc", .text("hi"), options: .init(replyTo: "om_gone"))
        #expect(r.messageId == "om_new")
        let reqs = http.apiRequests
        try #require(reqs.count == 2)
        #expect(reqs[0].url.path == "/open-apis/im/v1/messages/om_gone/reply")
        #expect(reqs[1].url.path == "/open-apis/im/v1/messages")
        #expect(try TestSupport.body(reqs[1])["msg_type"] == "text")
    }

    @Test func successfulReplyDoesNotFallBack() async throws {
        let (ch, http) = try Self.senderChannel { _, _ in Self.ok("om_replied") }
        let r = try await ch.send("oc_abc", .text("hi"), options: .init(replyTo: "om_alive"))
        #expect(r.messageId == "om_replied")
        #expect(http.apiRequests.count == 1)
    }

    @Test func nonRevokeErrorStillThrows() async throws {
        let (ch, http) = try Self.senderChannel { _, _ in TestSupport.apiError(code: 99991401, status: 401) }
        do {
            _ = try await ch.send("oc_abc", .text("hi"), options: .init(replyTo: "om_x"))
            Issue.record("expected throw")
        } catch let e as LarkChannelError {
            #expect(e.code == .permissionDenied)
            // Already classified by `retry` (node passes it through unchanged).
            #expect(e.context?.attempt == 1)
        }
        #expect(http.apiRequests.count == 1)
    }

    @Test func postFormatErrorRetriesAsText() async throws {
        let (ch, http) = try Self.senderChannel { _, n in n == 1 ? TestSupport.apiError(code: 230002, status: 400) : Self.ok("om_text") }
        let r = try await ch.send("oc_abc", .post(["zh_cn": ["title": "bad", "content": [[["tag": "text", "text": "hello"]]]]]))
        #expect(r.messageId == "om_text")
        let reqs = http.apiRequests
        try #require(reqs.count == 2)
        #expect(try TestSupport.body(reqs[0])["msg_type"] == "post")
        #expect(try TestSupport.body(reqs[1])["msg_type"] == "text")
        #expect(try TestSupport.content(reqs[1])["text"]?.stringValue?.contains("hello") == true)
    }

    @Test func postReplyRevokedRetriesAsFreshPost() async throws {
        let (ch, http) = try Self.senderChannel { req, _ in
            req.url.path.hasSuffix("/reply") ? TestSupport.apiError(code: 230020, status: 404) : Self.ok("om_post_new")
        }
        let r = try await ch.send(
            "oc_abc", .post(["zh_cn": ["title": "t", "content": [[["tag": "text", "text": "x"]]]]]), options: .init(replyTo: "om_gone"))
        #expect(r.messageId == "om_post_new")
        #expect(try TestSupport.body(http.apiRequests[1])["msg_type"] == "post")
    }

    @Test func postSucceedsWithoutFallback() async throws {
        let (ch, http) = try Self.senderChannel { _, _ in Self.ok("om_post") }
        let r = try await ch.send("oc_abc", .post(["zh_cn": ["title": "t", "content": [[["tag": "text", "text": "x"]]]]]))
        #expect(r.messageId == "om_post")
        #expect(http.apiRequests.count == 1)
    }

    @Test func cardReplyRevokedRetriesAsCreate() async throws {
        let (ch, http) = try Self.senderChannel { req, _ in
            req.url.path.hasSuffix("/reply") ? TestSupport.apiError(code: 230020, status: 404) : Self.ok("om_card_new")
        }
        let r = try await ch.send("oc_abc", .card(["schema": "2.0", "body": ["elements": []]]), options: .init(replyTo: "om_gone"))
        #expect(r.messageId == "om_card_new")
        #expect(try TestSupport.body(http.apiRequests[1])["msg_type"] == "interactive")
    }

    @Test func missingMessageIdIsRetriedAsUnknown() async throws {
        let http = TestSupport.http { _ in MockHTTPClient.json(["code": 0, "data": [:]]) }
        let ch = try TestSupport.channel(http: http, outbound: .init(retry: .init(maxAttempts: 2, baseDelayMs: 0)))
        do {
            _ = try await ch.send("oc_abc", .text("hi"))
            Issue.record("expected throw")
        } catch let e as LarkChannelError {
            #expect(e.code == .unknown)
            #expect(e.message == "message_id missing from create response")
        }
        #expect(http.apiRequests.count == 2)
    }

    @Test func customMarkdownConverterIsUsed() async throws {
        let http = TestSupport.http { _ in Self.ok("om") }
        let ch = try TestSupport.channel(
            http: http, outbound: .init(markdownConverter: .custom { md in ["zh_cn": ["content": [[["tag": "text", "text": .string("X:" + md)]]]]] }))
        _ = try await ch.send("oc_abc", .markdown("hi"))
        #expect(try TestSupport.content(http.apiRequests[0])["zh_cn"]?["content"]?[0]?[0]?["text"] == "X:hi")
    }

    // MARK: Wire vectors (node-sdk OutboundSender with a recording client)

    static func apiName(_ req: LarkHTTPRequest) -> String {
        let p = req.url.path
        switch (req.method.rawValue, p) {
        case ("POST", "/open-apis/im/v1/messages"): return "message.create"
        case ("POST", _) where p.hasSuffix("/reply"): return "message.reply"
        case ("PATCH", _) where p.hasPrefix("/open-apis/im/v1/messages/"): return "message.patch"
        case ("POST", "/open-apis/im/v1/images"): return "image.create"
        case ("POST", "/open-apis/im/v1/files"): return "file.create"
        case ("POST", "/open-apis/cardkit/v1/cards"): return "card.create"
        case ("PATCH", _) where p.hasSuffix("/settings"): return "card.settings"
        case ("PUT", _) where p.hasSuffix("/content"): return "cardElement.content"
        default: return "?\(req.method.rawValue) \(p)"
        }
    }

    /// Replies like node's fake client (incrementing message / card ids) with scripted failures.
    static func wireHTTP(failures: [String: [(Int, Int)]]) -> MockHTTPClient {
        let state = Locked((mid: 0, cid: 0, fails: failures))
        return TestSupport.http { req in
            let name = apiName(req)
            let fail = state.withLock { s -> (Int, Int)? in
                guard var list = s.fails[name], !list.isEmpty else { return nil }
                let f = list.removeFirst()
                s.fails[name] = list
                return f
            }
            if let (code, status) = fail { return TestSupport.apiError(code: code, status: status) }
            switch name {
            case "message.create", "message.reply":
                let id = state.withLock { $0.mid += 1; return $0.mid }
                return MockHTTPClient.json(["code": 0, "data": ["message_id": .string("om_\(id)")]])
            case "card.create":
                let id = state.withLock { $0.cid += 1; return $0.cid }
                return MockHTTPClient.json(["code": 0, "data": ["card_id": .string("card_\(id)")]])
            case "image.create": return MockHTTPClient.json(["code": 0, "data": ["image_key": "img_up"]])
            case "file.create": return MockHTTPClient.json(["code": 0, "data": ["file_key": "file_up"]])
            default: return MockHTTPClient.json(["code": 0])
            }
        }
    }

    static let failuresByScenario: [String: [String: [(Int, Int)]]] = [
        "postFallback": ["message.create": [(230002, 400)]],
        "markdownFallbackEmpty": ["message.create": [(230001, 200)]],
        "replyRevoked": ["message.reply": [(230020, 404)]],
    ]

    static func config(_ name: String, _ v: JSONValue) -> OutboundConfig {
        var c = OutboundConfig(retry: .init(maxAttempts: 1, baseDelayMs: 0))
        if name == "textChunks" { c.textChunkLimit = 10 }
        if name == "markdownChunks" { c.textChunkLimit = 40 }
        c.streamThrottleMs = v["streamThrottleMs"]?.intValue
        c.streamThrottleChars = v["streamThrottleChars"]?.intValue
        c.streamInitialText = v["streamInitialText"]?.string
        c.streamMaxElementChars = v["streamMaxElementChars"]?.intValue
        return c
    }

    struct ProducerFailure: Error, CustomStringConvertible {
        var description: String
    }

    static func run(_ name: String, _ ch: LarkChannel) async throws -> SendResult {
        let alice = MentionInfo(key: "@_user_1", openId: "ou_a", name: "Alice")
        switch name {
        case "text": return try await ch.send("oc_chat", .text("hello \"world\"\n/slash 中文 😀"))
        case "textMentionsReply":
            return try await ch.send(
                "ou_user", .text("hi"),
                options: .init(replyTo: "om_parent", replyInThread: true, mentions: [MentionInfo(key: "@_user_1", openId: "ou_a", name: "A"), MentionInfo(key: "@_x", name: "X")]))
        case "textChunks": return try await ch.send("on_union", .text("abcdefghijklmnopqrstuvwxy"), options: .init(replyTo: "om_r"))
        case "markdown": return try await ch.send("oc_chat", .markdown("# Title\n\nbody **bold** `code`\n\n\n\nend"), options: .init(mentions: [alice]))
        case "markdownChunks":
            return try await ch.send(
                "alice@example.com", .markdown("para one line\npara two line\n```js\nconst a = 1;\nconst b = 2;\n```\n## Next\nmore text here"),
                options: .init(replyTo: "om_r", mentions: [alice]))
        case "post": return try await ch.send("oc_chat", .post(["zh_cn": ["content": [[["tag": "text", "text": "x"]]], "title": "t"]]))
        case "card":
            return try await ch.send(
                "oc_chat", .card(["body": ["elements": [["content": "hi", "tag": "markdown"]]], "schema": "2.0"]), options: .init(replyTo: "om_r", replyInThread: false))
        case "shareChat": return try await ch.send("oc_chat", .shareChat(chatId: "oc_target"))
        case "shareUser": return try await ch.send("oc_chat", .shareUser(userId: "ou_alice"))
        case "sticker": return try await ch.send("u_plain", .sticker(fileKey: "sticker_abc"))
        case "image": return try await ch.send("oc_chat", .image(.data(Data([1, 2, 3]))))
        case "file": return try await ch.send("oc_chat", .file(.data(Data("doc".utf8)), fileName: "a.txt"))
        case "audio": return try await ch.send("oc_chat", .audio(.data(Data("opus".utf8)), duration: 3000))
        case "video": return try await ch.send("oc_chat", .video(.data(Data("mp4".utf8)), duration: 5000, coverImageKey: "img_cover"))
        case "postFallback":
            return try await ch.send("oc_chat", .post(["zh_cn": ["content": [[["tag": "text", "text": "hello"], ["tag": "at", "user_name": "Al"]]], "title": "bad"]]))
        case "markdownFallbackEmpty": return try await ch.send("oc_chat", .markdown(""))
        case "replyRevoked": return try await ch.send("oc_chat", .text("hi"), options: .init(replyTo: "om_gone"))
        case "streamMarkdown":
            return try await ch.stream(
                "oc_chat",
                .markdown { c in
                    try await c.append("Hello ")
                    try await c.append("Hello world")
                    try await c.append(" and more   text\nnew line")
                }, options: .init(replyTo: "om_r"))
        case "streamMarkdownEmpty": return try await ch.stream("oc_chat", .markdown { _ in })
        case "streamMarkdownSetContent":
            return try await ch.stream(
                "oc_chat",
                .markdown { c in
                    try await c.append("a")
                    try await c.setContent("replaced")
                })
        case "streamMarkdownRollover":
            return try await ch.stream("oc_chat", .markdown { c in try await c.setContent("line one is here\nline two is here\nline three here\nfour") })
        case "streamMarkdownLongSummary":
            return try await ch.stream("oc_chat", .markdown { c in try await c.append(String(repeating: "x", count: 60)) })
        case "streamCard":
            return try await ch.stream(
                "oc_chat",
                .card(initial: ["elements": [["content": "v0", "tag": "markdown"]], "schema": "2.0"]) { c in
                    await c.update(["elements": [["content": "v1", "tag": "markdown"]], "schema": "2.0"])
                    await c.update { cur in
                        var next = cur
                        next["header"] = ["title": "T"]
                        return next
                    }
                })
        case "streamMarkdownFail":
            return try await ch.stream(
                "oc_chat",
                .markdown { c in
                    try await c.append("partial")
                    throw ProducerFailure(description: "producer failure")
                })
        case "streamCardFail":
            return try await ch.stream(
                "oc_chat",
                .card(initial: ["elements": [["tag": "div"]]]) { c in
                    await c.update(["header": ["t": 1]])
                    throw ProducerFailure(description: "boom")
                })
        default:
            Issue.record("unknown scenario \(name)")
            throw ProducerFailure(description: "unknown")
        }
    }

    /// Card stream payloads go through ``JSONValue`` (unordered), so their keys
    /// are sorted instead of keeping the producer's insertion order.
    static let unorderedCardScenarios: Set<String> = ["streamCard"]

    static let wireScenarios = Vectors["wire"].objectValue!.keys.sorted()

    @Test(arguments: wireScenarios)
    func wireMatchesNodeSender(_ name: String) async throws {
        let v = Vectors["wire"][name]!
        let http = Self.wireHTTP(failures: Self.failuresByScenario[name] ?? [:])
        let ch = try TestSupport.channel(http: http, outbound: Self.config(name, v["config"]!))
        var result: SendResult?
        var errorMessage: String?
        do {
            result = try await Self.run(name, ch)
        } catch {
            errorMessage = (error as? ProducerFailure)?.description ?? "\(error)"
        }
        #expect(errorMessage == v["error"]?.string)
        if let r = v["result"], !r.isNull {
            #expect(result?.messageId == r["messageId"]?.string)
            #expect(result?.chunkIds == r["chunkIds"]?.arrayValue?.map { $0.string! })
        }

        let calls = v["calls"]!.array
        let reqs = http.apiRequests
        #expect(reqs.count == calls.count, "\(name): \(reqs.map(Self.apiName)) vs \(calls.map { $0["api"]! })")
        for (req, call) in zip(reqs, calls) {
            #expect(Self.apiName(req) == call["api"]!.string!, "\(name)")
            #expect(req.method.rawValue == call["method"]!.string!)
            #expect(req.url.path == call["path"]!.string!)
            let expectedQuery = call["query"]?.objectValue.map { q in q.keys.sorted().map { "\($0)=\(q[$0]!.stringValue!)" }.joined(separator: "&") }
            #expect(req.url.query == expectedQuery, "\(name)")
            if let body = call["body"]?.string {
                let actual = TestSupport.bodyString(req)
                if Self.unorderedCardScenarios.contains(name) && actual != body {
                    let a = try JSONValue(jsonString: actual), b = try JSONValue(jsonString: body)
                    #expect(try JSONValue(jsonString: a["content"]!.string!) == JSONValue(jsonString: b["content"]!.string!), "\(name)")
                } else {
                    #expect(actual == body, "\(name)")
                }
                #expect(req.headers["Content-Type"] == "application/json; charset=utf-8")
            }
            if let form = call["form"]?.objectValue {
                let parts = TestSupport.multipart(req)
                #expect(Set(parts.keys) == Set(form.keys), "\(name)")
                for (k, v) in form {
                    if let hex = v["hex"]?.string {
                        #expect(parts[k].map { $0.map { String(format: "%02x", $0) }.joined() } == hex)
                    } else {
                        #expect(parts[k].map { String(decoding: $0, as: UTF8.self) } == v.stringValue)
                    }
                }
            }
        }
    }
}
