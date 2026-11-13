import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `ws-client/__tests__/client-assertion.ts` (endpoint-discovery credential branch).
// Only placeholder fake values.

private let appId = "cli_ABCDEF0123456789"
private let fakeAssertion = "aaa.bbb.ccc"

private func startClient(
    provider: (any ClientAssertionProvider)?, appSecret: String = "", autoReconnect: Bool = true,
    onError: (@Sendable (Error) -> Void)? = nil
) async -> (WSClient, ControlledHTTPClient, Task<Void, Never>) {
    let http = ControlledHTTPClient()
    // MockConnector completes handshakes immediately, so close() can finish the started session.
    let client = try! WSClient(
        .init(
            appId: appId, appSecret: appSecret, clientAssertionProvider: provider, logLevel: .fatal, httpClient: http,
            webSocketConnector: MockConnector(), autoReconnect: autoReconnect, onError: onError))
    let started = Task { await client.start(eventDispatcher: EventDispatcher(cache: DefaultLarkCache(), logLevel: .fatal)) }
    return (client, http, started)
}

private func lastBody(_ http: ControlledHTTPClient) throws -> JSONValue {
    try JSONValue(data: try #require(http.requests.last?.body))
}

@Suite struct NodeWSClientAssertionTests {
    @Test("ws/client-assertion: provider mode: body AppSecret empty + ClientAssertion set; provider aud = OpenAPI host")
    func providerMode() async throws {
        let provider = RecordingAssertionProvider()
        let (client, http, started) = await startClient(provider: provider)
        #expect(await eventually { http.requests.count == 1 })

        let body = try lastBody(http)
        #expect(body["AppID"]?.stringValue == appId)
        #expect(body["AppSecret"]?.stringValue == "")
        #expect(body["ClientAssertion"]?.stringValue == fakeAssertion)
        #expect(provider.auds == ["open.feishu.cn"])

        http.resolveNext(ControlledHTTPClient.wsSuccess)
        await client.close()
        await started.value
    }

    @Test("ws/client-assertion: proxy branch: targetInfo rewrites url + adds X-Target-Service")
    func proxyBranch() async throws {
        let provider = RecordingAssertionProvider(target: TargetInfo(targetService: "proxy.example.org", targetPrefix: "/proxy/Lark"))
        let (client, http, started) = await startClient(provider: provider)
        #expect(await eventually { http.requests.count == 1 })

        let req = try #require(http.requests.last)
        #expect(req.url.absoluteString.contains("proxy.example.org"))
        #expect(req.url.absoluteString.contains("/proxy/Lark"))
        #expect(req.headers["X-Target-Service"] == "open.feishu.cn")

        http.resolveNext(ControlledHTTPClient.wsSuccess)
        await client.close()
        await started.value
    }

    @Test("ws/client-assertion: secret mode (no provider): body has AppSecret, no ClientAssertion (regression)")
    func secretMode() async throws {
        let (client, http, started) = await startClient(provider: nil, appSecret: "fake-secret-1")
        #expect(await eventually { http.requests.count == 1 })

        let body = try lastBody(http)
        #expect(body["AppSecret"]?.stringValue == "fake-secret-1")
        #expect(body["ClientAssertion"] == nil)

        http.resolveNext(ControlledHTTPClient.wsSuccess)
        await client.close()
        await started.value
    }

    @Test("ws/client-assertion: non-ok server code → server msg is propagated (not generic system busy)")
    func serverMessagePropagated() async throws {
        let errors = Box<[String]>([])
        let (client, http, started) = await startClient(
            provider: RecordingAssertionProvider(), autoReconnect: false, onError: { e in errors.mutate { $0.append("\(e)") } })
        #expect(await eventually { http.pendingCount == 1 })

        http.resolveNext(ControlledHTTPClient.wsFailure(403, "assertion rejected by gateway"))
        await started.value

        #expect(errors.value.count == 1)
        #expect(errors.value.first?.contains("assertion rejected by gateway") == true)
        await client.close()
    }

    // Derived from node-sdk `pullConnectConfig` (no dedicated node test): only ClientAssertionError
    // and ConnectionConfigError are terminal, so a provider that throws is retried.
    @Test("ws/client-assertion: provider errors are retryable, an empty assertion is fatal (pullConnectConfig catch branch)")
    func providerFailureClassification() async throws {
        let throwing = try WSClient(
            .init(
                appId: appId, clientAssertionProvider: RecordingAssertionProvider { throw TestError("signer down") }, logLevel: .fatal,
                httpClient: ControlledHTTPClient(), webSocketConnector: ControlledConnector()))
        guard case .retryable = await throwing.pullConnectConfig() else {
            Issue.record("a throwing provider must be retryable")
            return
        }
        let badProxy = try WSClient(
            .init(
                appId: appId, clientAssertionProvider: RecordingAssertionProvider(target: TargetInfo(targetService: "http://evil.org")),
                logLevel: .fatal, httpClient: ControlledHTTPClient(), webSocketConnector: ControlledConnector()))
        guard case .retryable = await badProxy.pullConnectConfig() else {
            Issue.record("a rejected proxy target is a plain Error in node: retryable")
            return
        }
        let empty = try WSClient(
            .init(
                appId: appId, clientAssertionProvider: RecordingAssertionProvider(value: ""), logLevel: .fatal,
                httpClient: ControlledHTTPClient(), webSocketConnector: ControlledConnector()))
        guard case .fatal(let message) = await empty.pullConnectConfig() else {
            Issue.record("an empty assertion must be fatal")
            return
        }
        #expect(message == "client assertion token is empty")
    }
}
