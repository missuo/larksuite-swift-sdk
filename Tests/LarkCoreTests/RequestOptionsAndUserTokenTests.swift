import Foundation
import Testing
@testable import LarkCore

/// node-sdk has no tests for `request-with.ts` or `user-access-token.ts`; these pin the
/// Swift behaviour to the node source.
@Suite struct RequestOptionsAndUserTokenTests {
    static func client(_ handler: @escaping @Sendable (LarkHTTPRequest) throws -> LarkHTTPResponse, cache: DefaultLarkCache = DefaultLarkCache(),
                       helpDesk: Bool = false) throws -> (LarkClient, MockHTTPClient) {
        let http = MockHTTPClient { req in
            if req.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
                return MockHTTPClient.json(["code": 0, "tenant_access_token": "t-managed", "expire": 7200])
            }
            if req.url.path == "/open-apis/auth/v3/app_access_token/internal" {
                return MockHTTPClient.json(["code": 0, "app_access_token": "a-managed", "expire": 7200])
            }
            return try handler(req)
        }
        let config = LarkConfiguration(
            appId: "cli_t", appSecret: "s", logLevel: .fatal, cache: cache, helpDeskId: helpDesk ? "hd" : nil,
            helpDeskToken: helpDesk ? "hdt" : nil, httpClient: http)
        return (try LarkClient(config), http)
    }

    static let ok: @Sendable (LarkHTTPRequest) throws -> LarkHTTPResponse = { _ in MockHTTPClient.json(["code": 0, "data": [:]]) }

    // MARK: request-with.ts

    @Test("withUserAccessToken: user token replaces the managed tenant token")
    func userToken() async throws {
        let (c, http) = try Self.client(Self.ok)
        _ = try await c.request(.get, "/open-apis/x", options: .userAccessToken("u-1"), as: JSONValue.self)
        #expect(http.requests.last?.headers["Authorization"] == "Bearer u-1")
        #expect(!http.requests.contains { $0.url.path.contains("tenant_access_token") })
    }

    @Test("default: managed tenant token")
    func managed() async throws {
        let (c, http) = try Self.client(Self.ok)
        _ = try await c.request(.get, "/open-apis/x", as: JSONValue.self)
        #expect(http.requests.last?.headers["Authorization"] == "Bearer t-managed")
    }

    @Test("withTenantToken: explicit tenant token is used (allowed deviation: always wins)")
    func tenantToken() async throws {
        let (c, http) = try Self.client(Self.ok)
        _ = try await c.request(.get, "/open-apis/x", options: .tenantAccessToken("t-explicit"), as: JSONValue.self)
        #expect(http.requests.last?.headers["Authorization"] == "Bearer t-explicit")
    }

    @Test("withHelpDeskCredential: base64(id:token) helpdesk header")
    func helpDesk() async throws {
        let (c, http) = try Self.client(Self.ok, helpDesk: true)
        _ = try await c.request(.get, "/open-apis/x", options: .helpDeskCredential, as: JSONValue.self)
        // Buffer.from('hd:hdt').toString('base64') === 'aGQ6aGR0'
        #expect(http.requests.last?.headers["X-Lark-Helpdesk-Authorization"] == "Bearer aGQ6aGR0")
        #expect(http.requests.last?.headers["Authorization"] == "Bearer t-managed")
    }

    @Test("options headers / query / path override generated values")
    func overrides() async throws {
        let (c, http) = try Self.client(Self.ok)
        let opts = RequestOptions(headers: ["X-Extra": "1"], query: ["a": "override", "b": "2"], path: ["id": "p 1"])
        _ = try await c.request(.get, "/open-apis/items/:id", query: ["a": "orig"] as JSONValue, body: .none, options: opts, as: JSONValue.self)
        let req = try #require(http.requests.last)
        #expect(req.headers["X-Extra"] == "1")
        let items = URLComponents(url: req.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "a" }.map(\.value) == ["override"])
        #expect(items.contains(URLQueryItem(name: "b", value: "2")))
        #expect(req.url.absoluteString.contains("/open-apis/items/p%201"))
    }

    @Test("withAll: later options win, flags are OR-ed, maps are merged")
    func withAll() {
        let merged = RequestOptions.all([
            .tenantKey("k1"), .userAccessToken("u1"), .helpDeskCredential,
            RequestOptions(tenantKey: "k2", headers: ["a": "1"]), RequestOptions(headers: ["b": "2"], timeout: 5),
        ])
        #expect(merged.tenantKey == "k2")
        #expect(merged.userAccessToken == "u1")
        #expect(merged.withHelpDeskCredential)
        #expect(merged.headers == ["a": "1", "b": "2"])
        #expect(merged.timeout == 5)
    }

    @Test("withTenantKey: ISV app requests a per-tenant token")
    func tenantKeyISV() async throws {
        let cache = DefaultLarkCache()
        _ = await cache.set(LarkCacheKey.appTicket, value: "ticket", expiresAt: nil, namespace: "cli_isv")
        let http = MockHTTPClient { req in
            switch req.url.path {
            case "/open-apis/auth/v3/app_access_token":
                return MockHTTPClient.json(["code": 0, "app_access_token": "a-isv", "expire": 7200])
            case "/open-apis/auth/v3/tenant_access_token":
                let body = try JSONValue(data: req.body!)
                #expect(body["tenant_key"]?.stringValue == "tk-1")
                #expect(body["app_access_token"]?.stringValue == "a-isv")
                return MockHTTPClient.json(["code": 0, "tenant_access_token": "t-isv", "expire": 7200])
            default:
                return MockHTTPClient.json(["code": 0, "data": [:]])
            }
        }
        let c = try LarkClient(LarkConfiguration(appId: "cli_isv", appSecret: "s", appType: .isv, logLevel: .fatal, cache: cache, httpClient: http))
        _ = try await c.request(.get, "/open-apis/x", options: .tenantKey("tk-1"), as: JSONValue.self)
        #expect(http.requests.last?.headers["Authorization"] == "Bearer t-isv")
    }

    // MARK: user-access-token.ts

    @Test("userAccessToken: initWithCode exchanges codes and caches tokens")
    func initWithCode() async throws {
        let (c, http) = try Self.client { req in
            #expect(req.url.path == "/open-apis/authen/v1/oidc/access_token")
            let body = try JSONValue(data: req.body!)
            #expect(body["grant_type"]?.stringValue == "authorization_code")
            return MockHTTPClient.json(["code": 0, "data": ["access_token": .string("u-\(body["code"]!.stringValue!)"), "refresh_token": "r-1", "expires_in": 7200]])
        }
        let info = try await c.userAccessToken.initWithCode(["alice": "c1"])
        #expect(info["alice"]?.token == "u-c1")
        #expect(try await c.userAccessToken.get("alice") == "u-c1")
        // Cached: no second exchange.
        #expect(http.requests.filter { $0.url.path.hasSuffix("oidc/access_token") }.count == 1)
        #expect(try await c.userAccessToken.get("nobody") == nil)
    }

    @Test("userAccessToken: expired token is refreshed with the refresh token")
    func refresh() async throws {
        let (c, http) = try Self.client { req in
            #expect(req.url.path == "/open-apis/authen/v1/oidc/refresh_access_token")
            let body = try JSONValue(data: req.body!)
            #expect(body["grant_type"]?.stringValue == "refresh_token")
            #expect(body["refresh_token"]?.stringValue == "r-old")
            return MockHTTPClient.json(["code": 0, "data": ["access_token": "u-new", "refresh_token": "r-new", "expires_in": 7200]])
        }
        await c.userAccessToken.update(["bob": UserTokenInfo(token: "u-old", refreshToken: "r-old", expiredTime: Date().addingTimeInterval(-1))])
        #expect(try await c.userAccessToken.get("bob") == "u-new")
        #expect(try await c.userAccessToken.get("bob") == "u-new")  // now cached and valid
        #expect(http.requests.filter { $0.url.path.hasSuffix("refresh_access_token") }.count == 1)
    }

    @Test("userAccessToken: failed refresh returns nil")
    func refreshFails() async throws {
        let (c, _) = try Self.client { _ in MockHTTPClient.json(["code": 20026, "msg": "invalid refresh token"], status: 400) }
        await c.userAccessToken.update(["eve": UserTokenInfo(token: "u", refreshToken: "bad", expiredTime: Date().addingTimeInterval(-1))])
        #expect(try await c.userAccessToken.get("eve") == nil)
    }

    @Test("userAccessToken: namespaces isolate keys")
    func namespaces() async throws {
        let (c, _) = try Self.client(Self.ok)
        let future = Date().addingTimeInterval(3600)
        await c.userAccessToken.update(["k": UserTokenInfo(token: "ns1", expiredTime: future)], namespace: "a")
        await c.userAccessToken.update(["k": UserTokenInfo(token: "ns2", expiredTime: future)], namespace: "b")
        #expect(try await c.userAccessToken.get("k", namespace: "a") == "ns1")
        #expect(try await c.userAccessToken.get("k", namespace: "b") == "ns2")
        #expect(try await c.userAccessToken.get("k") == nil)
    }
}
