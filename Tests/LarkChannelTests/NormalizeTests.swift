import Foundation
import Testing
@testable import LarkChannel
import LarkCore

/// Ports of node-sdk `channel/normalize/__tests__/*.test.ts` plus node-produced vectors.
@Suite struct NormalizeTests {
    static let ctx = ConvertContext(messageId: "om_x")

    static func convert(_ fn: ContentConverter, _ raw: String, _ ctx: ConvertContext = ctx) async throws -> ConvertResult {
        try await fn(raw, ctx)
    }

    // MARK: converters.test.ts — simple converters

    @Test func textExtractsText() async throws {
        let r = try await Self.convert(Converters.text, #"{"text":"hello"}"#)
        #expect(r.content == "hello")
        #expect(r.resources.isEmpty)
        #expect(try await Self.convert(Converters.text, "{}").content == "")
    }

    @Test func imageRendersMarkdownAndResource() async throws {
        let r = try await Self.convert(Converters.image, #"{"image_key":"img_v3_abc"}"#)
        #expect(r.content == "![image](img_v3_abc)")
        #expect(r.resources == [ResourceDescriptor(type: .image, fileKey: "img_v3_abc")])
        let missing = try await Self.convert(Converters.image, "{}")
        #expect(missing.content == "[image]")
        #expect(missing.resources.isEmpty)
    }

    @Test func fileIncludesNameAttribute() async throws {
        let r = try await Self.convert(Converters.file, #"{"file_key":"f1","file_name":"doc.pdf"}"#)
        #expect(r.content == #"<file key="f1" name="doc.pdf"/>"#)
        #expect(r.resources[0].fileName == "doc.pdf")
    }

    @Test func audioFormatsDuration() async throws {
        let r = try await Self.convert(Converters.audio, #"{"file_key":"a1","duration":1500}"#)
        #expect(r.content == #"<audio key="a1" duration="1.5s"/>"#)
        #expect(r.resources[0].durationMs == 1500)
        #expect(try await Self.convert(Converters.audio, #"{"file_key":"a1","duration":1000}"#).content == #"<audio key="a1" duration="1s"/>"#)
    }

    @Test func videoIncludesNameAndDuration() async throws {
        let r = try await Self.convert(Converters.video, #"{"file_key":"v1","file_name":"clip.mp4","duration":30000}"#)
        #expect(r.content == #"<video key="v1" name="clip.mp4" duration="30s"/>"#)
    }

    @Test func stickerLocationShare() async throws {
        #expect(try await Self.convert(Converters.sticker, #"{"file_key":"s1"}"#).content == #"<sticker key="s1"/>"#)
        #expect(
            try await Self.convert(Converters.location, #"{"name":"Cafe","latitude":"39.9","longitude":"116.4"}"#).content
                == #"<location name="Cafe" coords="lat:39.9,lng:116.4"/>"#)
        #expect(try await Self.convert(Converters.shareChat, #"{"chat_id":"oc_abc"}"#).content == #"<group_card id="oc_abc"/>"#)
        #expect(try await Self.convert(Converters.shareUser, #"{"user_id":"ou_bob"}"#).content == #"<contact_card id="ou_bob"/>"#)
    }

    @Test func fallbackConverter() async throws {
        #expect(try await Self.convert(Converters.unknown, #"{"text":"fallback body"}"#).content == "fallback body")
        #expect(try await Self.convert(Converters.unknown, #"{"random":"data"}"#).content == "[unsupported message]")
        #expect(try await Self.convert(Converters.unknown, "not-json").content == "[unsupported message]")
    }

    // MARK: converters.test.ts — post

    @Test func postTitleAndParagraph() async throws {
        let raw = #"{"zh_cn":{"title":"Hello","content":[[{"tag":"text","text":"world"}]]}}"#
        let r = try await Self.convert(Converters.post, raw)
        #expect(r.content.contains("**Hello**"))
        #expect(r.content.contains("world"))
    }

    @Test func postInlineImageAddsResource() async throws {
        let r = try await Self.convert(Converters.post, #"{"zh_cn":{"content":[[{"tag":"img","image_key":"img_1"}]]}}"#)
        #expect(r.content.contains("![image](img_1)"))
        #expect(r.resources.contains(ResourceDescriptor(type: .image, fileKey: "img_1")))
    }

    @Test func postAtUsesPlaceholderKeyWhenReverseLookupHits() async throws {
        var byOpenId = MentionMap()
        byOpenId.set("ou_alice", MentionInfo(key: "@_user_1", openId: "ou_alice", name: "Alice"))
        let ctx = ConvertContext(messageId: "om_x", mentionsByOpenId: byOpenId)
        let r = try await Self.convert(Converters.post, #"{"zh_cn":{"content":[[{"tag":"at","user_id":"ou_alice","user_name":"Alice"}]]}}"#, ctx)
        #expect(r.content.contains("@_user_1"))
    }

    @Test func postLinkAndStyle() async throws {
        #expect(
            try await Self.convert(Converters.post, #"{"zh_cn":{"content":[[{"tag":"a","text":"click","href":"https://x.com"}]]}}"#).content
                .contains("[click](https://x.com)"))
        #expect(
            try await Self.convert(Converters.post, #"{"zh_cn":{"content":[[{"tag":"text","text":"strong","style":["bold"]}]]}}"#).content
                .contains("**strong**"))
        #expect(try await Self.convert(Converters.post, "not json").content == "[rich text message]")
    }

    // MARK: vectors — every converter against node-sdk output

    static func expectedResources(_ v: JSONValue) -> [ResourceDescriptor] {
        v.array.map { r in
            ResourceDescriptor(
                type: ResourceDescriptor.Kind(rawValue: r["type"]!.string!)!, fileKey: r["fileKey"]!.string!,
                fileName: r["fileName"]?.string, durationMs: { if case .number(let n)? = r["durationMs"] { return Int(n) } else { return nil } }(),
                coverImageKey: r["coverImageKey"]?.string)
        }
    }

    @Test func convertersMatchNodeVectors() async throws {
        let cases = Vectors["converters"].array
        #expect(cases.count > 60)
        for c in cases {
            let type = c["type"]!.string!
            let raw = c["raw"]!.string!
            let r = await Converters.dispatch(raw, type, ConvertContext(messageId: "om_x", dispatch: Converters.dispatch))
            // node may return a non-string `content` (e.g. `{"text":42}`); Swift renders it with `String()`.
            #expect(r.content == JS.interpolate(OrderedJSON(c["content"]!)), "\(type) \(raw)")
            #expect(r.resources == Self.expectedResources(c["resources"]!), "\(type) \(raw)")
        }
    }

    // MARK: event-normalizers.test.ts

    @Test func cardActionNestedContext() throws {
        let r = try #require(
            normalizeCardAction([
                "context": ["open_message_id": "om_1", "open_chat_id": "oc_1"],
                "operator": ["open_id": "ou_alice", "union_id": "on_a"],
                "action": ["value": ["action": "approve"], "tag": "button"],
            ]))
        #expect(r.messageId == "om_1")
        #expect(r.chatId == "oc_1")
        #expect(r.operator.openId == "ou_alice")
        #expect(r.action.tag == "button")
    }

    @Test func cardActionLegacyTopLevelAndPrecedence() throws {
        let legacy = try #require(
            normalizeCardAction([
                "open_message_id": "om_1", "open_chat_id": "oc_1",
                "operator": ["open_id": "ou_alice", "user_id": "u_a", "name": "Alice"],
                "action": ["value": ["foo": 1], "tag": "button", "name": "approve"],
            ]))
        #expect(legacy.messageId == "om_1")
        #expect(legacy.operator.name == "Alice")
        let both = try #require(
            normalizeCardAction([
                "open_message_id": "om_top", "open_chat_id": "oc_top",
                "context": ["open_message_id": "om_ctx", "open_chat_id": "oc_ctx"],
                "operator": ["open_id": "ou_alice"], "action": ["tag": "button"],
            ]))
        #expect(both.messageId == "om_ctx")
        #expect(both.chatId == "oc_ctx")
    }

    @Test func cardActionRequiredFieldsDefaultTagAndRaw() throws {
        #expect(normalizeCardAction(["open_message_id": "om_1"]) == nil)
        #expect(normalizeCardAction(["context": ["open_message_id": "om_1"]]) == nil)
        #expect(normalizeCardAction([:]) == nil)
        let ev: JSONValue = ["context": ["open_message_id": "om_1", "open_chat_id": "oc_1"], "operator": ["open_id": "ou_alice"], "action": [:]]
        #expect(normalizeCardAction(ev)?.action.tag == "unknown")
        #expect(normalizeCardAction(ev)?.raw == JSONValue?.none)
        #expect(normalizeCardAction(ev, includeRaw: false)?.raw == JSONValue?.none)
        #expect(normalizeCardAction(ev, includeRaw: true)?.raw == ev)
    }

    @Test func reactionNormalizer() throws {
        let r = try #require(
            normalizeReaction(
                ["message_id": "om_1", "reaction_type": ["emoji_type": "OK"], "user_id": ["open_id": "ou_alice", "user_id": nil],
                 "action_time": "1000000000000"], action: .added))
        #expect(r.action == .added)
        #expect(r.emojiType == "OK")
        #expect(r.actionTime == 1_000_000_000_000)
        #expect(r.operator.userId == nil)
        let removed = normalizeReaction(["message_id": "om_1", "reaction_type": ["emoji_type": "LIKE"], "user_id": ["open_id": "ou_alice"]], action: .removed)
        #expect(removed?.action == .removed)
        #expect(normalizeReaction(["message_id": "om_1", "reaction_type": ["emoji_type": "OK"]], action: .added) == nil)
        #expect(normalizeReaction(["message_id": "om_1", "user_id": ["open_id": "ou_a"]], action: .added) == nil)
        let ev: JSONValue = ["message_id": "om_1", "reaction_type": ["emoji_type": "OK"], "user_id": ["open_id": "ou_a"]]
        #expect(normalizeReaction(ev, action: .added, includeRaw: true)?.raw == ev)
        #expect(normalizeReaction(ev, action: .added)?.raw == JSONValue?.none)
    }

    @Test func botAddedNormalizer() {
        #expect(normalizeBotAdded(["chat_id": "oc_new", "operator_id": ["open_id": "ou_alice"], "i18n_names": ["zh_cn": "测试bot", "en_us": "TestBot"]])?.botName == "测试bot")
        #expect(normalizeBotAdded(["chat_id": "oc_new", "operator_id": ["open_id": "ou_alice"], "i18n_names": ["en_us": "English Only"]])?.botName == "English Only")
        #expect(normalizeBotAdded(["chat_id": "oc_new", "operator_id": ["open_id": "ou_alice"], "name": "Top Level", "i18n_names": ["zh_cn": "不用这个"]])?.botName == "Top Level")
        #expect(normalizeBotAdded(["chat_id": "oc_new", "operator_id": ["open_id": "ou_alice", "user_id": nil], "name": "Bot"])?.operator.userId == nil)
        #expect(normalizeBotAdded(["operator_id": ["open_id": "ou_x"]]) == nil)
    }

    @Test func commentNormalizer() throws {
        let nested = try #require(
            normalizeComment([
                "file_token": "docx_xyz", "file_type": "docx", "comment_id": "cmt_1",
                "notice_meta": ["from_user_id": ["open_id": "ou_alice", "user_id": "u_a"], "timestamp": "1700000000000", "is_mentioned": true],
            ]))
        #expect(nested.fileToken == "docx_xyz")
        #expect(nested.mentionedBot)
        #expect(nested.timestamp == 1_700_000_000_000)
        #expect(nested.operator.openId == "ou_alice")

        let fallback = try #require(
            normalizeComment([
                "file_token": "docx_xyz", "file_type": "docx", "comment_id": "cmt_1", "user_id": ["open_id": "ou_alice"],
                "action_time": "1700000000000", "is_mention": false,
            ]))
        #expect(!fallback.mentionedBot)
        #expect(fallback.operator.openId == "ou_alice")

        #expect(normalizeComment(["file_type": "docx", "comment_id": "cmt_1", "notice_meta": ["from_user_id": ["open_id": "ou_x"]]]) == nil)
        #expect(
            normalizeComment([
                "file_token": "docx_xyz", "file_type": "docx", "comment_id": "cmt_1", "reply_id": "reply_1",
                "notice_meta": ["from_user_id": ["open_id": "ou_x"]],
            ])?.replyId == "reply_1")

        let real = try #require(
            normalizeComment([
                "comment_id": "7631464082675076055", "is_mentioned": true, "create_time": "1776838695000",
                "notice_meta": [
                    "file_token": "UQmCd8FQlo3pDOxZVVrc5eNVnpf", "file_type": "docx",
                    "from_user_id": ["open_id": "ou_alice", "union_id": "on_alice", "user_id": nil], "notice_type": "add_comment",
                ],
                "reply_id": "7631464082695392217",
            ]))
        #expect(real.fileToken == "UQmCd8FQlo3pDOxZVVrc5eNVnpf")
        #expect(real.fileType == "docx")
        #expect(real.mentionedBot)
        #expect(real.timestamp == 1_776_838_695_000)
        #expect(real.operator.userId == nil)
        #expect(real.operator.unionId == "on_alice")
        #expect(real.replyId == "7631464082695392217")

        let before = Int(Date().timeIntervalSince1970 * 1000)
        let noTime = try #require(
            normalizeComment(["file_token": "f", "file_type": "doc", "comment_id": "c", "user_id": ["open_id": "ou"]]))
        #expect(noTime.timestamp >= before)
    }

    @Test func eventNormalizersMatchNodeVectors() {
        let v = Vectors["eventNormalizers"]
        for pair in v["cardAction"]!.array {
            let r = normalizeCardAction(pair[0]!)
            let e = pair[1]!
            if e.isNull { #expect(r == nil); continue }
            #expect(r?.messageId == e["messageId"]?.string)
            #expect(r?.chatId == e["chatId"]?.string)
            #expect(r?.operator.openId == e["operator"]?["openId"]?.string)
            #expect(r?.operator.userId == e["operator"]?["userId"]?.string)
            #expect(r?.operator.name == e["operator"]?["name"]?.string)
            #expect(r?.action.tag == e["action"]?["tag"]?.string)
            #expect(r?.action.value == e["action"]?["value"])
            #expect(r?.action.name == e["action"]?["name"]?.string)
            #expect(r?.action.option == e["action"]?["option"]?.string)
        }
        for pair in v["reaction"]!.array {
            let r = normalizeReaction(pair[0]!, action: .added)
            let e = pair[1]!
            if e.isNull { #expect(r == nil); continue }
            #expect(r?.messageId == e["messageId"]?.string)
            #expect(r?.operator.userId == e["operator"]?["userId"]?.string)
            #expect(r?.actionTime == e["actionTime"]?.intValue)
        }
        for pair in v["botAdded"]!.array {
            let r = normalizeBotAdded(pair[0]!)
            let e = pair[1]!
            if e.isNull { #expect(r == nil); continue }
            #expect(r?.botName == e["botName"]?.string)
            #expect(r?.external == e["external"]?.boolValue)
            #expect(r?.operator.userId == e["operator"]?["userId"]?.string)
        }
        for pair in v["comment"]!.array {
            let r = normalizeComment(pair[0]!)
            let e = pair[1]!
            #expect(r?.fileToken == e["fileToken"]?.string)
            #expect(r?.fileType == e["fileType"]?.string)
            #expect(r?.mentionedBot == e["mentionedBot"]?.boolValue)
            #expect(r?.timestamp == e["timestamp"]?.intValue)
            #expect(r?.operator.openId == e["operator"]?["openId"]?.string)
            #expect(r?.operator.userId == e["operator"]?["userId"]?.string)
            #expect(r?.operator.unionId == e["operator"]?["unionId"]?.string)
        }
    }

    // MARK: mentions.test.ts

    static func mention(_ key: String, _ openId: String?, _ name: String?) -> OrderedJSON {
        var id = OrderedJSON.object([])
        if let openId { id["open_id"] = .string(openId) }
        var m = OrderedJSON.obj(["key": .string(key), "id": id])
        if let name { m["name"] = .string(name) }
        return m
    }

    @Test func extractMentions() {
        let empty = Mentions.extract(nil, botOpenId: "ou_bot")
        #expect(empty.mentionList.isEmpty && !empty.mentionAll && !empty.mentionedBot)

        let single = Mentions.extract([Self.mention("@_user_1", "ou_alice", "Alice")], botOpenId: "ou_bot")
        #expect(single.mentionList == [MentionInfo(key: "@_user_1", openId: "ou_alice", name: "Alice", isBot: false)])
        #expect(single.mentionsByOpenId.get("ou_alice") != nil)

        let bot = Mentions.extract([Self.mention("@_bot", "ou_bot", "Bot")], botOpenId: "ou_bot")
        #expect(bot.mentionedBot)
        #expect(bot.mentionList[0].isBot)

        let all = Mentions.extract([Self.mention("@_all", nil, "所有人")], botOpenId: "ou_bot")
        #expect(all.mentionAll)
        #expect(all.mentionList.isEmpty)
        #expect(all.mentions.has("@_all"))

        let mixed = Mentions.extract(
            [Self.mention("@_user_1", "ou_alice", "Alice"), Self.mention("@_bot", "ou_bot", "Bot"), Self.mention("@_all", nil, "所有人")],
            botOpenId: "ou_bot")
        #expect(mixed.mentionAll && mixed.mentionedBot)
        #expect(mixed.mentionList.count == 2)
    }

    static func map(_ entries: [(String, MentionInfo)]) -> MentionMap { MentionMap(entries) }

    @Test func resolveMentions() {
        let alice = Self.map([("@_user_1", MentionInfo(key: "@_user_1", openId: "ou_alice", name: "Alice"))])
        #expect(Mentions.resolve("hello @_user_1", mentions: alice, stripBotMentions: true) == "hello @Alice")
        let bot = Self.map([("@_bot", MentionInfo(key: "@_bot", openId: "ou_bot", name: "Bot", isBot: true))])
        #expect(Mentions.resolve("@_bot help me", mentions: bot, stripBotMentions: true) == "help me")
        #expect(Mentions.resolve("@_bot help me", mentions: bot, stripBotMentions: false) == "@Bot help me")
        let two = Self.map([
            ("@_user_1", MentionInfo(key: "@_user_1", openId: "ou_a", name: "A")), ("@_user_2", MentionInfo(key: "@_user_2", openId: "ou_b", name: "B")),
        ])
        #expect(Mentions.resolve("@_user_1 and @_user_2", mentions: two, stripBotMentions: true) == "@A and @B")
        #expect(Mentions.resolve("hello", mentions: MentionMap(), stripBotMentions: true) == "hello")
    }

    @Test func resolveMentionsMatchesNodeVectors() {
        for c in Vectors["resolveMentions"].array {
            let entries = c[1]!.array.map { e -> (String, MentionInfo) in
                let i = e[1]!
                return (e[0]!.string!, MentionInfo(key: i["key"]!.string!, openId: i["openId"]?.string, name: i["name"]?.string, isBot: i["isBot"]?.boolValue ?? false))
            }
            let out = Mentions.resolve(c[0]!.string!, mentions: MentionMap(entries), stripBotMentions: c[2]!.boolValue!)
            #expect(out == c[3]!.string!, "\(c[0]!)")
        }
    }

    // MARK: merge-forward.test.ts

    static func fakeDispatch(_ raw: String, _ type: String, _ ctx: ConvertContext) async -> ConvertResult {
        if type == "text" {
            return ConvertResult(content: (try? JSONValue(jsonString: raw))?["text"]?.stringValue ?? "", resources: [])
        }
        return ConvertResult(content: "[\(type)]", resources: [])
    }

    static func forwardCtx(_ items: [ApiMessageItem], resolve: (@Sendable (String) -> String?)? = nil) -> ConvertContext {
        ConvertContext(messageId: "om_root", fetchSubMessages: { _ in items }, resolveUserName: resolve, dispatch: fakeDispatch)
    }

    @Test func mergeForwardWithoutFetcher() async throws {
        #expect(try await MergeForward.convert("{}", ConvertContext(messageId: "om_root")).content == "<forwarded_messages/>")
    }

    @Test func mergeForwardRealShape() async throws {
        let items = [
            ApiMessageItem(messageId: "om_root", msgType: "merge_forward", content: "Merged and Forwarded Message", senderId: "ou_forwarder", createTime: "1776849870916"),
            ApiMessageItem(messageId: "om_child_a", upperMessageId: "om_root", msgType: "text", content: #"{"text":"first child"}"#, senderId: "ou_alice", createTime: "1776753549563"),
            ApiMessageItem(messageId: "om_child_b", upperMessageId: "om_root", msgType: "text", content: #"{"text":"second child"}"#, senderId: "ou_bob", createTime: "1776753669281"),
        ]
        let r = try await MergeForward.convert("{}", Self.forwardCtx(items))
        #expect(r.content.hasPrefix("<forwarded_messages>"))
        #expect(!r.content.contains("Merged and Forwarded Message"))
        let a = try #require(r.content.range(of: "first child")), b = try #require(r.content.range(of: "second child"))
        #expect(a.lowerBound < b.lowerBound)
    }

    @Test func mergeForwardSingleLevelIndent() async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let items = [
            ApiMessageItem(messageId: "om_1", msgType: "text", content: #"{"text":"hello"}"#, senderId: "ou_alice", createTime: String(now)),
            ApiMessageItem(messageId: "om_2", msgType: "text", content: #"{"text":"world"}"#, senderId: "ou_bob", createTime: String(now + 1000)),
        ]
        let r = try await MergeForward.convert("{}", Self.forwardCtx(items))
        #expect(r.content.hasPrefix("<forwarded_messages>"))
        #expect(r.content.hasSuffix("</forwarded_messages>"))
        #expect(r.content.contains("    hello"))
        #expect(r.content.contains("world"))
    }

    @Test func mergeForwardNested() async throws {
        let items = [
            ApiMessageItem(messageId: "om_outer", msgType: "merge_forward", content: "{}", senderId: "ou_alice", createTime: "1000"),
            ApiMessageItem(messageId: "om_inner", upperMessageId: "om_outer", msgType: "text", content: #"{"text":"inner"}"#, senderId: "ou_bob", createTime: "2000"),
        ]
        let r = try await MergeForward.convert("{}", Self.forwardCtx(items))
        #expect(r.content.contains("inner"))
        #expect(r.content.components(separatedBy: "<forwarded_messages>").count - 1 >= 2)
    }

    @Test func mergeForwardFetchFailureAndResolver() async throws {
        struct Fail: Error {}
        let failing = ConvertContext(messageId: "om_root", fetchSubMessages: { _ in throw Fail() }, dispatch: Self.fakeDispatch)
        #expect(try await MergeForward.convert("{}", failing).content == "<forwarded_messages/>")
        let items = [ApiMessageItem(messageId: "om_1", msgType: "text", content: #"{"text":"hi"}"#, senderId: "ou_alice", createTime: "1000")]
        let r = try await MergeForward.convert("{}", Self.forwardCtx(items) { $0 == "ou_alice" ? "Alice" : nil })
        #expect(r.content.contains("Alice:"))
    }

    @Test func mergeForwardTruncatesAt50AndBatchResolves() async throws {
        let items = (0..<55).map { i in
            ApiMessageItem(messageId: "om_\(i)", msgType: "text", content: #"{"text":"m\#(i)"}"#, senderId: "ou_\(i % 3)", createTime: String(1000 + i))
        }
        let batches = Recorder<[String]>()
        var ctx = Self.forwardCtx(items)
        ctx.batchResolveNames = { batches.append($0) }
        let r = try await MergeForward.convert("{}", ctx)
        #expect(r.content.hasSuffix("m49\n... (truncated)\n</forwarded_messages>"))
        #expect(!r.content.contains("m50"))
        #expect(batches.items == [["ou_0", "ou_1", "ou_2"]])
    }

    // MARK: normalize.test.ts

    static let bot = BotIdentity(openId: "ou_bot", name: "TestBot")

    static func event(_ overrides: [String: JSONValue] = [:], sender: JSONValue = ["sender_id": ["open_id": "ou_alice", "user_id": "u_alice"]]) -> JSONValue {
        var message: [String: JSONValue] = [
            "message_id": "om_x", "chat_id": "oc_test", "chat_type": "group", "message_type": "text", "content": #"{"text":"hello"}"#,
            "create_time": .string(String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        for (k, v) in overrides { message[k] = v }
        return ["sender": sender, "message": .object(message)]
    }

    @Test func normalizeBasicText() async throws {
        let msg = try await normalize(Self.event(), options: .init(botIdentity: Self.bot))
        #expect(msg.messageId == "om_x")
        #expect(msg.chatId == "oc_test")
        #expect(msg.chatType == .group)
        #expect(msg.senderId == "ou_alice")
        #expect(msg.content == "hello")
        #expect(msg.rawContentType == "text")
        #expect(!msg.mentionedBot && !msg.mentionAll)
    }

    @Test func normalizeFallbackSenderAndMentions() async throws {
        let fb = try await normalize(Self.event(sender: ["sender_id": ["user_id": "u_alice"]]), options: .init(botIdentity: Self.bot))
        #expect(fb.senderId == "u_alice")

        let m = try await normalize(
            Self.event(["content": #"{"text":"@_user_1 please"}"#, "mentions": [["key": "@_user_1", "id": ["open_id": "ou_bob"], "name": "Bob"]]]),
            options: .init(botIdentity: Self.bot))
        #expect(m.content == "@Bob please")
        #expect(m.mentions.count == 1)
        #expect(m.mentions[0].openId == "ou_bob")

        let b = try await normalize(
            Self.event(["content": #"{"text":"@_bot help me"}"#, "mentions": [["key": "@_bot", "id": ["open_id": "ou_bot"], "name": "TestBot"]]]),
            options: .init(botIdentity: Self.bot))
        #expect(b.mentionedBot)
        #expect(b.content == "help me")
    }

    @Test func normalizeMentionAllDetection() async throws {
        let opts = NormalizeOptions(botIdentity: Self.bot)
        #expect(try await normalize(Self.event(["content": #"{"text":"@_all listen up"}"#, "mentions": [["key": "@_all", "id": [:], "name": "所有人"]]]), options: opts).mentionAll)
        #expect(try await normalize(Self.event(["content": #"{"text":"@_all  hello everyone"}"#]), options: opts).mentionAll)
        #expect(!(try await normalize(Self.event(["content": #"{"text":"@_allies are with us"}"#]), options: opts).mentionAll))
        let post = #"{"zh_cn":{"title":"","content":[[{"tag":"text","text":"@_all meeting now"}]]}}"#
        #expect(try await normalize(Self.event(["message_type": "post", "content": .string(post)]), options: opts).mentionAll)
    }

    @Test func normalizeResourcesFallbackRawAndIds() async throws {
        let opts = NormalizeOptions(botIdentity: Self.bot)
        let img = try await normalize(Self.event(["message_type": "image", "content": #"{"image_key":"img_v3_xyz"}"#]), options: opts)
        #expect(img.content == "![image](img_v3_xyz)")
        #expect(img.resources == [ResourceDescriptor(type: .image, fileKey: "img_v3_xyz")])

        let post = #"{"zh_cn":{"title":"Greeting","content":[[{"tag":"text","text":"hi "},{"tag":"at","user_id":"ou_bob","user_name":"Bob"}],[{"tag":"img","image_key":"img_1"}]]}}"#
        let p = try await normalize(
            Self.event(["message_type": "post", "content": .string(post), "mentions": [["key": "@_user_1", "id": ["open_id": "ou_bob"], "name": "Bob"]]]),
            options: opts)
        #expect(p.content.contains("**Greeting**") && p.content.contains("@Bob") && p.content.contains("![image](img_1)"))
        #expect(p.resources.contains(ResourceDescriptor(type: .image, fileKey: "img_1")))

        let unknown = try await normalize(Self.event(["message_type": "something_new", "content": #"{"text":"sort of"}"#]), options: opts)
        #expect(unknown.content == "sort of")
        #expect(unknown.rawContentType == "something_new")
        #expect(try await normalize(Self.event(["message_type": "post", "content": "not valid json"]), options: opts).content == "[rich text message]")

        let ev = Self.event()
        #expect(try await normalize(ev, options: .init(botIdentity: Self.bot, includeRaw: true)).raw == ev)

        let card = #"{"elements":[{"tag":"markdown","content":"visible body"}]}"#
        #expect(try await normalize(Self.event(["message_type": "interactive", "content": .string(card)]), options: opts).content.contains("visible body"))

        let t = try await normalize(Self.event(["root_id": "om_root", "parent_id": "om_parent", "thread_id": "omt_1"]), options: opts)
        #expect(t.rootId == "om_root" && t.replyToMessageId == "om_parent" && t.threadId == "omt_1")

        let named = try await normalize(Self.event(), options: .init(botIdentity: Self.bot, resolveSenderName: { $0 == "ou_alice" ? "Alice" : nil }))
        #expect(named.senderName == "Alice")
    }

    @Test func normalizeMatchesNodeVectors() async throws {
        let forwardItems = Vectors["forwardItems"].array.map(ApiMessageItem.init(json:))
        for c in Vectors["normalize"].array {
            let name = c["name"]!.string!
            let o = c["options"]!
            var opts = NormalizeOptions(botIdentity: Self.bot)
            if o["stripBotMentions"] == false { opts.stripBotMentions = false }
            if o["forward"] == true {
                opts.fetchSubMessages = { _ in forwardItems }
                opts.resolveUserName = { $0 == "ou_alice" ? "Alice" : nil }
            }
            if o["senderName"] == true { opts.resolveSenderName = { $0 == "ou_alice" ? "Alice" : nil } }
            let m = try await normalize(c["event"]!, options: opts)
            let e = c["result"]!
            #expect(m.messageId == e["messageId"]!.string!, "\(name)")
            #expect(m.chatId == e["chatId"]!.string!, "\(name)")
            #expect(m.chatType.rawValue == e["chatType"]!.string!, "\(name)")
            #expect(m.senderId == e["senderId"]!.string!, "\(name)")
            #expect(m.senderName == e["senderName"]?.string, "\(name)")
            #expect(m.content == e["content"]!.string!, "\(name)")
            #expect(m.rawContentType == e["rawContentType"]!.string!, "\(name)")
            #expect(m.resources == Self.expectedResources(e["resources"]!), "\(name)")
            #expect(m.mentionAll == e["mentionAll"]!.boolValue!, "\(name)")
            #expect(m.mentionedBot == e["mentionedBot"]!.boolValue!, "\(name)")
            #expect(m.rootId == e["rootId"]?.string && m.threadId == e["threadId"]?.string, "\(name)")
            #expect(m.replyToMessageId == e["replyToMessageId"]?.string, "\(name)")
            #expect(m.createTime == e["createTime"]!.intValue!, "\(name)")
            let mentions = e["mentions"]!.array.map {
                MentionInfo(key: $0["key"]!.string!, openId: $0["openId"]?.string, userId: $0["userId"]?.string, name: $0["name"]?.string, isBot: $0["isBot"]!.boolValue!)
            }
            #expect(m.mentions == mentions, "\(name)")
        }
    }

    @Test func normalizeRejectsPayloadWithoutMessage() async {
        await #expect(throws: LarkChannelError.self) { try await normalize(["sender": [:]], options: .init(botIdentity: Self.bot)) }
        await #expect(throws: LarkChannelError.self) {
            try await normalize(["message": ["message_id": "om", "content": "{}", "message_type": "text"]], options: .init(botIdentity: Self.bot))
        }
    }

    // MARK: utils

    @Test func utilsMatchNodeVectors() {
        for p in Vectors["formatDuration"].array {
            #expect(NormalizeUtils.formatDuration(p[0]!.doubleValue) == p[1]?.string, "\(p[0]!)")
        }
        for p in Vectors["millisToDatetime"].array {
            #expect(NormalizeUtils.millisToDatetime(OrderedJSON(p[0]!)) == p[1]?.string, "\(p[0]!)")
        }
        for p in Vectors["rfc3339"].array {
            #expect(NormalizeUtils.formatRFC3339Beijing(p[0]!.doubleValue!) == p[1]!.string!)
        }
        #expect(NormalizeUtils.escapeAttr(#"a "b""#) == "a &quot;b&quot;")
        #expect(NormalizeUtils.indentLines("a\n\nb", "  ") == "  a\n  \n  b")
        #expect(NormalizeUtils.applyStyle("x", ["code", "strikethrough"]) == "`~~x~~`")
    }

    @Test func orderedJSONRoundTripsLikeJSON() throws {
        let raw = #"{"b":1,"a":[true,null,"é\n\"x\"",1.5,-0,1e21,1e-7,123456789012],"b":2,"c":{}}"#
        let v = try #require(OrderedJSON.parse(raw))
        #expect(v.keys == ["b", "a", "c"])  // duplicate key keeps its first position, last value
        #expect(v.stringify() == #"{"b":2,"a":[true,null,"é\n\"x\"",1.5,0,1e+21,1e-7,123456789012],"c":{}}"#)
        #expect(OrderedJSON.parse("{") == nil)
        #expect(OrderedJSON.parse("01") == nil)
        var quoted = ""
        OrderedJSON.quote("\u{1}\u{8}\t", into: &quoted)
        #expect(quoted == #""\u0001\b\t""#)
    }
}
