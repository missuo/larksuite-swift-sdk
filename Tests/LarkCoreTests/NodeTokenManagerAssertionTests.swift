import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `client/__tests__/token-manager-assertion.ts` (ClientAssertion TAT acquisition).
// Only placeholder fake values.

private let appId = "cli_ABCDEF0123456789"
private let fakeAssertion = "aaa.bbb.ccc"

/// Records the audiences it was asked for and returns a fixed token (or fails).
final class RecordingAssertionProvider: ClientAssertionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _auds: [String] = []
    let result: @Sendable () throws -> ClientAssertionToken

    init(_ result: @escaping @Sendable () throws -> ClientAssertionToken) { self.result = result }
    convenience init(value: String = "aaa.bbb.ccc", target: TargetInfo? = nil) {
        self.init { ClientAssertionToken(value: value, targetInfo: target) }
    }

    var auds: [String] { lock.withLock { _auds } }

    func retrieveToken(aud: String) async throws -> ClientAssertionToken {
        lock.withLock { _auds.append(aud) }
        return try result()
    }
}

private func makeTokenManager(
    provider: (any ClientAssertionProvider)?, appSecret: String = "", appType: LarkAppType = .selfBuild,
    cache: any LarkCache = DefaultLarkCache(), http: MockHTTPClient
) -> TokenManager {
    let config = LarkConfiguration(
        appId: appId, appSecret: appSecret, clientAssertionProvider: provider, appType: appType, logLevel: .fatal, cache: cache,
        httpClient: http)
    return TokenManager(config: config, baseURL: "https://open.feishu.cn", logger: LoggerProxy(level: .fatal), userAgent: "ua")
}

private func body(_ req: LarkHTTPRequest?) throws -> JSONValue { try JSONValue(data: try #require(req?.body)) }

@Suite struct NodeTokenManagerAssertionTests {
    @Test("token-manager-assertion: hits oauth token uri with jwt-bearer body, no client_secret; provider aud is OAuth host")
    func requestConstruction() async throws {
        let provider = RecordingAssertionProvider()
        let http = MockHTTPClient { _ in MockHTTPClient.json(["access_token": "fake-tat-1", "expire": 7200]) }
        let tm = makeTokenManager(provider: provider, http: http)

        #expect(try await tm.tenantAccessToken() == "fake-tat-1")

        let req = try #require(http.requests.last)
        #expect(req.url.absoluteString == "https://accounts.feishu.cn/oauth/v3/token")
        let b = try body(req)
        #expect(b["grant_type"]?.stringValue == "urn:ietf:params:oauth:grant-type:jwt-bearer")
        #expect(b["client_assertion_type"]?.stringValue == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
        #expect(b["client_assertion"]?.stringValue == fakeAssertion)
        #expect(b["client_id"]?.stringValue == appId)
        #expect(b["client_secret"] == nil)
        #expect(provider.auds == ["accounts.feishu.cn"])
    }

    @Test("token-manager-assertion: a cached tenant token returns without calling provider or http")
    func cacheHitSkipsProvider() async throws {
        let provider = RecordingAssertionProvider()
        let cache = DefaultLarkCache()
        await cache.set(LarkCacheKey.tenantAccessToken, value: "cached-tat", expiresAt: nil, namespace: appId)
        let http = MockHTTPClient { _ in MockHTTPClient.json([:]) }
        let tm = makeTokenManager(provider: provider, cache: cache, http: http)

        #expect(try await tm.tenantAccessToken() == "cached-tat")
        #expect(provider.auds.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test("token-manager-assertion: targetInfo rewrites url to proxy and adds X-Target-Service header")
    func proxyBranch() async throws {
        let provider = RecordingAssertionProvider(target: TargetInfo(targetService: "proxy.example.org", targetPrefix: "/proxy/Lark"))
        let http = MockHTTPClient { _ in MockHTTPClient.json(["access_token": "fake-tat-1", "expire": 7200]) }
        let tm = makeTokenManager(provider: provider, http: http)

        _ = try await tm.tenantAccessToken()

        let req = try #require(http.requests.last)
        #expect(req.url.absoluteString == "https://proxy.example.org/proxy/Lark/oauth/v3/token")
        #expect(req.headers["X-Target-Service"] == "accounts.feishu.cn")
    }

    @Test("token-manager-assertion: provider throwing → ClientAssertionError 7102")
    func providerThrows() async throws {
        let provider = RecordingAssertionProvider { throw TestError("signer down") }
        let tm = makeTokenManager(provider: provider, http: MockHTTPClient { _ in MockHTTPClient.json([:]) })
        let error = await #expect(throws: LarkError.self) { try await tm.tenantAccessToken() }
        guard case .clientAssertion(let code, _)? = error else { Issue.record("unexpected \(String(describing: error))"); return }
        #expect(code == 7102)
    }

    @Test("token-manager-assertion: provider returning empty value → ClientAssertionError 7101")
    func providerEmpty() async throws {
        let provider = RecordingAssertionProvider(value: "")
        let tm = makeTokenManager(provider: provider, http: MockHTTPClient { _ in MockHTTPClient.json([:]) })
        let error = await #expect(throws: LarkError.self) { try await tm.tenantAccessToken() }
        guard case .clientAssertion(let code, _)? = error else { Issue.record("unexpected \(String(describing: error))"); return }
        #expect(code == 7101)
    }

    @Test("token-manager-assertion: throws ClientAssertionError carrying error_description")
    func responseWithoutAccessToken() async throws {
        let provider = RecordingAssertionProvider()
        let http = MockHTTPClient { _ in MockHTTPClient.json(["error": "invalid_client", "error_description": "bad"]) }
        let tm = makeTokenManager(provider: provider, http: http)
        let error = await #expect(throws: LarkError.self) { try await tm.tenantAccessToken() }
        guard case .clientAssertion(_, let msg)? = error else { Issue.record("unexpected \(String(describing: error))"); return }
        #expect(msg.contains("bad"))
    }

    @Test("token-manager-assertion: with both configured, assertion is used (no client_secret, provider called)")
    func providerPriority() async throws {
        let provider = RecordingAssertionProvider()
        let http = MockHTTPClient { _ in MockHTTPClient.json(["access_token": "fake-tat-1", "expire": 7200]) }
        let tm = makeTokenManager(provider: provider, appSecret: "fake-secret-1", http: http)

        _ = try await tm.tenantAccessToken()

        let b = try body(http.requests.last)
        #expect(b["client_assertion"]?.stringValue == fakeAssertion)
        #expect(b["client_secret"] == nil)
        #expect(provider.auds.count == 1)
    }

    @Test("token-manager-assertion: getMarketTenantAccessToken throws ClientAssertionError 7100")
    func isvRejected() async throws {
        let provider = RecordingAssertionProvider()
        let tm = makeTokenManager(provider: provider, appType: .isv, http: MockHTTPClient { _ in MockHTTPClient.json([:]) })
        let error = await #expect(throws: LarkError.self) { try await tm.tenantAccessToken(tenantKey: "tenant-key-1") }
        guard case .clientAssertion(let code, _)? = error else { Issue.record("unexpected \(String(describing: error))"); return }
        #expect(code == 7100)
    }

    @Test("token-manager-assertion: still hits internal tenant_access_token endpoint with app_id/app_secret")
    func secretModeRegression() async throws {
        let cache = DefaultLarkCache()
        let http = MockHTTPClient { _ in MockHTTPClient.json(["tenant_access_token": "fake-tat-secret", "expire": 7200]) }
        let tm = makeTokenManager(provider: nil, appSecret: "fake-secret-1", cache: cache, http: http)

        #expect(try await tm.tenantAccessToken() == "fake-tat-secret")
        #expect(http.requests.count == 1)
        let req = try #require(http.requests.first)
        #expect(req.url.absoluteString == "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")
        #expect(try body(req) == ["app_id": .string(appId), "app_secret": "fake-secret-1"])
        #expect(await cache.get(LarkCacheKey.tenantAccessToken, namespace: appId) == "fake-tat-secret")
    }
}
