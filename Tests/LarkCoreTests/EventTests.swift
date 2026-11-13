import Foundation
import Testing
@testable import LarkCore

@Suite struct EventTests {
    // Produced by Node's crypto (aes-256-cbc, key = sha256("test-encrypt-key"), iv = 0x07 * 16).
    let encrypted =
        "BwcHBwcHBwcHBwcHBwcHB7fbpaXTa3Jt7et/RcpohYcs13LWqK6rueFnXQtYjlbBUkTTtUrVFuhfw38hEuAA59M2ViXsLDCL2pJ8kGG7qFT9kImT7hEpYGY/mdaRlCS3kVudJu2CFdfXqC0b05oqnLwwSo+Nf3ODEZWwErjQpUvC934rvuzZKDg9R/qjVmcUiWUPXq95VlZY9My2pzTJTSh7ANT4MHlD3NhF3DohtBCWoWjBTQVoQSdXA6OsBJwJ"
    let plain =
        #"{"schema":"2.0","header":{"event_type":"im.message.receive_v1","token":"vt","event_id":"e1"},"event":{"message":{"message_id":"om_1","content":"{\"text\":\"hi\"}"}}}"#
    let signature = "b258b3c88b18bd3e7fa505ae33618f7b83606ce6c1786e5954211cde85395d27"

    @Test func aesMatchesNode() throws {
        let cipher = AESCipher("test-encrypt-key")
        #expect(try cipher.decrypt(encrypted) == plain)
        let iv = Data(repeating: 7, count: 16)
        #expect(try cipher.encrypt(plain, iv: iv) == encrypted)
    }

    @Test func v2EventIsFlattened() throws {
        let e = LarkEvent(body: try JSONValue(jsonString: plain))
        #expect(e.type == "im.message.receive_v1")
        #expect(e.schema == "2.0")
        #expect(e.eventId == "e1")
        #expect(e.payload["message"]?["message_id"]?.stringValue == "om_1")
        #expect(e.payload["event_type"]?.stringValue == "im.message.receive_v1")
        #expect(e.payload["header"] == nil)
    }

    @Test func v1EventIsFlattened() throws {
        let e = LarkEvent(body: try JSONValue(jsonString: #"{"uuid":"u","token":"t","ts":"1","type":"event_callback","event":{"type":"app_ticket","app_id":"cli_1","app_ticket":"tk"}}"#))
        #expect(e.type == "app_ticket")
        #expect(e.schema == nil)
        #expect(e.payload["app_ticket"]?.stringValue == "tk")
        #expect(e.payload["uuid"]?.stringValue == "u")
    }

    @Test func encryptedWebhookIsVerifiedAndDispatched() async throws {
        let body = Data(#"{"encrypt":"\#(encrypted)"}"#.utf8)
        let dispatcher = EventDispatcher(encryptKey: "test-encrypt-key", logLevel: .error)
            .register("im.message.receive_v1") { event in
                ["got": .string(event.payload["message"]?["message_id"]?.stringValue ?? "")] as JSONValue
            }
        let good = WebhookRequest(
            headers: ["X-Lark-Request-Timestamp": "1700000000", "X-Lark-Request-Nonce": "nonce1", "X-Lark-Signature": signature],
            body: body)
        let result = try await dispatcher.invoke(good)
        #expect(result?["got"]?.stringValue == "om_1")

        let bad = WebhookRequest(
            headers: ["X-Lark-Request-Timestamp": "1700000000", "X-Lark-Request-Nonce": "nonce1", "X-Lark-Signature": "00"],
            body: body)
        #expect(try await dispatcher.invoke(bad) == nil)
        let resp = await dispatcher.handleWebhook(bad)
        #expect(resp.statusCode == 200)
        #expect(String(decoding: resp.body, as: UTF8.self) == "null")
    }

    @Test func verificationTokenAndChallenge() async throws {
        let dispatcher = EventDispatcher(verificationToken: "vt", logLevel: .error)
        let challenge = WebhookRequest(headers: [:], body: Data(#"{"type":"url_verification","challenge":"abc","token":"vt"}"#.utf8))
        let resp = await dispatcher.handleWebhook(challenge)
        #expect(resp.statusCode == 200)
        #expect(try JSONValue(data: resp.body)["challenge"]?.stringValue == "abc")

        let wrong = WebhookRequest(headers: [:], body: Data(#"{"type":"url_verification","challenge":"abc","token":"nope"}"#.utf8))
        #expect(await dispatcher.handleWebhook(wrong).statusCode == 403)
    }

    @Test func appTicketIsCached() async throws {
        let cache = DefaultLarkCache()
        let dispatcher = EventDispatcher(cache: cache, logLevel: .error)
        _ = try await dispatcher.dispatch(json: try JSONValue(jsonString: #"{"uuid":"u","event":{"type":"app_ticket","app_id":"cli_x","app_ticket":"T1"}}"#))
        #expect(await cache.get(LarkCacheKey.appTicket, namespace: "cli_x") == "T1")
    }

    struct MessageEvent: Decodable, Sendable {
        struct Message: Decodable, Sendable { var message_id: String }
        var message: Message
    }

    @Test func typedHandlerAndCardResponse() async throws {
        let dispatcher = EventDispatcher(logLevel: .error)
            .register(LarkEventKey<MessageEvent>("im.message.receive_v1")) { msg, _ in
                CardActionResponse(toast: .init(type: .success, content: msg.message.message_id))
            }
        let out = try await dispatcher.dispatch(json: try JSONValue(jsonString: plain))
        #expect(out?["toast"]?["type"]?.stringValue == "success")
        #expect(out?["toast"]?["content"]?.stringValue == "om_1")
    }

    @Test func legacyCardSignature() async throws {
        let body = #"{"open_id":"ou_1","action":{"value":{"k":"v"}}}"#
        let sig = LarkDigest.sha1Hex("1" + "n" + "vt" + body)
        let handler = CardActionHandler(verificationToken: "vt", logLevel: .error) { event in
            ["ok": .string(event.payload["open_id"]?.stringValue ?? "")] as JSONValue
        }
        let req = WebhookRequest(
            headers: ["x-lark-request-timestamp": "1", "x-lark-request-nonce": "n", "x-lark-signature": sig], body: Data(body.utf8))
        #expect(try await handler.invoke(req)?["ok"]?.stringValue == "ou_1")
        let bad = WebhookRequest(
            headers: ["x-lark-request-timestamp": "1", "x-lark-request-nonce": "n", "x-lark-signature": "x"], body: Data(body.utf8))
        #expect(try await handler.invoke(bad) == nil)
    }
}
