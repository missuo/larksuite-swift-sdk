import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `adaptor/services/__tests__/verification-token.ts`. node runs each case against
// four HTTP adapters (default, express, koa, koa-router); Swift has one framework-agnostic adapter
// (`handleWebhook` with autoChallenge, the port of `adaptDefault`), so each case is ported once.

/// Produced with Node `crypto` by the node test's `encrypt(payload)` helper: aes-256-cbc,
/// key = sha256("encryption-fixture"), iv = 16 × 0x01, plaintext = JSON.stringify(payload) for
/// {"type":"url_verification","token":<token>,"challenge":"fixture"}.
private let encryptedChallenge: [String: String] = [
    "audit-fixture":
        "AQEBAQEBAQEBAQEBAQEBAVX/QGIgCZRdNNZtzgz9PbYt4I/C2Td47d2KrOEO5Bfxmn7GuKNkGaI5mP2iV7zirLO0CKgeK68O9EbQAm/WNCC6lEZsR/hWUaVdZWWatzhy",
    "wrong":
        "AQEBAQEBAQEBAQEBAQEBAVX/QGIgCZRdNNZtzgz9PbYt4I/C2Td47d2KrOEO5BfxaawdV2koPKJv8+ND2lbzn77lK/yd9gtbKhol96p5FTpV0ZyF8IdXFSn3mqkKLeUX",
]

@Suite struct NodeAdaptorVerificationTokenTests {
    @Test("adaptor/verification-token: default webhook adapter authenticates challenge token %#", arguments: nodeTokenCases)
    func challengeToken(token: JSONValue?) async throws {
        let handler = HandlerSpy()
        let dispatcher = EventDispatcher(verificationToken: "audit-fixture", cache: DefaultLarkCache(), logLevel: .fatal)
            .register("audit.test", handler.handler)
        var payload: JSONValue = ["type": "url_verification", "challenge": "fixture"]
        if let token { payload["token"] = token }

        let result = await dispatcher.handleWebhook(webhook(payload), autoChallenge: true)

        let valid = token == "audit-fixture"
        #expect(result.statusCode == (valid ? 200 : 403))
        #expect(try JSONValue(data: result.body) == (valid ? ["challenge": "fixture"] : ["msg": "webhook verification failed"]))
        #expect(handler.count == 0)
    }

    @Test("adaptor/verification-token: default webhook adapter preserves plaintext challenge with no configured token")
    func plaintextChallengeWithoutToken() async throws {
        let dispatcher = EventDispatcher(cache: DefaultLarkCache(), logLevel: .fatal)
        let result = await dispatcher.handleWebhook(webhook(["type": "url_verification", "token": "", "challenge": "fixture"]), autoChallenge: true)
        #expect(result.statusCode == 200)
        #expect(try JSONValue(data: result.body) == ["challenge": "fixture"])
    }

    @Test("adaptor/verification-token: default webhook adapter authenticates decrypted challenge token %s", arguments: ["audit-fixture", "wrong"])
    func decryptedChallengeToken(token: String) async throws {
        let dispatcher = EventDispatcher(
            encryptKey: "encryption-fixture", verificationToken: "audit-fixture", cache: DefaultLarkCache(), logLevel: .fatal)
        let result = await dispatcher.handleWebhook(webhook(["encrypt": .string(encryptedChallenge[token]!)]), autoChallenge: true)
        #expect(result.statusCode == (token == "audit-fixture" ? 200 : 403))
    }

    @Test("adaptor/verification-token: default webhook adapter rejects forged ordinary events before handlers")
    func forgedEventsRejected() async throws {
        let handler = HandlerSpy()
        let dispatcher = EventDispatcher(verificationToken: "audit-fixture", cache: DefaultLarkCache(), logLevel: .fatal)
            .register("audit.test", handler.handler)
        _ = await dispatcher.handleWebhook(
            webhook(["schema": "2.0", "header": ["event_type": "audit.test", "token": "wrong"], "event": [:]]), autoChallenge: true)
        #expect(handler.count == 0)
    }

    @Test("adaptor/verification-token: non-challenge payloads still flow through regular validation")
    func nonChallengePayload() throws {
        #expect(try WebhookAdapter.generateChallenge(body: [:], encryptKey: "").isChallenge == false)
    }
}
