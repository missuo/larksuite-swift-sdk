import Foundation
import Testing
@testable import LarkChannel
@testable import LarkCore

/// Port of node-sdk `channel/__tests__/channel-api.test.ts` plus the other
/// channel-level APIs and event wiring.
@Suite struct ChannelAPITests {
    // MARK: downloadResource

    @Test func imageDownloadReturnsBytes() async throws {
        let payload = Data("fake-png-bytes".utf8)
        let http = TestSupport.http { req in
            #expect(req.method == .get)
            #expect(req.url.path == "/open-apis/im/v1/images/img_v3_xyz")
            return LarkHTTPResponse(statusCode: 200, headers: ["Content-Type": "image/png"], body: payload)
        }
        let ch = try TestSupport.channel(http: http)
        #expect(try await ch.downloadResource("img_v3_xyz", type: .image) == payload)
    }

    @Test func fileDownloadReturnsBytes() async throws {
        let payload = Data("hello file contents".utf8)
        let http = TestSupport.http { req in
            #expect(req.url.path == "/open-apis/im/v1/files/file_v3_xyz")
            return LarkHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: payload)
        }
        let ch = try TestSupport.channel(http: http)
        #expect(try await ch.downloadResource("file_v3_xyz", type: .file) == payload)
    }

    /// node: "legacy Buffer response" / "{ data: Buffer } shape" — in Swift any
    /// non-JSON 2xx body is the payload, with or without a content type.
    @Test func downloadWithoutContentTypeStillWorks() async throws {
        let payload = Data("legacy".utf8)
        let http = TestSupport.http { _ in LarkHTTPResponse(statusCode: 200, headers: [:], body: payload) }
        let ch = try TestSupport.channel(http: http)
        #expect(try await ch.downloadResource("img_x", type: .image) == payload)
    }

    /// node: "unknown shape throws" — the Swift transport always yields bytes;
    /// the failure mode is a JSON error envelope, which throws.
    @Test func downloadErrorEnvelopeThrows() async throws {
        let http = TestSupport.http { _ in TestSupport.apiError(code: 234001, status: 400) }
        let ch = try TestSupport.channel(http: http)
        await #expect(throws: LarkError.self) { try await ch.downloadResource("img_x", type: .image) }
    }

    // MARK: reactions

    @Test func addReactionReturnsReactionId() async throws {
        let http = TestSupport.http { _ in
            MockHTTPClient.json(["code": 0, "data": ["reaction_id": "rx_1234", "reaction_type": ["emoji_type": "OK"]]])
        }
        let ch = try TestSupport.channel(http: http)
        #expect(try await ch.addReaction("om_xyz", emojiType: "OK") == "rx_1234")
        let req = try #require(http.apiRequests.first)
        #expect(req.method == .post)
        #expect(req.url.path == "/open-apis/im/v1/messages/om_xyz/reactions")
        #expect(TestSupport.bodyString(req) == #"{"reaction_type":{"emoji_type":"OK"}}"#)
    }

    @Test func addReactionAcceptsTopLevelReactionId() async throws {
        let http = TestSupport.http { _ in MockHTTPClient.json(["code": 0, "reaction_id": "rx_top"]) }
        let ch = try TestSupport.channel(http: http)
        #expect(try await ch.addReaction("om_xyz", emojiType: "OK") == "rx_top")
    }

    @Test func addReactionThrowsWhenReactionIdMissing() async throws {
        let http = TestSupport.http { _ in MockHTTPClient.json(["code": 0, "data": [:]]) }
        let ch = try TestSupport.channel(http: http)
        do {
            _ = try await ch.addReaction("om_xyz", emojiType: "OK")
            Issue.record("expected throw")
        } catch let e as LarkChannelError {
            #expect(e.code == .unknown)
            #expect(e.message.contains("no reaction_id"))
        }
    }

    @Test func removeReactionDeletesById() async throws {
        let http = TestSupport.http { _ in MockHTTPClient.json(["code": 0, "data": [:]]) }
        let ch = try TestSupport.channel(http: http)
        try await ch.removeReaction("om_xyz", reactionId: "rx_1234")
        let req = try #require(http.apiRequests.first)
        #expect(req.method == .delete)
        #expect(req.url.path == "/open-apis/im/v1/messages/om_xyz/reactions/rx_1234")
        #expect(req.body == nil)
    }

    @Test func removeReactionByEmojiDeletesBotReaction() async throws {
        let http = TestSupport.http { req in
            if req.method == .get {
                return MockHTTPClient.json([
                    "code": 0,
                    "data": ["items": [
                        ["reaction_id": "rx_user", "operator": ["operator_type": "user"]],
                        ["reaction_id": "rx_bot", "operator": ["operator_type": "app"]],
                    ]],
                ])
            }
            return MockHTTPClient.json(["code": 0, "data": [:]])
        }
        let ch = try TestSupport.channel(http: http)
        #expect(try await ch.removeReactionByEmoji("om_xyz", emojiType: "OK") == true)
        let reqs = http.apiRequests
        #expect(reqs.count == 2)
        #expect(reqs[0].url.path == "/open-apis/im/v1/messages/om_xyz/reactions")
        // Query keys in node `qs` order.
        #expect(reqs[0].url.query == "reaction_type=OK&page_size=50")
        #expect(reqs[1].method == .delete)
        #expect(reqs[1].url.path == "/open-apis/im/v1/messages/om_xyz/reactions/rx_bot")
    }

    @Test func removeReactionByEmojiReturnsFalseWhenBotHasNotReacted() async throws {
        let http = TestSupport.http { _ in
            MockHTTPClient.json(["code": 0, "data": ["items": [["reaction_id": "rx_user", "operator": ["operator_type": "user"]]]]])
        }
        let ch = try TestSupport.channel(http: http)
        #expect(try await ch.removeReactionByEmoji("om_xyz", emojiType: "OK") == false)
        #expect(http.apiRequests.filter { $0.method == .delete }.isEmpty)
    }

    @Test func removeReactionByEmojiReturnsFalseOnEmptyList() async throws {
        let http = TestSupport.http { _ in MockHTTPClient.json(["code": 0, "data": ["items": []]]) }
        let ch = try TestSupport.channel(http: http)
        #expect(try await ch.removeReactionByEmoji("om_xyz", emojiType: "OK") == false)
        #expect(http.apiRequests.count == 1)
    }

    // MARK: editMessage / recall / updateCard

    @Test func editMessageUsesMessageUpdateWithTextType() async throws {
        let http = TestSupport.http { _ in MockHTTPClient.json(["code": 0, "data": [:]]) }
        let ch = try TestSupport.channel(http: http)
        try await ch.editMessage("om_xyz", text: "new body")
        let req = try #require(http.apiRequests.first)
        #expect(req.method == .put)  // message.update, NOT message.patch
        #expect(req.url.path == "/open-apis/im/v1/messages/om_xyz")
        #expect(TestSupport.bodyString(req) == #"{"msg_type":"text","content":"{\"text\":\"new body\"}"}"#)
    }

    @Test func recallMessageDeletes() async throws {
        let http = TestSupport.http { _ in MockHTTPClient.json(["code": 0]) }
        let ch = try TestSupport.channel(http: http)
        try await ch.recallMessage("om_xyz")
        let req = try #require(http.apiRequests.first)
        #expect(req.method == .delete)
        #expect(req.url.path == "/open-apis/im/v1/messages/om_xyz")
    }

    @Test func updateCardPatchesWithSerializedCard() async throws {
        let http = TestSupport.http { _ in MockHTTPClient.json(["code": 0]) }
        let ch = try TestSupport.channel(http: http)
        try await ch.updateCard("om_card", card: ["schema": "2.0", "body": ["elements": []]])
        let req = try #require(http.apiRequests.first)
        #expect(req.method == .patch)
        #expect(req.url.path == "/open-apis/im/v1/messages/om_card")
        // User cards (unordered JSONValue) are serialised with sorted keys.
        #expect(TestSupport.bodyString(req) == #"{"content":"{\"body\":{\"elements\":[]},\"schema\":\"2.0\"}"}"#)
    }

    // MARK: card.action dedup key includes button identity

    static func rawCardAction(_ value: JSONValue, messageId: String = "om_card1") -> JSONValue {
        [
            "schema": "2.0",
            "header": ["event_type": "card.action.trigger", "event_id": "ev"],
            "event": [
                "context": ["open_message_id": .string(messageId), "open_chat_id": "oc_test"],
                "operator": ["open_id": "ou_alice"],
                "action": ["tag": "button", "value": value],
            ],
        ]
    }

    @Test func twoDifferentButtonsOnTheSameCardBothFire() async throws {
        let ch = try TestSupport.channel(http: TestSupport.http { _ in MockHTTPClient.json(["code": 0]) })
        ch.registerDispatcherHandlers()
        let fired = Recorder<JSONValue?>()
        ch.on(.cardAction) { evt in fired.append(evt.action.value) }
        _ = try await ch.dispatcher.dispatch(json: Self.rawCardAction(["cmd": "A"]))
        _ = try await ch.dispatcher.dispatch(json: Self.rawCardAction(["cmd": "B"]))
        #expect(fired.items == [["cmd": "A"], ["cmd": "B"]])
    }

    @Test func sameButtonClickedTwiceOnlyFiresOnce() async throws {
        let ch = try TestSupport.channel(http: TestSupport.http { _ in MockHTTPClient.json(["code": 0]) })
        ch.registerDispatcherHandlers()
        let calls = Recorder<Int>()
        ch.on(.cardAction) { _ in calls.append(1) }
        _ = try await ch.dispatcher.dispatch(json: Self.rawCardAction(["cmd": "A"], messageId: "om_dedup_probe"))
        _ = try await ch.dispatcher.dispatch(json: Self.rawCardAction(["cmd": "A"], messageId: "om_dedup_probe"))
        #expect(calls.count == 1)
    }

    @Test func cardActionIdMatchesNodeFormat() {
        #expect(LarkChannel.cardActionId(.init(value: ["cmd": "A"], tag: "button")) == #"button|||{"cmd":"A"}"#)
        #expect(LarkChannel.cardActionId(.init(value: "plain", tag: "button", name: "n", option: "o")) == "button|n|o|plain")
        #expect(LarkChannel.cardActionId(.init(value: nil, tag: "t")) == #"t|||"""#)
        #expect(LarkChannel.cardActionId(.init(value: .null, tag: "t")) == #"t|||"""#)
        let long = String(repeating: "x", count: 200)
        #expect(LarkChannel.cardActionId(.init(value: .string(long), tag: "b")) == "b|||" + String(repeating: "x", count: 128))
    }

    // MARK: comment dedup key includes replyId

    static func rawComment(fileToken: String = "doccn_x", commentId: String, replyId: String? = nil) -> JSONValue {
        var event: JSONValue = [
            "file_token": .string(fileToken), "file_type": "doc", "comment_id": .string(commentId), "is_mentioned": true,
            "create_time": .string(String(Int(Date().timeIntervalSince1970 * 1000))),
            "notice_meta": ["from_user_id": ["open_id": "ou_alice"]],
        ]
        if let replyId { event["reply_id"] = .string(replyId) }
        return ["schema": "2.0", "header": ["event_type": "drive.notice.comment_add_v1"], "event": event]
    }

    @Test func topLevelCommentFires() async throws {
        let ch = try TestSupport.channel(http: TestSupport.http { _ in MockHTTPClient.json(["code": 0]) })
        ch.registerDispatcherHandlers()
        let fired = Recorder<String?>()
        ch.on(.comment) { evt in fired.append(evt.replyId) }
        _ = try await ch.dispatcher.dispatch(json: Self.rawComment(commentId: "cmt_top_a"))
        #expect(fired.items == [nil])
    }

    @Test func repliesInTheSameThreadAllFire() async throws {
        let ch = try TestSupport.channel(http: TestSupport.http { _ in MockHTTPClient.json(["code": 0]) })
        ch.registerDispatcherHandlers()
        let fired = Recorder<String?>()
        ch.on(.comment) { evt in fired.append(evt.replyId) }
        for r in ["rpl_1", "rpl_2", "rpl_3"] {
            _ = try await ch.dispatcher.dispatch(json: Self.rawComment(fileToken: "doc_thread", commentId: "cmt_thread_a", replyId: r))
        }
        #expect(fired.items == ["rpl_1", "rpl_2", "rpl_3"])
    }

    @Test func genuineDuplicateCommentIsDedupedOnce() async throws {
        let ch = try TestSupport.channel(http: TestSupport.http { _ in MockHTTPClient.json(["code": 0]) })
        ch.registerDispatcherHandlers()
        let calls = Recorder<Int>()
        ch.on(.comment) { _ in calls.append(1) }
        let raw = Self.rawComment(fileToken: "doc_dup", commentId: "cmt_dup_a", replyId: "rpl_x")
        _ = try await ch.dispatcher.dispatch(json: raw)
        _ = try await ch.dispatcher.dispatch(json: raw)
        #expect(calls.count == 1)
    }

    @Test func topLevelAndReplyDoNotCollide() async throws {
        let ch = try TestSupport.channel(http: TestSupport.http { _ in MockHTTPClient.json(["code": 0]) })
        ch.registerDispatcherHandlers()
        let fired = Recorder<String?>()
        ch.on(.comment) { evt in fired.append(evt.replyId) }
        _ = try await ch.dispatcher.dispatch(json: Self.rawComment(fileToken: "doc_mix", commentId: "cmt_mix_a"))
        _ = try await ch.dispatcher.dispatch(json: Self.rawComment(fileToken: "doc_mix", commentId: "cmt_mix_a", replyId: "rpl_1"))
        #expect(fired.items == [nil, "rpl_1"])
    }

    // MARK: share_chat / share_user / sticker outbound

    static func okSender() -> MockHTTPClient {
        TestSupport.http { _ in MockHTTPClient.json(["code": 0, "data": ["message_id": "om_ok"]]) }
    }

    @Test func shareChatOutbound() async throws {
        let http = Self.okSender()
        let ch = try TestSupport.channel(http: http)
        let r = try await ch.send("oc_abc", .shareChat(chatId: "oc_target"))
        #expect(r.messageId == "om_ok")
        let req = try #require(http.apiRequests.first)
        #expect(try TestSupport.body(req)["msg_type"] == "share_chat")
        #expect(try TestSupport.content(req) == ["chat_id": "oc_target"])
    }

    @Test func shareUserOutbound() async throws {
        let http = Self.okSender()
        let ch = try TestSupport.channel(http: http)
        let r = try await ch.send("oc_abc", .shareUser(userId: "ou_alice"))
        #expect(r.messageId == "om_ok")
        let req = try #require(http.apiRequests.first)
        #expect(try TestSupport.body(req)["msg_type"] == "share_user")
        #expect(try TestSupport.content(req) == ["user_id": "ou_alice"])
    }

    @Test func stickerOutbound() async throws {
        let http = Self.okSender()
        let ch = try TestSupport.channel(http: http)
        let r = try await ch.send("oc_abc", .sticker(fileKey: "sticker_abc"))
        #expect(r.messageId == "om_ok")
        let req = try #require(http.apiRequests.first)
        #expect(try TestSupport.body(req)["msg_type"] == "sticker")
        #expect(try TestSupport.content(req) == ["file_key": "sticker_abc"])
    }

    // MARK: getChatMode / getChatInfo

    static func chatChannel(_ data: JSONValue) throws -> (LarkChannel, MockHTTPClient) {
        let http = TestSupport.http { req in
            #expect(req.url.path == "/open-apis/im/v1/chats/oc_x")
            return MockHTTPClient.json(["code": 0, "data": data])
        }
        return (try TestSupport.channel(http: http), http)
    }

    @Test(arguments: [
        (JSONValue.object(["chat_mode": "p2p"]), ChatMode.p2p),
        (JSONValue.object(["chat_mode": "group"]), ChatMode.group),
        (JSONValue.object(["chat_mode": "topic"]), ChatMode.topic),
        (JSONValue.object([:]), ChatMode.group),
        (JSONValue.object(["chat_mode": "something_new"]), ChatMode.group),
    ])
    func getChatMode(_ data: JSONValue, _ expected: ChatMode) async throws {
        let (ch, _) = try Self.chatChannel(data)
        #expect(try await ch.getChatMode("oc_x") == expected)
    }

    @Test func getChatModePropagatesApiErrors() async throws {
        let http = TestSupport.http { _ in TestSupport.apiError(code: 99991672, status: 403) }
        let ch = try TestSupport.channel(http: http)
        do {
            _ = try await ch.getChatMode("oc_x")
            Issue.record("expected throw")
        } catch let e as LarkError {
            #expect(e.apiError?.code == 99991672)
        }
    }

    @Test func getChatInfoMapsFields() async throws {
        let (ch, _) = try Self.chatChannel([
            "name": "Team", "description": "desc", "chat_mode": "topic", "owner_id": "ou_owner", "user_count": "12",
        ])
        let info = try await ch.getChatInfo("oc_x")
        #expect(info == ChatInfo(chatId: "oc_x", name: "Team", description: "desc", chatType: "topic", ownerId: "ou_owner", memberCount: 12))
        let (ch2, _) = try Self.chatChannel([:])
        #expect(try await ch2.getChatInfo("oc_x").chatType == .group)
    }

    // MARK: event wiring

    @Test func handlerRegistrationReplacesAndUnsubscribes() async throws {
        let logger = CapturingLogger()
        let ch = try TestSupport.channel(http: Self.okSender(), logger: logger)
        let first = ch.on(.reaction) { _ in }
        #expect(ch.handler(.reaction) != nil)
        let second = ch.on(.reaction) { _ in }
        #expect(logger.lines.contains { $0.1.contains("handler for \"reaction\" is being overwritten") })
        first()  // stale unsubscribe is a no-op
        #expect(ch.handler(.reaction) != nil)
        second()
        #expect(ch.handler(.reaction) == nil)

        let all = ch.on(LarkChannelHandlers(message: { _ in }, reconnecting: {}))
        #expect(ch.handler(.message) != nil && ch.handler(.reconnecting) != nil)
        all()
        #expect(ch.handler(.message) == nil && ch.handler(.reconnecting) == nil)
    }

    static func reactionEvent(_ type: String, actionTime: String) -> JSONValue {
        [
            "schema": "2.0", "header": ["event_type": .string(type)],
            "event": [
                "message_id": "om_r", "reaction_type": ["emoji_type": "OK"],
                "user_id": ["open_id": "ou_a", "user_id": "u_a"], "action_time": .string(actionTime),
            ],
        ]
    }

    @Test func reactionsAreDedupedByActionTime() async throws {
        let ch = try TestSupport.channel(http: Self.okSender(), includeRawEvent: true)
        ch.registerDispatcherHandlers()
        let got = Recorder<ReactionEvent>()
        ch.on(.reaction) { got.append($0) }
        _ = try await ch.dispatcher.dispatch(json: Self.reactionEvent("im.message.reaction.created_v1", actionTime: "1"))
        _ = try await ch.dispatcher.dispatch(json: Self.reactionEvent("im.message.reaction.created_v1", actionTime: "1"))
        _ = try await ch.dispatcher.dispatch(json: Self.reactionEvent("im.message.reaction.deleted_v1", actionTime: "1"))
        _ = try await ch.dispatcher.dispatch(json: Self.reactionEvent("im.message.reaction.created_v1", actionTime: "2"))
        #expect(got.items.map(\.action) == [.added, .removed, .added])
        #expect(got.items.first?.raw?["tenant_key"] == JSONValue?.none)
        #expect(got.items.first?.raw?["message_id"] == "om_r")
        #expect(LarkChannel.reactionKey(got.items[0]) == "rx:om_r:ou_a:OK:added:1")
    }

    @Test func botAddedFiresDirectlyAndHandlerErrorsAreEmitted() async throws {
        let ch = try TestSupport.channel(http: Self.okSender())
        ch.registerDispatcherHandlers()
        let errors = Recorder<LarkChannelError>()
        ch.on(.error) { errors.append($0) }
        struct Boom: Error {}
        ch.on(.botAdded) { evt in
            #expect(evt.chatId == "oc_new")
            #expect(evt.botName == "Bot")
            throw Boom()
        }
        _ = try await ch.dispatcher.dispatch(json: [
            "schema": "2.0", "header": ["event_type": "im.chat.member.bot.added_v1"],
            "event": ["chat_id": "oc_new", "operator_id": ["open_id": "ou_a"], "name": "Bot", "external": false],
        ])
        #expect(errors.count == 1)
        #expect(errors.items.first?.code == .unknown)
    }

    static func messageEvent(id: String, text: String, chatType: String = "p2p", mentions: JSONValue = []) -> JSONValue {
        [
            "schema": "2.0", "header": ["event_type": "im.message.receive_v1"],
            "event": [
                "sender": ["sender_id": ["open_id": "ou_alice"]],
                "message": [
                    "message_id": .string(id), "chat_id": "oc_chat", "chat_type": .string(chatType), "message_type": "text",
                    "content": .string(#"{"text":"\#(text)"}"#),
                    "create_time": .string(String(Int(Date().timeIntervalSince1970 * 1000))), "mentions": mentions,
                ],
            ],
        ]
    }

    @Test func inboundMessagesAreBatchedPerChat() async throws {
        let ch = try TestSupport.channel(http: Self.okSender(), safety: .init(batch: .init(text: .init(delayMs: 30))))
        ch.registerDispatcherHandlers()
        let got = Recorder<NormalizedMessage>()
        ch.on(.message) { got.append($0) }
        _ = try await ch.dispatcher.dispatch(json: Self.messageEvent(id: "om_b1", text: "hello"))
        _ = try await ch.dispatcher.dispatch(json: Self.messageEvent(id: "om_b2", text: "world"))
        _ = try await ch.dispatcher.dispatch(json: Self.messageEvent(id: "om_b1", text: "hello"))  // in-flight duplicate
        #expect(await eventually { got.count == 1 })
        #expect(got.items[0].content == "hello\n\nworld")
        #expect(got.items[0].messageId == "om_b2")
        // Committed to the dedup cache after the handler ran.
        #expect(await eventually { await ch.safety.seenCache.memoryContains("om_b1") })
        _ = try await ch.dispatcher.dispatch(json: Self.messageEvent(id: "om_b1", text: "hello"))
        await sleepMillis(80)
        #expect(got.count == 1)
    }

    @Test func rejectedGroupMessagesEmitReject() async throws {
        let ch = try TestSupport.channel(http: Self.okSender())
        ch.registerDispatcherHandlers()
        let rejects = Recorder<RejectEvent>()
        let messages = Recorder<NormalizedMessage>()
        ch.on(LarkChannelHandlers(message: { messages.append($0) }, reject: { rejects.append($0) }))
        _ = try await ch.dispatcher.dispatch(json: Self.messageEvent(id: "om_g1", text: "hi", chatType: "group"))
        #expect(rejects.items == [RejectEvent(messageId: "om_g1", chatId: "oc_chat", senderId: "ou_alice", reason: .noMention)])
        ch.updatePolicy(PolicyConfig(requireMention: false))
        #expect(ch.getPolicy().requireMention == false)
        _ = try await ch.dispatcher.dispatch(json: Self.messageEvent(id: "om_g2", text: "hi", chatType: "group"))
        #expect(await eventually { messages.count == 1 })
    }

    @Test func malformedMessageEmitsError() async throws {
        let ch = try TestSupport.channel(http: Self.okSender())
        ch.registerDispatcherHandlers()
        let errors = Recorder<LarkChannelError>()
        ch.on(.error) { errors.append($0) }
        _ = try await ch.dispatcher.dispatch(json: ["schema": "2.0", "header": ["event_type": "im.message.receive_v1"], "event": [:]])
        #expect(errors.count == 1)
        #expect(errors.items[0].code == .unknown)
    }

    @Test func mergeForwardFetchesSubMessagesViaMessageGet() async throws {
        let http = TestSupport.http { req in
            #expect(req.method == .get)
            #expect(req.url.path == "/open-apis/im/v1/messages/om_fw")
            return MockHTTPClient.json(["code": 0, "data": ["items": [
                ["message_id": "om_fw", "msg_type": "merge_forward", "body": ["content": "x"]],
                ["message_id": "om_c", "upper_message_id": "om_fw", "msg_type": "text", "body": ["content": #"{"text":"inner"}"#],
                 "sender": ["id": "ou_b"], "create_time": "1776753549563"],
            ]]])
        }
        let ch = try TestSupport.channel(http: http, safety: .init(chatQueue: .init(enabled: false)))
        ch.registerDispatcherHandlers()
        let got = Recorder<NormalizedMessage>()
        ch.on(.message) { got.append($0) }
        var ev = Self.messageEvent(id: "om_fw", text: "")
        ev["event"]?["message"]?["message_type"] = "merge_forward"
        _ = try await ch.dispatcher.dispatch(json: ev)
        #expect(await eventually { got.count == 1 })
        #expect(got.items[0].content == "<forwarded_messages>\n[2026-04-21T14:39:09+08:00] ou_b:\n    inner\n</forwarded_messages>")
    }
}
