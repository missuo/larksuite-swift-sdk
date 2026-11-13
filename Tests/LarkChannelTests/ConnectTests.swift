import Foundation
import Testing
@testable import LarkChannel
@testable import LarkCore

/// Port of node-sdk `channel/__tests__/connect-errors.test.ts`, plus the
/// connect / WebSocket lifecycle.
@Suite struct ConnectTests {
    static let botPath = "/open-apis/bot/v3/info"

    static func channel(_ handler: @escaping @Sendable (LarkHTTPRequest) throws -> LarkHTTPResponse) throws -> LarkChannel {
        try TestSupport.channel(http: TestSupport.http(handler))
    }

    static func expectCode(_ ch: LarkChannel, _ code: LarkChannelError.Code, messageContains: String? = nil) async {
        do {
            _ = try await ch.fetchBotIdentity()
            Issue.record("expected throw")
        } catch let e as LarkChannelError {
            #expect(e.code == code)
            if let messageContains { #expect(e.message.contains(messageContains)) }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func http401IsPermissionDenied() async throws {
        let ch = try Self.channel { _ in MockHTTPClient.json(["code": 99991401, "msg": "invalid token"], status: 401) }
        await Self.expectCode(ch, .permissionDenied)
    }

    @Test func http403IsPermissionDenied() async throws {
        let ch = try Self.channel { _ in MockHTTPClient.json(["code": 99991400, "msg": "forbidden"], status: 403) }
        await Self.expectCode(ch, .permissionDenied)
    }

    /// node: `{ response: { data: { code: 99991401 } } }` without a status.
    @Test func feishuAuthCodeWithoutStatusIsPermissionDenied() async throws {
        let ch = try Self.channel { _ in
            throw LarkError.api(LarkAPIError(code: 99991401, msg: "auth failed", httpStatus: 0, logId: nil, headers: [:], body: Data()))
        }
        await Self.expectCode(ch, .permissionDenied)
    }

    @Test func http429PassesThroughAsRateLimited() async throws {
        let ch = try Self.channel { _ in MockHTTPClient.json(["msg": "too many requests"], status: 429) }
        await Self.expectCode(ch, .rateLimited)
    }

    /// node: `{ code: 'ETIMEDOUT' }` — Swift transports fail with `URLError.timedOut`.
    @Test func timeoutPassesThroughAsSendTimeout() async throws {
        let ch = try Self.channel { _ in throw URLError(.timedOut) }
        await Self.expectCode(ch, .sendTimeout)
    }

    @Test func unclassifiableFailureFallsBackToNotConnected() async throws {
        struct Refused: Error, CustomStringConvertible { var description: String { "ECONNREFUSED: no route to host" } }
        let ch = try Self.channel { _ in throw Refused() }
        await Self.expectCode(ch, .notConnected)
    }

    @Test func missingOpenIdFallsBackToNotConnected() async throws {
        let ch = try Self.channel { _ in MockHTTPClient.json(["bot": [:]]) }
        await Self.expectCode(ch, .notConnected, messageContains: "could not resolve bot identity")
        do {
            _ = try await ch.fetchBotIdentity()
        } catch let e as LarkChannelError {
            #expect("\(e.cause!)" == #"bot/v3/info response missing open_id: {"bot":{}}"#)
        }
    }

    @Test func successReturnsBotIdentity() async throws {
        let ch = try Self.channel { req in
            #expect(req.method == .get)
            #expect(req.url.path == Self.botPath)
            #expect(req.headers["Authorization"] == "Bearer t-123")
            #expect(req.headers["User-Agent"]?.hasSuffix(" channel") == true)
            return MockHTTPClient.json(["code": 0, "msg": "ok", "bot": ["open_id": "ou_abc", "app_name": "Test Bot"]])
        }
        #expect(try await ch.fetchBotIdentity() == BotIdentity(openId: "ou_abc", name: "Test Bot"))
        let ch2 = try Self.channel { _ in MockHTTPClient.json(["bot": ["open_id": "ou_abc"]]) }
        #expect(try await ch2.fetchBotIdentity().name == "bot")
    }

    // MARK: Lifecycle

    static let wsAppId = "cli_0123456789abcdef"

    static func wsHTTP(endpointCode: Int = 0, botCalls: Recorder<Int>? = nil) -> MockHTTPClient {
        TestSupport.http { req in
            switch req.url.path {
            case botPath:
                botCalls?.append(1)
                return MockHTTPClient.json(["code": 0, "bot": ["open_id": "ou_bot", "app_name": "Bot"]])
            case "/callback/ws/endpoint":
                if endpointCode != 0 { return MockHTTPClient.json(["code": .number(Double(endpointCode)), "msg": "forbidden"]) }
                return MockHTTPClient.json([
                    "code": 0,
                    "data": [
                        "URL": "wss://msg-frontier.feishu.cn/ws/v2?device_id=dev1&service_id=33",
                        "ClientConfig": ["PingInterval": 120, "ReconnectCount": 2, "ReconnectInterval": 0, "ReconnectNonce": 0],
                    ],
                ])
            default:
                return MockHTTPClient.json(["code": 0, "data": ["message_id": "om_sent"]])
            }
        }
    }

    @Test func connectOpensWebSocketAndDeliversMessages() async throws {
        let connector = MockConnector()
        let botCalls = Recorder<Int>()
        let ch = try TestSupport.channel(
            http: Self.wsHTTP(botCalls: botCalls), connector: connector, appId: Self.wsAppId)
        ch.botIdentity = nil
        #expect(await ch.getConnectionStatus() == nil)
        let got = Recorder<NormalizedMessage>()
        let reconnected = Recorder<Int>()
        ch.on(.message) { got.append($0) }
        ch.on(.reconnected) { _ in reconnected.append(1) }

        // Concurrent connects share one attempt.
        async let a: Void = ch.connect()
        async let b: Void = ch.connect()
        _ = try await (a, b)
        #expect(botCalls.count == 1)
        #expect(ch.botIdentity == BotIdentity(openId: "ou_bot", name: "Bot"))
        #expect(await ch.getConnectionStatus()?.state == .connected)
        try await ch.connect()  // idempotent
        #expect(botCalls.count == 1)

        let socket = try #require(connector.sockets.first)
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        let payload = Data(
            #"{"schema":"2.0","header":{"event_type":"im.message.receive_v1","event_id":"e1"},"event":{"sender":{"sender_id":{"open_id":"ou_alice"}},"message":{"message_id":"om_ws","chat_id":"oc_1","chat_type":"p2p","message_type":"text","content":"{\"text\":\"hi from ws\"}","create_time":"\#(ts)"}}}"#.utf8)
        socket.push(
            WSFrame(seqID: 1, logID: 1, service: 33, method: 1, headers: [
                .init(key: "type", value: "event"), .init(key: "message_id", value: "m1"),
                .init(key: "sum", value: "1"), .init(key: "seq", value: "0"), .init(key: "trace_id", value: "t"),
            ], payload: payload))
        #expect(await eventually { got.count == 1 })
        #expect(got.items.first?.content == "hi from ws")

        socket.drop()
        #expect(await eventually { reconnected.count == 1 })

        await ch.disconnect()
        #expect(await ch.getConnectionStatus()?.state == .idle)
        await ch.disconnect()  // no-op when not connected
    }

    @Test func connectFailsWhenWebSocketCannotConnect() async throws {
        let ch = try TestSupport.channel(http: Self.wsHTTP(endpointCode: 403), connector: MockConnector(), appId: Self.wsAppId)
        do {
            try await ch.connect()
            Issue.record("expected throw")
        } catch let e as LarkChannelError {
            #expect(e.code == .notConnected)
            #expect(e.message.hasPrefix("WebSocket connect failed: "))
        }
        #expect(await ch.getConnectionStatus()?.state == .failed)
    }

    struct HangingConnector: WebSocketConnector {
        func connect(url: URL, headers: [String: String], timeout: TimeInterval?) async throws -> any WebSocketConnection {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw URLError(.timedOut)
        }
    }

    @Test func handshakeTimeoutRejectsWithNotConnected() async throws {
        let ch = try TestSupport.channel(http: Self.wsHTTP(), connector: HangingConnector(), appId: Self.wsAppId)
        do {
            try await ch.connectWebSocket(timeoutMs: 50)
            Issue.record("expected throw")
        } catch let e as LarkChannelError {
            #expect(e.code == .notConnected)
            #expect(e.message == "WebSocket handshake did not complete within 50ms")
        }
        await ch.rawWsClient?.close()
    }

    @Test func webhookTransportSkipsWebSocket() async throws {
        let ch = try TestSupport.channel(http: Self.wsHTTP(), transport: .webhook, appId: Self.wsAppId)
        try await ch.connect()
        #expect(ch.rawWsClient == nil)
        #expect(await ch.getConnectionStatus() == nil)
        // Webhook requests go through the channel dispatcher.
        let got = Recorder<CardActionEvent>()
        ch.on(.cardAction) { got.append($0) }
        let body = try JSONValue(
            jsonString: #"{"schema":"2.0","header":{"event_type":"card.action.trigger"},"event":{"context":{"open_message_id":"om_1","open_chat_id":"oc_1"},"operator":{"open_id":"ou_1"},"action":{"tag":"button","value":"v"}}}"#)
        let resp = await ch.handleWebhook(WebhookRequest(headers: [:], body: Data(body.jsonString().utf8)))
        #expect(resp.statusCode == 200)
        #expect(got.items.first?.action.value == "v")
        await ch.disconnect()
    }

    @Test func failedConnectCanBeRetried() async throws {
        let attempts = Recorder<Int>()
        let http = TestSupport.http { req in
            attempts.append(1)
            if attempts.count == 1 { return MockHTTPClient.json(["msg": "busy"], status: 429) }
            return MockHTTPClient.json(["bot": ["open_id": "ou_bot"]])
        }
        let ch = try TestSupport.channel(http: http, transport: .webhook)
        await #expect(throws: LarkChannelError.self) { try await ch.connect() }
        try await ch.connect()
        #expect(ch.botIdentity?.openId == "ou_bot")
    }
}
