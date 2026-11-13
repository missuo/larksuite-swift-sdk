import Foundation
import Testing
@testable import LarkCore
import LarkContact
import LarkDocx
import LarkIM

/// Compile-checks the code shown in README.md (never executed against a server).
@Suite struct ReadmeSnippetTests {
    func apiSnippets(client: LarkClient, cardJSON: JSONValue, newCardJSON: JSONValue) async throws {
        let sent = try await client.im.v1.message.create(
            params: .init(receiveIdType: .chatId),
            body: .init(receiveId: "oc_xxx", msgType: "text", content: MessageContent.text("hello")))
        print(sent.data?.messageId ?? "", sent.logId ?? "")
        _ = try await client.im.v1.message.create(params: .init(receiveIdType: .openId), body: .card(to: "ou_xxx", cardJSON))
        _ = try await client.im.v1.message.reply(messageId: "om_xxx", body: .text("ok", replyInThread: true))
        let user = try await client.contact.v3.user.get(userId: "ou_xxx", params: .init(userIdType: .openId))
        print(user.data?.user?.name ?? "")
        for try await page in client.im.v1.chatMembers.getWithIterator(chatId: "oc_xxx", params: .init(pageSize: 100)) {
            for member in page.items ?? [] { print(member.memberId ?? "") }
        }
        let image = try await client.im.v1.image.create(
            body: .init(imageType: "message", image: try LarkFile(path: "/tmp/photo.png")))
        print(image.data?.imageKey ?? "")
        let file = try await client.im.v1.messageResource.get(messageId: "om_xxx", fileKey: "file_xxx", params: .init(type: "file"))
        try file.writeFile("/tmp/download.bin")
        _ = try await client.docx.v1.document.get(documentId: "doc_xxx", options: .userAccessToken("u-xxx"))
        _ = try await client.im.v1.chat.list(options: .tenantKey("tenant_xxx"))
        _ = try await client.im.v1.chat.list(options: RequestOptions(headers: ["X-Request-Id": "1"], timeout: 10))
        do {
            _ = try await client.im.v1.message.create(params: .init(receiveIdType: .chatId), body: .text(to: "oc_x", "hi"))
        } catch let LarkError.api(error) {
            print(error.code, error.msg, error.logId ?? "")
        } catch {
            print(error)
        }
        let info = try await client.request(.get, "/open-apis/bot/v3/info", as: JSONValue.self)
        _ = info.json?["bot"]?["open_id"]?.stringValue
        _ = try await client.accessToken.retrieve(byAuthorizationCode: .init(code: "c"))
        _ = try await client.accessToken.refresh(.init(refreshToken: "r"))
    }

    @Test func configurationAndEventSnippets() async throws {
        let client = try LarkClient(LarkConfiguration(
            appId: "cli_xxx", appSecret: "xxx", domain: .feishu, appType: .selfBuild, logLevel: .fatal,
            logger: ConsoleLarkLogger(), cache: DefaultLarkCache.shared, httpClient: URLSessionHTTPClient()))
        #expect(client.baseURL == "https://open.feishu.cn")
        let newCardJSON: JSONValue = ["schema": "2.0"]
        let dispatcher = EventDispatcher(encryptKey: "k", verificationToken: "t", logLevel: .fatal)
            .register(.contactUserCreatedV3) { event, _ in print(event.object?.name ?? ""); return nil }
            .register(.imMessageReceiveV1) { _, raw in print(raw.eventId ?? ""); return nil }
            .register("any.event_v1") { event in print(event.payload); return nil }
        dispatcher.register(.cardActionTrigger) { event, _ in
            _ = event.action?.value
            return CardActionResponse(toast: .init(type: .info, content: "Saved"), card: .raw(newCardJSON))
        }
        let response = await dispatcher.handleWebhook(WebhookRequest(headers: [:], body: Data(#"{"type":"url_verification","challenge":"c","token":"t"}"#.utf8)))
        // Same as node-sdk generateChallenge: a plain challenge with the right token is answered.
        #expect(response.statusCode == 200)
        #expect(try JSONValue(data: response.body)["challenge"]?.stringValue == "c")
        #expect(IM.Events.messageReceiveV1.name == "im.message.receive_v1")
    }
}
