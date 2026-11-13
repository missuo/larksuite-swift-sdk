import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `client/__tests__/access-token.ts` (UAT service, `client.accessToken`).
// Swift transports return non-2xx responses instead of rejecting (axios), so the "axios
// rejection" case is a 400 response. Only placeholder fake values.

private let appId = "cli_ABCDEF0123456789"
private let fakeAssertion = "aaa.bbb.ccc"

private let successBody: JSONValue = [
    "access_token": "fake-uat-1",
    "token_type": "Bearer",
    "expires_in": 7200,
    "refresh_token": "fake-rt-1",
    "refresh_token_expires_in": 86400,
    "scope": "a b",
]

private func makeAccessToken(
    provider: (any ClientAssertionProvider)? = nil, appSecret: String = "", http: MockHTTPClient
) -> AccessTokenService {
    let config = LarkConfiguration(appId: appId, appSecret: appSecret, clientAssertionProvider: provider, logLevel: .fatal, httpClient: http)
    return AccessTokenService(config: config, baseURL: "https://open.feishu.cn", logger: LoggerProxy(level: .fatal), userAgent: "ua")
}

private func replying(_ body: JSONValue, status: Int = 200) -> MockHTTPClient {
    MockHTTPClient { _ in MockHTTPClient.json(body, status: status) }
}

private func lastBody(_ http: MockHTTPClient) throws -> JSONValue {
    try JSONValue(data: try #require(http.requests.last?.body))
}

/// Shape of an axios transport error: a message plus the request config holding the cleartext body.
private struct TransportError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    let configData: String
    var errorDescription: String? { message }
    var description: String { message }
}

@Suite struct NodeAccessTokenTests {
    // MARK: grant body construction

    @Test("access-token: authorization_code body carries code/redirect_uri/code_verifier/scope/client_id, undefined dropped")
    func authorizationCodeBody() async throws {
        let http = replying(successBody)
        let at = makeAccessToken(appSecret: "fake-secret-1", http: http)

        _ = try await at.retrieve(
            byAuthorizationCode: .init(code: "auth-code-1", redirectURI: "https://app.example/cb", codeVerifier: "verifier-1", scope: "a b"))

        let body = try lastBody(http)
        #expect(body["grant_type"]?.stringValue == "authorization_code")
        #expect(body["code"]?.stringValue == "auth-code-1")
        #expect(body["redirect_uri"]?.stringValue == "https://app.example/cb")
        #expect(body["code_verifier"]?.stringValue == "verifier-1")
        #expect(body["scope"]?.stringValue == "a b")
        #expect(body["client_id"]?.stringValue == appId)
    }

    @Test("access-token: omitted optional fields are not present in the body")
    func omittedFields() async throws {
        let http = replying(successBody)
        let at = makeAccessToken(appSecret: "fake-secret-1", http: http)

        _ = try await at.retrieve(byAuthorizationCode: .init(code: "auth-code-1"))

        let body = try lastBody(http)
        #expect(body["redirect_uri"] == nil)
        #expect(body["code_verifier"] == nil)
        #expect(body["scope"] == nil)
    }

    @Test("access-token: refresh body carries grant_type=refresh_token + refresh_token + client_id")
    func refreshBody() async throws {
        let http = replying(successBody)
        let at = makeAccessToken(appSecret: "fake-secret-1", http: http)

        _ = try await at.refresh(.init(refreshToken: "fake-rt-1", scope: "a"))

        let body = try lastBody(http)
        #expect(body["grant_type"]?.stringValue == "refresh_token")
        #expect(body["refresh_token"]?.stringValue == "fake-rt-1")
        #expect(body["client_id"]?.stringValue == appId)
        #expect(body["scope"]?.stringValue == "a")
    }

    // MARK: credential selection

    @Test("access-token: provider mode sends client_assertion_type + client_assertion")
    func providerMode() async throws {
        let http = replying(successBody)
        let at = makeAccessToken(provider: RecordingAssertionProvider(), http: http)

        _ = try await at.retrieve(byAuthorizationCode: .init(code: "auth-code-1"))

        let body = try lastBody(http)
        #expect(body["client_assertion_type"]?.stringValue == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
        #expect(body["client_assertion"]?.stringValue == fakeAssertion)
        #expect(body["client_secret"] == nil)
    }

    @Test("access-token: secret-only mode sends client_secret")
    func secretMode() async throws {
        let http = replying(successBody)
        let at = makeAccessToken(appSecret: "fake-secret-1", http: http)

        _ = try await at.refresh(.init(refreshToken: "fake-rt-1"))

        let body = try lastBody(http)
        #expect(body["client_secret"]?.stringValue == "fake-secret-1")
        #expect(body["client_assertion"] == nil)
    }

    @Test("access-token: neither credential → ClientAssertionError 7104")
    func neitherCredential() async throws {
        let at = makeAccessToken(http: replying(successBody))
        for _ in 0..<2 {
            let error = await #expect(throws: LarkError.self) { try await at.retrieve(byAuthorizationCode: .init(code: "auth-code-1")) }
            guard case .clientAssertion(let code, _)? = error else {
                Issue.record("unexpected \(String(describing: error))")
                return
            }
            #expect(code == 7104)
        }
    }

    // MARK: error translation + success mapping

    @Test("access-token: axios rejection (non-200) → structured AccessTokenError")
    func non200() async throws {
        let http = replying(["code": 0, "error": "invalid_grant", "error_description": "x"], status: 400)
        let at = makeAccessToken(appSecret: "fake-secret-1", http: http)

        let error = await #expect(throws: LarkError.self) { try await at.refresh(.init(refreshToken: "fake-rt-1")) }
        guard case .accessToken(let status, _, let err, let desc)? = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(status == 400)
        #expect(err == "invalid_grant")
        #expect(desc == "x")
    }

    @Test("access-token: network error (no response) → self-safe AccessTokenError, no credential leak")
    func networkErrorNoLeak() async throws {
        let http = MockHTTPClient { _ in
            throw TransportError(
                message: "connect ECONNREFUSED 127.0.0.1:443",
                configData: #"{"client_secret":"fake-secret-1","refresh_token":"fake-rt-1"}"#)
        }
        let at = makeAccessToken(appSecret: "fake-secret-1", http: http)

        let error = await #expect(throws: LarkError.self) { try await at.refresh(.init(refreshToken: "fake-rt-1")) }
        let thrown = try #require(error)
        guard case .accessToken = thrown else {
            Issue.record("unexpected \(thrown)")
            return
        }
        var dumped = ""
        dump(thrown, to: &dumped)
        for text in [String(describing: thrown), String(reflecting: thrown), thrown.localizedDescription, dumped] {
            #expect(!text.contains("fake-secret-1"))
            #expect(!text.contains("fake-rt-1"))
        }
    }

    @Test("access-token: 2xx body containing error still throws AccessTokenError")
    func errorIn2xx() async throws {
        let at = makeAccessToken(appSecret: "fake-secret-1", http: replying(["error": "invalid_grant", "error_description": "x"]))
        let error = await #expect(throws: LarkError.self) { try await at.refresh(.init(refreshToken: "fake-rt-1")) }
        guard case .accessToken? = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
    }

    @Test("access-token: body missing access_token throws AccessTokenError")
    func missingAccessToken() async throws {
        let at = makeAccessToken(appSecret: "fake-secret-1", http: replying(["token_type": "Bearer", "expires_in": 1]))
        let error = await #expect(throws: LarkError.self) { try await at.refresh(.init(refreshToken: "fake-rt-1")) }
        guard case .accessToken? = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
    }

    @Test("access-token: success maps to camelCase fields")
    func successMapping() async throws {
        let at = makeAccessToken(appSecret: "fake-secret-1", http: replying(successBody))
        let out = try await at.retrieve(byAuthorizationCode: .init(code: "auth-code-1"))
        #expect(
            out
                == AccessTokenResponse(
                    accessToken: "fake-uat-1", tokenType: "Bearer", expiresIn: 7200, refreshToken: "fake-rt-1",
                    refreshTokenExpiresIn: 86400, scope: "a b"))
    }

    // MARK: proxy + custom headers

    @Test("access-token: targetInfo proxies url + adds X-Target-Service, caller headers preserved")
    func proxyAndHeaders() async throws {
        let http = replying(successBody)
        let provider = RecordingAssertionProvider(target: TargetInfo(targetService: "proxy.example.org", targetPrefix: "/proxy/Lark"))
        let at = makeAccessToken(provider: provider, http: http)

        _ = try await at.retrieve(byAuthorizationCode: .init(code: "auth-code-1", headers: ["X-Custom": "1"]))

        let req = try #require(http.requests.last)
        #expect(req.url.absoluteString == "https://proxy.example.org/proxy/Lark/oauth/v3/token")
        #expect(req.headers["X-Target-Service"] == "accounts.feishu.cn")
        #expect(req.headers["X-Custom"] == "1")
    }
}
