import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `dispatcher/__tests__/verification-token.ts`.
// `nil` stands for node's MISSING symbol (no token field at all).

/// The token values node iterates over: 'audit-fixture', 'wrong', MISSING, null, '', 123, {}, [].
let nodeTokenCases: [JSONValue?] = ["audit-fixture", "wrong", nil, .null, "", 123, .object([:]), .array([])]

/// `eventOf(schema, token)` from the node test.
func nodeEventOf(_ schema: String, token: JSONValue?, eventType: String = "audit.test") -> JSONValue {
    if schema == "v1" {
        var payload: JSONValue = ["uuid": "audit-id", "type": "event_callback", "event": ["type": .string(eventType)]]
        if let token { payload["token"] = token }
        return payload
    }
    var header: JSONValue = ["event_type": .string(eventType)]
    if let token { header["token"] = token }
    return ["schema": "2.0", "header": header, "event": [:]]
}

func webhook(_ body: JSONValue, headers: [String: String] = [:]) -> WebhookRequest {
    WebhookRequest(headers: headers, body: Data(body.jsonString().utf8))
}

/// Produced by node-sdk's test helper with Node `crypto`: aes-256-cbc, key = sha256("encryption-fixture"),
/// iv = 16 × 0x01, plaintext = JSON.stringify(eventOf('v2', MISSING)); signature =
/// sha256("timestampnonceencryption-fixture" + JSON.stringify({ encrypt })).
enum NodeVectors {
    static let missingTokenEncrypted =
        #"{"encrypt":"AQEBAQEBAQEBAQEBAQEBAdhJ6Gza8IS6D+EkF/wm65ge/9vi+bsc37R5v83G227xIBZ2zQb9DG+zosy1m6xsKh4ZcTHQAcB1Csgv6EF5qg2GKiWZTii7CiQzRo8K1/0I"}"#
    static let missingTokenSignature = "e2e03a9fe106ac586866cc8129083f1f7699eb3d74e89b136ced7b5a13d3d842"
}

@Suite struct NodeDispatcherVerificationTokenTests {
    @Test("dispatcher/verification-token: %s authenticates before dispatch", arguments: ["v1", "v2"])
    func authenticatesBeforeDispatch(schema: String) async throws {
        for token in nodeTokenCases {
            let handler = HandlerSpy()
            let dispatcher = EventDispatcher(verificationToken: "audit-fixture", cache: DefaultLarkCache(), logLevel: .fatal)
                .register("audit.test", handler.handler)
            _ = try await dispatcher.invoke(webhook(nodeEventOf(schema, token: token)))
            #expect(handler.count == (token == "audit-fixture" ? 1 : 0), "token \(String(describing: token))")
        }
        // isVerificationTokenValid never coerces: a numeric token does not match a configured "123".
        let handler = HandlerSpy()
        let dispatcher = EventDispatcher(verificationToken: "123", cache: DefaultLarkCache(), logLevel: .fatal)
            .register("audit.test", handler.handler)
        _ = try await dispatcher.invoke(webhook(nodeEventOf(schema, token: 123)))
        _ = try await dispatcher.invoke(webhook(nodeEventOf(schema, token: "123")))
        #expect(handler.count == 1)
    }

    @Test("dispatcher/verification-token: %s preserves credential-free dispatch", arguments: ["v1", "v2"])
    func credentialFreeDispatch(schema: String) async throws {
        let handler = HandlerSpy()
        let dispatcher = EventDispatcher(cache: DefaultLarkCache(), logLevel: .fatal).register("audit.test", handler.handler)
        for token: JSONValue? in ["", "wrong", nil, .null] {
            _ = try await dispatcher.invoke(webhook(nodeEventOf(schema, token: token)))
        }
        #expect(handler.count == 4)
    }

    @Test("dispatcher/verification-token: trusted websocket dispatch still works without credentials")
    func trustedWebSocketDispatch() async throws {
        let handler = HandlerSpy()
        let dispatcher = EventDispatcher(cache: DefaultLarkCache(), logLevel: .fatal).register("audit.test", handler.handler)
        _ = try await dispatcher.invoke(webhook(nodeEventOf("v2", token: nil)), needCheck: false)
        #expect(handler.count == 1)
    }

    @Test("dispatcher/verification-token: v2 events cannot fall back to a top-level token")
    func noTopLevelFallback() async throws {
        let handler = HandlerSpy()
        let dispatcher = EventDispatcher(verificationToken: "audit-fixture", cache: DefaultLarkCache(), logLevel: .fatal)
            .register("audit.test", handler.handler)
        _ = try await dispatcher.invoke(
            webhook(["schema": "2.0", "token": "audit-fixture", "header": ["event_type": "audit.test"], "event": [:]]))
        #expect(handler.count == 0)
    }

    @Test("dispatcher/verification-token: encrypted webhook retains signature validation: %s", arguments: [true, false])
    func encryptedSignature(valid: Bool) async throws {
        let handler = HandlerSpy()
        let dispatcher = EventDispatcher(encryptKey: "encryption-fixture", cache: DefaultLarkCache(), logLevel: .fatal)
            .register("audit.test", handler.handler)
        let request = WebhookRequest(
            headers: [
                "x-lark-request-timestamp": "timestamp",
                "x-lark-request-nonce": "nonce",
                "x-lark-signature": valid ? NodeVectors.missingTokenSignature : "wrong",
            ],
            body: Data(NodeVectors.missingTokenEncrypted.utf8))
        _ = try await dispatcher.invoke(request)
        #expect(handler.count == (valid ? 1 : 0))
    }

    @Test("dispatcher/verification-token: v2 card callback validates token %#", arguments: ["audit-fixture", "wrong", nil] as [String?])
    func cardCallbackToken(token: String?) async throws {
        let handler = HandlerSpy(returning: [:])
        let card = CardActionHandler(verificationToken: "audit-fixture", cache: DefaultLarkCache(), logLevel: .fatal, handler: handler.handler)
        let payload = nodeEventOf("v2", token: token.map { .string($0) }, eventType: "card.action.trigger")
        _ = try await card.invoke(webhook(payload))
        #expect(handler.count == (token == "audit-fixture" ? 1 : 0))
    }
}
