import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `ws-client/__tests__/callbacks.ts` (state-transition callbacks).
// The three `WSClient.safeInvoke` cases (no-op on undefined, argument forwarding, swallowing a
// throwing callback) test a private helper whose job the Swift type system does: callbacks are
// optional non-throwing `@Sendable` closures, so they cannot throw into the state machine.

@Suite struct NodeWSCallbacksTests {
    @Test("callbacks: hasEverConnected starts false")
    func hasEverConnectedStartsFalse() async throws {
        let client = try WSClient(.init(appId: "x", appSecret: "y", logLevel: .fatal, httpClient: ControlledHTTPClient()))
        #expect(await client.testState.hasEverConnected == false)
    }

    @Test("callbacks: accepts callback fields without error")
    func acceptsCallbacks() throws {
        let fired = Box<[String]>([])
        let client = try WSClient(
            .init(
                appId: "x", appSecret: "y", logLevel: .fatal, httpClient: ControlledHTTPClient(),
                onReady: { fired.mutate { $0.append("ready") } },
                onError: { _ in fired.mutate { $0.append("error") } },
                onReconnecting: { fired.mutate { $0.append("reconnecting") } },
                onReconnected: { fired.mutate { $0.append("reconnected") } }))
        // Fields are stored as given (closures are not comparable: invoke them instead).
        client.options.onReady?()
        client.options.onError?(TestError("e"))
        client.options.onReconnecting?()
        client.options.onReconnected?()
        #expect(fired.value == ["ready", "error", "reconnecting", "reconnected"])
    }

    @Test("callbacks: tolerates missing (optional) callbacks")
    func toleratesMissingCallbacks() {
        #expect(throws: Never.self) { try WSClient(.init(appId: "x", appSecret: "y", logLevel: .fatal)) }
    }
}
