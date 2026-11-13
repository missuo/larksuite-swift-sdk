import Foundation
import Testing
@testable import LarkCore

@Suite struct WSClientTests {
    static let appId = "cli_0123456789abcdef"

    func endpointClient(pingInterval: Int = 120) -> MockHTTPClient {
        MockHTTPClient { req in
            #expect(req.url.path == "/callback/ws/endpoint")
            return MockHTTPClient.json([
                "code": 0,
                "data": [
                    "URL": "wss://msg-frontier.feishu.cn/ws/v2?device_id=dev1&service_id=33",
                    "ClientConfig": ["PingInterval": .number(Double(pingInterval)), "ReconnectCount": 2, "ReconnectInterval": 0, "ReconnectNonce": 0],
                ],
            ])
        }
    }

    func nextFrame(_ socket: MockWebSocket, where predicate: (WSFrame) -> Bool) async throws -> WSFrame? {
        for await data in socket.outbound {
            let f = try WSFrame(serializedData: data)
            if predicate(f) { return f }
        }
        return nil
    }

    @Test func receivesEventAndAcksWithHandlerResult() async throws {
        let http = endpointClient()
        let connector = MockConnector()
        let ready = AsyncStream<Void>.makeStream()
        let ws = try WSClient(
            .init(
                appId: Self.appId, appSecret: "secret", logLevel: .error, httpClient: http, webSocketConnector: connector,
                connectionHeaders: ["X-Test": "1"], onReady: { ready.continuation.yield() }))
        let dispatcher = EventDispatcher(logLevel: .error)
            .register("card.action.trigger") { event in
                CardActionResponse(toast: .init(type: .success, content: event.payload["action"]?["value"]?["option"]?.stringValue ?? ""))
            }
        await ws.start(eventDispatcher: dispatcher)
        var it = ready.stream.makeAsyncIterator()
        _ = await it.next()

        // Endpoint discovery body and connection parameters.
        let body = try JSONValue(data: http.requests[0].body!)
        #expect(body["AppID"]?.stringValue == Self.appId)
        #expect(body["AppSecret"]?.stringValue == "secret")
        #expect(connector.urls.first?.host == "msg-frontier.feishu.cn")
        #expect(connector.headers.first?["X-Test"] == "1")
        #expect(await ws.connectionStatus.state == .connected)

        let socket = connector.sockets[0]
        // First outbound frame is a ping on service 33.
        let ping = try await nextFrame(socket) { $0.method == 0 }
        #expect(ping?.header("type") == "ping")
        #expect(ping?.service == 33)

        // An event split in two fragments.
        let payload = Data(#"{"schema":"2.0","header":{"event_type":"card.action.trigger","event_id":"e"},"event":{"action":{"value":{"option":"A"}}}}"#.utf8)
        let half = payload.count / 2
        func frag(_ seq: Int, _ d: Data) -> WSFrame {
            WSFrame(seqID: 9, logID: 8, service: 33, method: 1, headers: [
                .init(key: "type", value: "event"), .init(key: "message_id", value: "mid"),
                .init(key: "sum", value: "2"), .init(key: "seq", value: String(seq)), .init(key: "trace_id", value: "tr"),
            ], payload: d)
        }
        socket.push(frag(1, payload.suffix(from: half)))
        socket.push(frag(0, payload.prefix(half)))

        let ack = try #require(try await nextFrame(socket) { $0.method == 1 })
        #expect(ack.seqID == 9)
        #expect(ack.header("biz_rt") != nil)
        let ackBody = try JSONValue(data: ack.payload!)
        #expect(ackBody["code"]?.intValue == 200)
        let decoded = try JSONValue(data: Data(base64Encoded: ackBody["data"]!.stringValue!)!)
        #expect(decoded["toast"]?["content"]?.stringValue == "A")

        await ws.close()
        #expect(await ws.connectionStatus.state == .idle)
    }

    @Test func pongUpdatesConfigAndReconnectsAfterDrop() async throws {
        let http = endpointClient()
        let connector = MockConnector()
        let reconnected = AsyncStream<Void>.makeStream()
        let ws = try WSClient(
            .init(
                appId: Self.appId, appSecret: "secret", logLevel: .error, httpClient: http, webSocketConnector: connector,
                onReconnected: { reconnected.continuation.yield() }))
        await ws.start(eventDispatcher: EventDispatcher(logLevel: .error))
        let socket = connector.sockets[0]
        socket.push(WSFrame(service: 33, method: 0, headers: [.init(key: "type", value: "pong")],
                            payload: Data(#"{"PingInterval":5,"ReconnectCount":3,"ReconnectInterval":0,"ReconnectNonce":0}"#.utf8)))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await ws.settings.pingInterval == 5)
        #expect(await ws.settings.reconnectCount == 3)

        socket.drop()
        var it = reconnected.stream.makeAsyncIterator()
        _ = await it.next()
        #expect(connector.sockets.count == 2)
        #expect(await ws.connectionStatus.state == .connected)
        await ws.close()
    }

    @Test func fatalEndpointErrorStops() async throws {
        let http = MockHTTPClient { _ in MockHTTPClient.json(["code": 403, "msg": "forbidden"]) }
        let failed = AsyncStream<String>.makeStream()
        let ws = try WSClient(
            .init(appId: Self.appId, appSecret: "s", logLevel: .fatal, httpClient: http, webSocketConnector: MockConnector(),
                  onError: { failed.continuation.yield("\($0)") }))
        await ws.start(eventDispatcher: EventDispatcher(logLevel: .error))
        var it = failed.stream.makeAsyncIterator()
        let msg = await it.next()
        #expect(msg?.contains("403") == true)
        #expect(await ws.connectionStatus.state == .failed)
    }

    @Test func rejectsReservedHandshakeHeaders() {
        #expect(throws: (any Error).self) {
            try WSClient(.init(appId: Self.appId, appSecret: "s", connectionHeaders: ["Sec-WebSocket-Key": "x"]))
        }
    }
}
