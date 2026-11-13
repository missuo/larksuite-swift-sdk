import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `ws-client/__tests__/receive-events.ts` (issue #201): inbound frames that fail
// to decode / merge / parse are logged instead of being dropped silently or crashing.

private func makeClient(logger: RecordingLogger, http: any LarkHTTPClient = ControlledHTTPClient(), connector: any WebSocketConnector = MockConnector())
    throws -> WSClient
{
    try WSClient(
        .init(appId: testWSAppId, appSecret: "secret", logLevel: .trace, logger: logger, httpClient: http, webSocketConnector: connector))
}

private func eventFrame(messageId: String, sum: String, seq: String, traceId: String, payload: Data) -> WSFrame {
    WSFrame(
        seqID: 1, logID: 2, service: 1, method: 1,
        headers: [
            .init(key: "type", value: "event"), .init(key: "message_id", value: messageId), .init(key: "sum", value: sum),
            .init(key: "seq", value: seq), .init(key: "trace_id", value: traceId),
        ],
        payload: payload)
}

/// Next outbound data frame (acks); pings are skipped.
private func nextAck(_ socket: MockWebSocket) async throws -> WSFrame? {
    for await data in socket.outbound {
        let frame = try WSFrame(serializedData: data)
        if frame.method == 1 { return frame }
    }
    return nil
}

@Suite struct NodeWSReceiveEventsTests {
    @Test("receive-events: decode failure is logged and the connection survives")
    func decodeFailure() async throws {
        let logger = RecordingLogger()
        let http = ControlledHTTPClient()
        let connector = MockConnector()
        let client = try makeClient(logger: logger, http: http, connector: connector)
        let started = Task { await client.start(eventDispatcher: EventDispatcher(cache: DefaultLarkCache(), logLevel: .fatal)) }
        #expect(await eventually { http.pendingCount == 1 })
        http.resolveNext(ControlledHTTPClient.wsSuccess)
        await started.value
        let socket = try #require(connector.sockets.first)

        socket.pushRaw(Data([1, 2, 3]))
        #expect(await eventually { !logger.messages(.error).isEmpty })

        let errors = logger.messages(.error).joined(separator: "\n")
        #expect(errors.contains("failed to handle inbound frame"))
        #expect(errors.contains("invalid field number 0"))
        // The connection is still alive: same socket, no reconnect happened.
        #expect(await client.testHasConnection)
        #expect(connector.sockets.count == 1)

        // A subsequent valid frame is still processed without new errors.
        socket.push(WSFrame(method: 0, headers: [.init(key: "type", value: "ping")]))
        socket.push(WSFrame(method: 0, headers: [.init(key: "type", value: "pong")], payload: Data(#"{"PingInterval":7}"#.utf8)))
        #expect(await eventually { await client.settings.pingInterval == 7 })
        #expect(logger.messages(.error).count == 1)
        await client.close()
    }

    @Test("receive-events: malformed event fragment metadata is logged with message_id")
    func malformedFragmentMetadata() async throws {
        let logger = RecordingLogger()
        let client = try makeClient(logger: logger)
        await client.handleData(eventFrame(messageId: "msg_1", sum: "not-a-number", seq: "0", traceId: "trace_1", payload: Data([1, 2, 3])))

        let errors = logger.messages(.error).joined(separator: "\n")
        #expect(errors.contains("failed to merge event fragments"))
        #expect(errors.contains("msg_1"))
    }

    @Test("receive-events: malformed pong payload is logged, not crashed")
    func malformedPong() async throws {
        let logger = RecordingLogger()
        let client = try makeClient(logger: logger)
        await client.handleControl(WSFrame(method: 0, headers: [.init(key: "type", value: "pong")], payload: Data("this is not json".utf8)))
        #expect(logger.messages(.error).joined().contains("invalid pong payload"))
    }

    @Test("receive-events: valid fragmented event merges, dispatches to the handler and ACKs")
    func validFragmentedEvent() async throws {
        let logger = RecordingLogger()
        let client = try makeClient(logger: logger)
        let handler = HandlerSpy()
        let dispatcher = EventDispatcher(cache: DefaultLarkCache(), logLevel: .fatal).register("im.message.receive_v1", handler.handler)
        await client.testSet(dispatcher: dispatcher)
        let socket = MockWebSocket()
        await client.testAdopt(socket)

        let eventPayload: JSONValue = [
            "schema": "2.0",
            "header": [
                "event_id": "evt_1", "event_type": "im.message.receive_v1", "create_time": "2026-01-01T00:00:00+08:00", "token": "t",
                "app_id": "cli_x", "tenant_key": "tk",
            ],
            "event": ["message": ["message_id": "om_1"], "sender": [:]],
        ]
        let bytes = Data(eventPayload.jsonString().utf8)
        let half = (bytes.count + 1) / 2

        await client.handleData(eventFrame(messageId: "msg_2", sum: "2", seq: "0", traceId: "trace_2", payload: bytes.prefix(half)))
        await client.handleData(eventFrame(messageId: "msg_2", sum: "2", seq: "1", traceId: "trace_2", payload: bytes.suffix(from: half)))

        let ack = try #require(try await nextAck(socket))
        #expect(handler.count == 1)
        #expect(ack.headers.contains(.init(key: "message_id", value: "msg_2")))
        #expect(try JSONValue(data: try #require(ack.payload)) == ["code": 200])
        #expect(!logger.messages(.error).joined().contains("failed to merge"))
        await client.close()
    }

    // Derived from node-sdk `DataCache.mergeData` (it JSON-parses the merged bytes, so a parse failure
    // is reported as a merge failure and `handleEventData` returns before sending any ack).
    @Test("receive-events: merged payload that is not JSON is logged as a merge failure and not acknowledged")
    func invalidJSONNotAcked() async throws {
        let logger = RecordingLogger()
        let client = try makeClient(logger: logger)
        await client.testSet(dispatcher: EventDispatcher(cache: DefaultLarkCache(), logLevel: .fatal))
        let socket = MockWebSocket()
        await client.testAdopt(socket)

        await client.handleData(eventFrame(messageId: "bad", sum: "1", seq: "0", traceId: "t", payload: Data("not json".utf8)))
        await client.handleData(
            eventFrame(messageId: "good", sum: "1", seq: "0", traceId: "t", payload: Data(#"{"schema":"2.0","header":{"event_type":"x"}}"#.utf8)))

        let errors = logger.messages(.error).joined(separator: "\n")
        #expect(errors.contains("failed to merge event fragments, message_id: bad"))
        // The first (and only) ack is for the valid frame.
        let ack = try #require(try await nextAck(socket))
        #expect(ack.header("message_id") == "good")
        await client.close()
    }
}
