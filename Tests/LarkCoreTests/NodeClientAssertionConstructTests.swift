import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `client/__tests__/client-assertion-construct.ts`: construct-time credential
// validation and token injection priority. Only placeholder fake values.

private let appId = "cli_ABCDEF0123456789"

private func code(of error: (any Error)?) -> Int? {
    guard case .clientAssertion(let code, _)? = error as? LarkError else { return nil }
    return code
}

@Suite struct NodeClientAssertionConstructTests {
    let http = MockHTTPClient { req in throw TestError("unexpected request to \(req.url)") }

    @Test("client-assertion-construct: appId only (no secret, no provider) → throws ClientAssertionError 7104")
    func appIdOnly() {
        let error = #expect(throws: LarkError.self) {
            try LarkClient(LarkConfiguration(appId: appId, logLevel: .fatal, httpClient: http))
        }
        #expect(code(of: error) == 7104)
    }

    @Test("client-assertion-construct: provider + ISV appType → throws ClientAssertionError 7100")
    func providerWithISV() {
        let error = #expect(throws: LarkError.self) {
            try LarkClient(
                LarkConfiguration(
                    appId: appId, clientAssertionProvider: RecordingAssertionProvider(), appType: .isv, logLevel: .fatal, httpClient: http))
        }
        #expect(code(of: error) == 7100)
    }

    @Test("client-assertion-construct: provider-only self-build does not throw")
    func providerOnly() {
        #expect(throws: Never.self) {
            try LarkClient(LarkConfiguration(appId: appId, clientAssertionProvider: RecordingAssertionProvider(), logLevel: .fatal, httpClient: http))
        }
    }

    @Test("client-assertion-construct: secret-only does not throw (back-compat)")
    func secretOnly() {
        #expect(throws: Never.self) {
            try LarkClient(LarkConfiguration(appId: appId, appSecret: "fake-secret-1", logLevel: .fatal, httpClient: http))
        }
    }

    @Test("client-assertion-construct: manual user token wins; tokenManager is not consulted")
    func manualUserTokenWins() async throws {
        let provider = RecordingAssertionProvider()
        let client = try LarkClient(
            LarkConfiguration(appId: appId, clientAssertionProvider: provider, logLevel: .fatal, cache: DefaultLarkCache(), httpClient: http))

        let headers = try await client.prepareHeaders(.userAccessToken("manual-uat-1"))

        #expect(headers["Authorization"] == "Bearer manual-uat-1")
        // The token manager would have called the provider and the OAuth endpoint.
        #expect(provider.auds.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test("client-assertion-construct: without a manual token, tenant token is injected")
    func tenantTokenInjected() async throws {
        let oauth = MockHTTPClient { _ in MockHTTPClient.json(["access_token": "fake-tat-1", "expires_in": 7200]) }
        let client = try LarkClient(
            LarkConfiguration(
                appId: appId, clientAssertionProvider: RecordingAssertionProvider(), logLevel: .fatal, cache: DefaultLarkCache(),
                httpClient: oauth))

        let headers = try await client.prepareHeaders(.none)
        #expect(headers["Authorization"] == "Bearer fake-tat-1")
    }
}
