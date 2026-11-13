import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `client/__tests__/client-assertion.ts`: constants, OAuth base-URL / aud
// resolution, proxy-URL construction and the error types (`LarkError.clientAssertion` /
// `LarkError.accessToken` are the Swift counterparts of ClientAssertionError / AccessTokenError).

@Suite struct NodeClientAssertionTests {
    // MARK: constants

    @Test("client-assertion: OAuth URI + grant / assertion types are RFC-exact")
    func constants() {
        #expect(LarkOAuth.tokenURI == "/oauth/v3/token")
        #expect(LarkOAuth.grantTypeJWTBearer == "urn:ietf:params:oauth:grant-type:jwt-bearer")
        #expect(LarkOAuth.clientAssertionTypeJWTBearer == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
        #expect(LarkOAuth.grantTypeAuthorizationCode == "authorization_code")
        #expect(LarkOAuth.grantTypeRefreshToken == "refresh_token")
    }

    @Test("client-assertion: X-Target-Service header name is exact")
    func targetServiceHeader() {
        #expect(LarkOAuth.targetServiceHeader == "X-Target-Service")
    }

    @Test("client-assertion: error classes carry the documented codes (7100–7104)")
    func errorCodes() {
        #expect(ClientAssertionErrorCode.providerNotConfigured == 7100)
        #expect(ClientAssertionErrorCode.tokenEmpty == 7101)
        #expect(ClientAssertionErrorCode.retrieveFailed == 7102)
        #expect(ClientAssertionErrorCode.modeNotSupported == 7103)
        #expect(ClientAssertionErrorCode.appSecretAndClientAssertionEmpty == 7104)
        for code in 7100...7104 {
            guard case .clientAssertion(let c, _) = LarkError.clientAssertion(code: code, msg: "m") else {
                Issue.record("wrong case")
                continue
            }
            #expect(c == code)
        }
    }

    // MARK: resolveOauthBaseUrl

    @Test("client-assertion: explicit oauthBaseUrl is normalized (adds https, strips trailing /)")
    func explicitBaseURL() throws {
        #expect(try LarkOAuth.resolveBaseURL(oauthBaseURL: "accounts.x.cn/", domain: "https://open.feishu.cn") == "https://accounts.x.cn")
    }

    @Test("client-assertion: official feishu domain derives accounts.feishu.cn")
    func feishuDomain() throws {
        #expect(try LarkOAuth.resolveBaseURL(oauthBaseURL: nil, domain: "https://open.feishu.cn") == "https://accounts.feishu.cn")
    }

    @Test("client-assertion: official larksuite domain derives accounts.larksuite.com")
    func larkDomain() throws {
        #expect(try LarkOAuth.resolveBaseURL(oauthBaseURL: nil, domain: "https://open.larksuite.com") == "https://accounts.larksuite.com")
    }

    @Test("client-assertion: custom domain without oauthBaseUrl throws")
    func customDomainThrows() {
        #expect(throws: (any Error).self) { try LarkOAuth.resolveBaseURL(oauthBaseURL: nil, domain: "https://open.example.com") }
    }

    @Test("client-assertion: official mapping cannot be bypassed by a non-official domain")
    func mappingNotBypassed() {
        #expect(throws: (any Error).self) {
            try LarkOAuth.resolveBaseURL(oauthBaseURL: nil, domain: "https://evil.accounts.feishu.cn.attacker.com")
        }
    }

    // MARK: extractAudFromUrl

    @Test("client-assertion: returns host from a full url")
    func audFromURL() throws {
        #expect(try LarkOAuth.extractAud(fromURL: "https://accounts.feishu.cn/oauth/v3/token") == "accounts.feishu.cn")
    }

    @Test("client-assertion: schemeless input is auto-prefixed then parsed")
    func audSchemeless() throws {
        #expect(try LarkOAuth.extractAud(fromURL: "accounts.feishu.cn") == "accounts.feishu.cn")
    }

    @Test("client-assertion: host with explicit port keeps the port")
    func audPort() throws {
        #expect(try LarkOAuth.extractAud(fromURL: "host:8443") == "host:8443")
    }

    @Test("client-assertion: unparseable input throws")
    func audUnparseable() {
        #expect(throws: (any Error).self) { try LarkOAuth.extractAud(fromURL: "http://") }
    }

    // MARK: buildProxyUrl (happy path)

    @Test("client-assertion: schemeless targetService + prefix + path → normalized https url")
    func proxyURL() throws {
        #expect(
            try LarkOAuth.buildProxyURL(TargetInfo(targetService: "proxy.example.org", targetPrefix: "/proxy/Lark"), apiPath: "/oauth/v3/token")
                == "https://proxy.example.org/proxy/Lark/oauth/v3/token")
    }

    @Test("client-assertion: adjacent slashes between prefix and path are collapsed")
    func proxyURLCollapsesSlashes() throws {
        #expect(
            try LarkOAuth.buildProxyURL(TargetInfo(targetService: "proxy.example.org", targetPrefix: "/proxy/Lark/"), apiPath: "/oauth/v3/token")
                == "https://proxy.example.org/proxy/Lark/oauth/v3/token")
    }

    // MARK: buildProxyUrl (security)

    @Test("client-assertion: plaintext http:// targetService throws (no cleartext exfiltration)")
    func proxyRejectsHTTP() {
        #expect(throws: (any Error).self) {
            try LarkOAuth.buildProxyURL(TargetInfo(targetService: "http://evil.org", targetPrefix: "/proxy/Lark"), apiPath: "/oauth/v3/token")
        }
    }

    @Test("client-assertion: targetService with userinfo (@) throws")
    func proxyRejectsUserinfo() {
        #expect(throws: (any Error).self) {
            try LarkOAuth.buildProxyURL(TargetInfo(targetService: "https://user:pass@evil.org"), apiPath: "/oauth/v3/token")
        }
    }

    @Test("client-assertion: unparseable targetService throws")
    func proxyRejectsUnparseable() {
        #expect(throws: (any Error).self) {
            try LarkOAuth.buildProxyURL(TargetInfo(targetService: ":::"), apiPath: "/oauth/v3/token")
        }
    }

    // MARK: error classes

    @Test("client-assertion: AccessTokenError preserves the structured fields and message")
    func accessTokenError() {
        let err = LarkError.accessToken(statusCode: 400, code: 0, error: "invalid", errorDescription: "bad request")
        guard case .accessToken(let status, let code, let error, let desc) = err else {
            Issue.record("wrong case")
            return
        }
        #expect(status == 400)
        #expect(code == 0)
        #expect(error == "invalid")
        #expect(desc == "bad request")
        #expect(err.description.contains("bad request"))
    }

    @Test("client-assertion: ClientAssertionError preserves code and msg")
    func clientAssertionError() {
        let err = LarkError.clientAssertion(code: 7102, msg: "token empty")
        guard case .clientAssertion(let code, let msg) = err else {
            Issue.record("wrong case")
            return
        }
        #expect(code == 7102)
        #expect(msg == "token empty")
        #expect(err.description.contains("token empty"))
    }

    @Test("client-assertion: neither error carries a config / request / response reference")
    func errorsCarryNoRequest() {
        // The Swift errors are plain enum payloads: only the documented fields exist.
        let a = LarkError.accessToken(statusCode: 400, code: 0, error: "e", errorDescription: "d")
        let c = LarkError.clientAssertion(code: 7102, msg: "m")
        func labels(_ e: LarkError) -> [String] {
            guard let payload = Mirror(reflecting: e).children.first?.value else { return [] }
            return Mirror(reflecting: payload).children.compactMap(\.label)
        }
        #expect(labels(a) == ["statusCode", "code", "error", "errorDescription"])
        #expect(labels(c) == ["code", "msg"])
        for e in [a, c] {
            for forbidden in ["config", "request", "response"] { #expect(!labels(e).contains(forbidden)) }
        }
    }
}
