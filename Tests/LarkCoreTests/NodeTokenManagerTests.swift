import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `client/__tests__/token-manager.test.ts`.

private let domain = "https://open.feishu.cn"
private let appId = "cli_test_app"

/// `makeHttp` in the node test: replies by URL substring, failing on unexpected URLs.
private func routedHTTP(_ routes: [(String, @Sendable () throws -> JSONValue)]) -> MockHTTPClient {
    MockHTTPClient { req in
        let url = req.url.absoluteString
        guard let route = routes.first(where: { url.contains($0.0) }) else {
            throw TestError("unexpected POST to \(url)")
        }
        return MockHTTPClient.json(try route.1())
    }
}

private func makeManager(
    appType: LarkAppType, cache: RecordingCache, http: MockHTTPClient, logger: RecordingLogger = RecordingLogger(),
    appSecret: String = "app_secret_value"
) -> TokenManager {
    let config = LarkConfiguration(
        appId: appId, appSecret: appSecret, domain: .custom(domain), appType: appType, logLevel: .trace, logger: logger,
        cache: cache, httpClient: http)
    return TokenManager(config: config, baseURL: domain, logger: LoggerProxy(level: .trace, sink: logger), userAgent: "ua")
}

private func message(of error: any Error) -> String { "\(error)" }

@Suite struct NodeTokenManagerTests {
    // MARK: getCustomTenantAccessToken (self-build)

    @Test("token-manager: rethrows the original transport error instead of a secondary destructure error")
    func rethrowsTransportError() async throws {
        let logger = RecordingLogger()
        let cache = RecordingCache()
        let http = routedHTTP([("tenant_access_token/internal", { throw TestError("EPIPE") })])
        let tm = makeManager(appType: .selfBuild, cache: cache, http: http, logger: logger)

        await #expect(throws: TestError("EPIPE")) { try await tm.tenantAccessToken() }
        await #expect(throws: TestError("EPIPE")) { try await tm.tenantAccessToken() }
        #expect(await cache.setCalls.isEmpty)
        #expect(!logger.messages(.error).isEmpty)
    }

    @Test("token-manager: throws on business error (no token field) and does not cache")
    func businessErrorNotCached() async throws {
        let cache = RecordingCache()
        let http = routedHTTP([("tenant_access_token/internal", { ["code": 99991663, "msg": "app ticket invalid"] })])
        let tm = makeManager(appType: .selfBuild, cache: cache, http: http)

        let error = await #expect(throws: LarkError.self) { try await tm.tenantAccessToken() }
        #expect(message(of: try #require(error)).contains("99991663"))
        #expect(message(of: try #require(error)).contains("app ticket invalid"))
        #expect(await cache.setCalls.isEmpty)
    }

    @Test("token-manager: success path is unchanged: returns token and caches with 3-min-earlier expiry")
    func successCachesWithMargin() async throws {
        let cache = RecordingCache()
        let http = routedHTTP([("tenant_access_token/internal", { ["code": 0, "tenant_access_token": "t-xxx", "expire": 7200] })])
        let tm = makeManager(appType: .selfBuild, cache: cache, http: http)

        let before = Date()
        let token = try await tm.tenantAccessToken()
        let after = Date()

        #expect(token == "t-xxx")
        let calls = await cache.setCalls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.key == LarkCacheKey.tenantAccessToken)
        #expect(call.value == "t-xxx")
        #expect(call.namespace == appId)
        let offset: TimeInterval = 7200 - 3 * 60
        let expiry = try #require(call.expiresAt)
        #expect(expiry >= before.addingTimeInterval(offset))
        #expect(expiry <= after.addingTimeInterval(offset))
    }

    @Test("token-manager: cache hit short-circuits without any request")
    func cacheHit() async throws {
        let cache = RecordingCache([(LarkCacheKey.tenantAccessToken, "cached-t", appId)])
        let http = routedHTTP([])
        let tm = makeManager(appType: .selfBuild, cache: cache, http: http)

        #expect(try await tm.tenantAccessToken() == "cached-t")
        #expect(http.requests.isEmpty)
    }

    @Test("token-manager: business-error message does not leak credentials")
    func businessErrorNoLeak() async throws {
        let cache = RecordingCache()
        let http = routedHTTP([("tenant_access_token/internal", { ["code": 1, "msg": "bad"] })])
        let tm = makeManager(appType: .selfBuild, cache: cache, http: http, appSecret: "SUPER_SECRET_xyz")

        let error = await #expect(throws: LarkError.self) { try await tm.tenantAccessToken() }
        #expect(!message(of: try #require(error)).contains("SUPER_SECRET_xyz"))
    }

    // MARK: getMarketTenantAccessToken (ISV)

    @Test("token-manager: rethrows transport error from app_access_token request and does not cache")
    func marketTransportError() async throws {
        let cache = RecordingCache([(LarkCacheKey.appTicket, "ticket-1", appId)])
        let http = routedHTTP([("auth/v3/app_access_token", { throw TestError("ETIMEDOUT") })])
        let tm = makeManager(appType: .isv, cache: cache, http: http)

        await #expect(throws: TestError("ETIMEDOUT")) { try await tm.tenantAccessToken(tenantKey: "tk") }
        #expect(await !cache.setCalls.contains { $0.key == "larkMarketAccessTokentk" })
    }

    @Test("token-manager: throws when tenant_access_token field missing and does not cache")
    func marketMissingTenantToken() async throws {
        let cache = RecordingCache([(LarkCacheKey.appTicket, "ticket-1", appId)])
        let http = routedHTTP([
            ("auth/v3/app_access_token", { ["code": 0, "app_access_token": "a-xxx"] }),
            ("auth/v3/tenant_access_token", { ["code": 1, "msg": "boom"] }),
        ])
        let tm = makeManager(appType: .isv, cache: cache, http: http)

        let error = await #expect(throws: LarkError.self) { try await tm.tenantAccessToken(tenantKey: "tk") }
        #expect(message(of: try #require(error)).contains("1"))
        #expect(message(of: try #require(error)).contains("boom"))
        #expect(await !cache.setCalls.contains { $0.key == "larkMarketAccessTokentk" })
        // node-sdk never caches the intermediate app_access_token either: nothing is written.
        #expect(await cache.setCalls.isEmpty)
    }

    @Test("token-manager: success path is unchanged: returns tenant token and caches it")
    func marketSuccess() async throws {
        let cache = RecordingCache([(LarkCacheKey.appTicket, "ticket-1", appId)])
        let http = routedHTTP([
            ("auth/v3/app_access_token", { ["code": 0, "app_access_token": "a-xxx"] }),
            ("auth/v3/tenant_access_token", { ["code": 0, "tenant_access_token": "t-yyy", "expire": 7200] }),
        ])
        let tm = makeManager(appType: .isv, cache: cache, http: http)

        let before = Date()
        let token = try await tm.tenantAccessToken(tenantKey: "tk")
        let after = Date()

        #expect(token == "t-yyy")
        let call = try #require(await cache.setCalls.first { $0.key == "larkMarketAccessTokentk" })
        #expect(call.value == "t-yyy")
        #expect(call.namespace == appId)
        let offset: TimeInterval = 7200 - 3 * 60
        let expiry = try #require(call.expiresAt)
        #expect(expiry >= before.addingTimeInterval(offset))
        #expect(expiry <= after.addingTimeInterval(offset))
        // Request bodies match node-sdk.
        let bodies = try http.requests.map { try JSONValue(data: $0.body ?? Data()) }
        #expect(bodies.first == ["app_id": .string(appId), "app_secret": "app_secret_value", "app_ticket": "ticket-1"])
        #expect(bodies.last == ["app_access_token": "a-xxx", "tenant_key": "tk"])
    }

    @Test("token-manager: cache hit short-circuits without token request")
    func marketCacheHit() async throws {
        let cache = RecordingCache([
            ("larkMarketAccessTokentk", "cached-m", appId),
            (LarkCacheKey.appTicket, "ticket-1", appId),
        ])
        let http = routedHTTP([])
        let tm = makeManager(appType: .isv, cache: cache, http: http)

        #expect(try await tm.tenantAccessToken(tenantKey: "tk") == "cached-m")
        #expect(http.requests.isEmpty)
    }
}
