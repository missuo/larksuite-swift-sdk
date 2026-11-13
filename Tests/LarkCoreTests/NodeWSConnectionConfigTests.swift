import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `ws-client/__tests__/connection-config.ts` (connectionHost / connectionHeaders).

private let endpoint = "wss://original.test/a%2Fb?device_id=d&service_id=42&x=%2F&x=2"

private func createClient(
    connectionHost: String? = nil, connectionHeaders: [String: String] = [:], http: any LarkHTTPClient = ControlledHTTPClient(),
    connector: any WebSocketConnector = ControlledConnector()
) throws -> WSClient {
    try WSClient(
        .init(
            appId: "cli_ABCDEF0123456789", appSecret: "placeholder", logLevel: .fatal, httpClient: http, webSocketConnector: connector,
            connectionHost: connectionHost, connectionHeaders: connectionHeaders))
}

@Suite struct NodeWSConnectionConfigTests {
    @Test("connection-config: host override preserves raw path/query: %s", arguments: ["example.test", "example.test:443", "127.0.0.1:80", "[::1]", "[::1]:443"])
    func hostOverride(host: String) throws {
        _ = try createClient(connectionHost: host)
        #expect(try WSClient.buildConnectionURL(endpoint, host: host).absoluteString == "wss://\(host)/a%2Fb?device_id=d&service_id=42&x=%2F&x=2")
        #expect(try WSClient.buildConnectionURL(endpoint, host: nil).absoluteString == endpoint)
    }

    /// node's sixth case is the number 123 (a non-string host), which `String?` cannot represent.
    @Test("connection-config: rejects invalid host before network: %s", arguments: ["", " ", "https://x", "x/path", "x?q=1"])
    func rejectsInvalidHost(host: String) {
        let connector = ControlledConnector()
        let error = #expect(throws: LarkError.self) { try createClient(connectionHost: host, connector: connector) }
        #expect(error?.description.contains("invalid websocket connection host") == true)
        #expect(connector.attempts == 0)
    }

    @Test("connection-config: rejects reserved header: %s", arguments: ["Host", "cOnNeCtIoN", "Upgrade", "sEc-WeBsOcKeT-Key"])
    func rejectsReservedHeader(name: String) {
        let error = #expect(throws: LarkError.self) { try createClient(connectionHeaders: [name: "value"]) }
        #expect(error?.description.contains("invalid websocket connection headers") == true)
    }

    @Test("connection-config: invalid overridden endpoint is terminal: %s", arguments: ["https://x/ws", "wss://user@x/ws", "wss://x/ws#", "wss:///path"])
    func invalidEndpoint(value: String) {
        let error = #expect(throws: LarkError.self) { try WSClient.buildConnectionURL(value, host: "logical.test") }
        #expect(error?.description.contains("invalid websocket connection endpoint") == true)
    }

    @Test("connection-config: bootstrap and repeated handshakes use isolated configuration and existing agent")
    func isolatedConfiguration() async throws {
        // `agent` (a Node http.Agent) has no Swift counterpart; the rest is ported.
        let http = MockHTTPClient { _ in
            MockHTTPClient.json([
                "code": 0, "msg": "ok",
                "data": ["URL": .string(endpoint), "ClientConfig": ["PingInterval": 120, "ReconnectCount": 3, "ReconnectInterval": 1, "ReconnectNonce": 0]],
            ])
        }
        let connector = ControlledConnector()
        var headers = ["X-Route": "ws-only"]
        let client = try createClient(connectionHost: "logical.test:8443", connectionHeaders: headers, http: http, connector: connector)
        headers["X-Route"] = "caller-mutated"
        _ = headers
        for i in 0..<2 {
            let pulled = await client.pullConnectConfig()
            guard case .ok = pulled else {
                Issue.record("pullConnectConfig: \(pulled)")
                return
            }
            let bootstrap = http.requests[i]
            #expect(bootstrap.url.absoluteString.contains("/callback/ws/endpoint"))
            #expect(bootstrap.headers["X-Route"] == nil)
            let pending = Task { await client.connect() }
            #expect(await eventually { connector.attempts == i + 1 })
            #expect(connector.urls[i].absoluteString == "wss://logical.test:8443/a%2Fb?device_id=d&service_id=42&x=%2F&x=2")
            #expect(connector.headers[i] == ["X-Route": "ws-only"])
            #expect(connector.failNext())
            #expect(await pending.value == false)
        }
    }

    @Test("connection-config: default connection preserves original URL and options")
    func defaultConnection() async throws {
        let connector = ControlledConnector()
        let client = try createClient(connector: connector)
        await client.testSetConnectURL(URL(string: endpoint)!)
        let pending = Task { await client.connect() }
        #expect(await eventually { connector.attempts == 1 })
        #expect(connector.urls.first?.absoluteString == endpoint)
        #expect(connector.headers.first == [:])
        #expect(connector.failNext())
        #expect(await pending.value == false)
    }

    @Test("connection-config: invalid overridden endpoint is classified as non-retryable")
    func invalidEndpointNonRetryable() async throws {
        let http = MockHTTPClient { _ in
            MockHTTPClient.json(["code": 0, "data": ["URL": "wss://user@original.test/ws", "ClientConfig": [:]]])
        }
        let connector = ControlledConnector()
        let client = try createClient(connectionHost: "logical.test", http: http, connector: connector)
        let result = await client.pullConnectConfig()
        guard case .fatal(let message) = result else {
            Issue.record("expected fatal, got \(result)")
            return
        }
        #expect(message == "invalid websocket connection endpoint")
        #expect(connector.attempts == 0)
    }
}

extension WSClient {
    func testSetConnectURL(_ url: URL) { settings.connectURL = url }
}
