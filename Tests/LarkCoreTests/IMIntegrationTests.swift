import Foundation
import Testing
@testable import LarkCore
import LarkIM

/// Mirrors the call sites of the feishu-agent bot against a mock Open Platform.
@Suite struct IMIntegrationTests {
    static func makeClient(_ handler: @escaping @Sendable (LarkHTTPRequest) throws -> LarkHTTPResponse) throws -> (LarkClient, MockHTTPClient) {
        let http = MockHTTPClient { req in
            if req.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
                return MockHTTPClient.json(["code": 0, "tenant_access_token": "t-123", "expire": 7200])
            }
            return try handler(req)
        }
        let client = try LarkClient(
            LarkConfiguration(appId: "cli_test", appSecret: "secret", logLevel: .fatal, cache: DefaultLarkCache(), httpClient: http))
        return (client, http)
    }

    static func query(_ req: LarkHTTPRequest) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for item in URLComponents(url: req.url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name, default: []].append(item.value ?? "")
        }
        return out
    }

    @Test func sendAndReply() async throws {
        let (client, http) = try Self.makeClient { req in
            MockHTTPClient.json(["code": 0, "msg": "success", "data": ["message_id": "om_new", "chat_id": "oc_1"]])
        }
        let created = try await client.im.v1.message.create(
            params: .init(receiveIdType: .chatId),
            body: .init(receiveId: "oc_1", msgType: "text", content: try LarkJSON.string(["text": "hello"])))
        #expect(created.data?.messageId == "om_new")

        let replied = try await client.im.v1.message.reply(
            messageId: "om_root", body: .init(content: #"{"text":"hi"}"#, msgType: "text", replyInThread: false))
        #expect(replied.data?.messageId == "om_new")

        let reqs = http.requests
        // Token fetched once and reused.
        #expect(reqs.filter { $0.url.path.hasSuffix("tenant_access_token/internal") }.count == 1)
        let create = reqs[1]
        #expect(create.method == .post)
        #expect(create.url.path == "/open-apis/im/v1/messages")
        #expect(Self.query(create)["receive_id_type"] == ["chat_id"])
        #expect(create.headers["Authorization"] == "Bearer t-123")
        let body = try JSONValue(data: create.body!)
        #expect(body["receive_id"]?.stringValue == "oc_1")
        #expect(body["msg_type"]?.stringValue == "text")
        #expect(try JSONValue(jsonString: body["content"]!.stringValue!)["text"]?.stringValue == "hello")
        #expect(body["uuid"] == nil)  // nil optionals are omitted

        let reply = reqs[2]
        #expect(reply.url.path == "/open-apis/im/v1/messages/om_root/reply")
        #expect(try JSONValue(data: reply.body!)["reply_in_thread"] == .bool(false))
    }

    @Test func historyPaging() async throws {
        let (client, http) = try Self.makeClient { req in
            let token = Self.query(req)["page_token"]?.first
            let page: JSONValue = token == nil
                ? ["has_more": true, "page_token": "p2", "items": [["message_id": "om_1", "msg_type": "text", "create_time": "1700000000000", "body": ["content": #"{"text":"a"}"#], "sender": ["id": "ou_1", "id_type": "open_id", "sender_type": "user"]]]]
                : ["has_more": false, "items": [["message_id": "om_2", "msg_type": "post"]]]
            return MockHTTPClient.json(["code": 0, "data": page])
        }
        let params = IM.MessageListQuery(
            containerIdType: "chat", containerId: "oc_1", startTime: "1700000000", sortType: .byCreateTimeAsc, pageSize: 50)
        var ids: [String] = []
        for try await page in client.im.v1.message.listWithIterator(params: params) {
            ids += (page.items ?? []).compactMap(\.messageId)
        }
        #expect(ids == ["om_1", "om_2"])
        let first = http.requests[1]
        #expect(Self.query(first)["sort_type"] == ["ByCreateTimeAsc"])
        #expect(Self.query(first)["page_size"] == ["50"])
        #expect(Self.query(first)["start_time"] == ["1700000000"])
        #expect(Self.query(http.requests[2])["page_token"] == ["p2"])

        // Typed access to the first item.
        let one = try await client.im.v1.message.list(params: params)
        let item = try #require(one.data?.items?.first)
        #expect(item.body?.content == #"{"text":"a"}"#)
        #expect(item.sender?.idType == "open_id")
    }

    @Test func downloadResource() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let (client, http) = try Self.makeClient { _ in
            LarkHTTPResponse(statusCode: 200, headers: ["Content-Type": "image/png", "Content-Disposition": "attachment; filename=\"a.png\""], body: png)
        }
        let file = try await client.im.v1.messageResource.get(messageId: "om_1", fileKey: "img_v3_x", params: .init(type: "image"))
        #expect(file.data == png)
        #expect(file.fileName == "a.png")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lark-test-\(UUID().uuidString).png")
        try file.write(to: url)
        #expect(try Data(contentsOf: url) == png)
        try? FileManager.default.removeItem(at: url)
        #expect(http.requests[1].url.path == "/open-apis/im/v1/messages/om_1/resources/img_v3_x")
        #expect(Self.query(http.requests[1])["type"] == ["image"])
    }

    @Test func chatMembersAndRawRequest() async throws {
        let (client, _) = try Self.makeClient { req in
            if req.url.path == "/open-apis/bot/v3/info" {
                return MockHTTPClient.json(["code": 0, "msg": "ok", "bot": ["open_id": "ou_bot", "app_name": "agent"]])
            }
            return MockHTTPClient.json(["code": 0, "data": ["has_more": false, "items": [["member_id": "ou_a", "name": "A"], ["member_id": "ou_b"]]]])
        }
        var members: [String] = []
        for try await page in client.im.v1.chatMembers.getWithIterator(chatId: "oc_1", params: .init(memberIdType: .openId, pageSize: 100)) {
            members += (page.items ?? []).compactMap(\.memberId)
        }
        #expect(members == ["ou_a", "ou_b"])

        let info = try await client.request(.get, "/open-apis/bot/v3/info", as: JSONValue.self)
        #expect(info.json?["bot"]?["open_id"]?.stringValue == "ou_bot")
    }

    @Test func businessErrorsThrow() async throws {
        let (client, _) = try Self.makeClient { _ in
            MockHTTPClient.json(["code": 230002, "msg": "Bot/User can NOT be out of the chat."], status: 400, headers: ["X-Tt-Logid": "log-1"])
        }
        do {
            _ = try await client.im.v1.message.create(
                params: .init(receiveIdType: .chatId), body: .init(receiveId: "oc_x", msgType: "text", content: "{}"))
            Issue.record("expected an error")
        } catch let LarkError.api(e) {
            #expect(e.code == 230002)
            #expect(e.httpStatus == 400)
            #expect(e.logId == "log-1")
        }
    }

    @Test func typedEvents() async throws {
        let received = AsyncStream<(String, String)>.makeStream()
        let dispatcher = EventDispatcher(logLevel: .fatal)
            .register(.imMessageReceiveV1) { e, _ in
                received.continuation.yield((e.message.messageId, e.sender.senderId?.openId ?? ""))
                return nil
            }
            .register(.cardActionTrigger) { e, _ in
                CardActionResponse(
                    toast: .init(type: .success, content: "chose \(e.action?.value?["option"]?.stringValue ?? "")"),
                    card: .raw(["schema": "2.0"]))
            }
        _ = try await dispatcher.dispatch(json: try JSONValue(jsonString: """
            {"schema":"2.0","header":{"event_id":"e1","event_type":"im.message.receive_v1","tenant_key":"t"},
             "event":{"sender":{"sender_id":{"open_id":"ou_1"},"sender_type":"user"},
                      "message":{"message_id":"om_9","chat_id":"oc_1","chat_type":"group","message_type":"text","content":"{\\"text\\":\\"hi\\"}","create_time":"1"}}}
            """))
        var it = received.stream.makeAsyncIterator()
        let got = await it.next()
        #expect(got?.0 == "om_9")
        #expect(got?.1 == "ou_1")

        let out = try await dispatcher.dispatch(json: try JSONValue(jsonString: """
            {"schema":"2.0","header":{"event_type":"card.action.trigger","token":"vt"},
             "event":{"operator":{"open_id":"ou_2"},"token":"card-token","action":{"tag":"button","value":{"kind":"choice","option":"B"}},
                      "context":{"open_message_id":"om_card","open_chat_id":"oc_1"}}}
            """))
        #expect(out?["toast"]?["content"]?.stringValue == "chose B")
        #expect(out?["card"]?["type"]?.stringValue == "raw")
    }
}
