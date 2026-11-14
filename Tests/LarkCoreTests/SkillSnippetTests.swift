import Foundation
import Testing
@testable import LarkCore
import LarkIM

/// Compile-checks the code shown in skills/lark-swift-sdk/SKILL.md (never executed against a server).
@Suite struct SkillSnippetTests {
    func snippets(client: LarkClient, chatId: String, openId: String, rootId: String, key: String) async throws {
        let sent = try await client.im.v1.message.create(
            params: .init(receiveIdType: .chatId), body: .text(to: chatId, "hello \(MessageContent.at(openId))"))
        _ = sent.data?.messageId
        _ = try await client.im.v1.message.reply(messageId: rootId, body: .text("ok", replyInThread: false))
        _ = try await client.im.v1.message.reply(messageId: rootId, body: .card(["schema": "2.0", "body": ["elements": []]]))
        let params = IM.MessageListQuery(
            containerIdType: "chat", containerId: chatId, startTime: "1", sortType: .byCreateTimeAsc, pageSize: 50)
        for try await page in client.im.v1.message.listWithIterator(params: params) {
            for m in page.items ?? [] { print(m.messageId ?? "", m.msgType ?? "", m.body?.content ?? "") }
        }
        let file = try await client.im.v1.messageResource.get(messageId: rootId, fileKey: key, params: .init(type: "image"))
        try file.writeFile("/tmp/a.png")
        var ids: [String] = []
        for try await page in client.im.v1.chatMembers.getWithIterator(
            chatId: chatId, params: .init(memberIdType: .openId, pageSize: 100))
        {
            ids += (page.items ?? []).compactMap(\.memberId)
        }
        _ = try await client.im.v1.image.create(body: .init(imageType: "message", image: try LarkFile(path: "/tmp/a.png")))
        _ = try await client.im.v1.message.create(params: .init(receiveIdType: "chat_id"), body: .card(to: chatId, ["schema": "2.0"]))
        let info = try await client.request(.get, "/open-apis/bot/v3/info", as: JSONValue.self)
        _ = info.json?["bot"]?["open_id"]?.stringValue
        do {
            _ = try await client.request(.post, "/open-apis/x", query: params, json: ["a": 1] as JSONValue, as: JSONValue.self)
        } catch let LarkError.api(e) {
            print(e.code, e.msg, e.logId ?? "")
        }
        _ = try await client.im.v1.message.list(params: params, options: .userAccessToken("u-x"))
    }

    func registerAppSnippet() async throws {
        let result = try await registerApp(RegisterAppOptions(onQRCodeReady: { qr in print("scan:", qr.url) }))
        print(result.clientId, result.clientSecret)
        let app = try await registerApp(RegisterAppOptions(
            appPreset: AppPreset(name: "My Agent"),
            onQRCodeReady: { qr in print("Scan to create the app:", qr.url) }))
        print(app.clientId, app.clientSecret)
    }

    @Test func dispatcherSnippetBuilds() async throws {
        let dispatcher = EventDispatcher(logLevel: .fatal)
            .register(.imMessageReceiveV1) { e, _ in
                guard let m = e.message else { return nil }
                _ = (m.messageId, m.chatId, m.chatType, m.messageType, m.content, m.mentions, m.rootId, m.parentId)
                _ = (e.sender?.senderId?.openId, e.text)
                return nil
            }
            .register(.imChatMemberBotAddedV1) { e, _ in
                print("added to", e.chatId ?? "")
                return nil
            }
            .register(.cardActionTrigger) { e, _ in
                _ = e.action?.value
                return CardActionResponse(toast: .init(type: .success, content: "Done"), card: .template(id: "t", variables: ["a": 1]))
            }
            .register("some.event_v1") { event in
                _ = event.payload
                return nil
            }
        #expect(dispatcher.registeredEventTypes.contains("card.action.trigger"))
        let ws = try WSClient(.init(appId: "cli_0123456789abcdef", appSecret: "x", onReady: {}, onError: { _ in }))
        #expect(await ws.connectionStatus.state == .idle)
    }
}
