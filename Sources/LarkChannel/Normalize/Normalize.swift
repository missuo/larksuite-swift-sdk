import Foundation
import LarkCore

/// Options for ``normalize(_:options:)`` (node-sdk `NormalizeOptions`).
public struct NormalizeOptions: Sendable {
    public var botIdentity: BotIdentity?
    /// Remove `@bot` placeholders from the content (default true).
    public var stripBotMentions: Bool
    /// Attach the raw payload as ``NormalizedMessage/raw``.
    public var includeRaw: Bool
    /// Expands merge-forwarded messages (`im.v1.message.get` items).
    public var fetchSubMessages: (@Sendable (String) async throws -> [ApiMessageItem])?
    /// Display names for merge-forward senders.
    public var resolveUserName: (@Sendable (String) -> String?)?
    /// Fills ``NormalizedMessage/senderName``.
    public var resolveSenderName: (@Sendable (String) -> String?)?
    /// Pre-warms a name cache for merge-forward senders.
    public var batchResolveNames: (@Sendable ([String]) async throws -> Void)?

    public init(
        botIdentity: BotIdentity?,
        stripBotMentions: Bool = true,
        includeRaw: Bool = false,
        fetchSubMessages: (@Sendable (String) async throws -> [ApiMessageItem])? = nil,
        resolveUserName: (@Sendable (String) -> String?)? = nil,
        resolveSenderName: (@Sendable (String) -> String?)? = nil,
        batchResolveNames: (@Sendable ([String]) async throws -> Void)? = nil
    ) {
        self.botIdentity = botIdentity
        self.stripBotMentions = stripBotMentions
        self.includeRaw = includeRaw
        self.fetchSubMessages = fetchSubMessages
        self.resolveUserName = resolveUserName
        self.resolveSenderName = resolveSenderName
        self.batchResolveNames = batchResolveNames
    }
}

/// Normalizes a raw `im.message.receive_v1` payload (node-sdk `normalize`).
///
/// Pipeline: extract mentions → dispatch to the content converter for the
/// `message_type` (errors fall back to a generic converter) → resolve mention
/// placeholders → assemble the message.
///
/// - Throws: ``LarkChannelError`` (`unknown`) when the payload has no
///   `message` / `sender.sender_id` object (node-sdk throws a `TypeError`).
public func normalize(_ event: RawMessageEvent, options: NormalizeOptions) async throws -> NormalizedMessage {
    let ev = OrderedJSON(event)
    guard let msg = ev["message"], msg.isObject else {
        throw LarkChannelError(.unknown, "Cannot read properties of undefined (reading 'mentions')")
    }
    let botOpenId = options.botIdentity?.openId
    let rawMentions = msg["mentions"]?.arrayValue
    let extraction = Mentions.extract(rawMentions, botOpenId: botOpenId)
    let rawContent = msg["content"]?.stringValue ?? ""

    // Feishu often omits `mentions` for @所有人 while `@_all` stays in the content.
    let mentionAll = extraction.mentionAll || detectMentionAllInContent(msg["content"]?.stringValue)

    let messageId = JS.string(msg["message_id"], default: "")
    let ctx = ConvertContext(
        messageId: messageId,
        botOpenId: botOpenId,
        mentions: extraction.mentions,
        mentionsByOpenId: extraction.mentionsByOpenId,
        stripBotMentions: options.stripBotMentions,
        fetchSubMessages: options.fetchSubMessages,
        resolveUserName: options.resolveUserName,
        batchResolveNames: options.batchResolveNames,
        dispatch: Converters.dispatch)

    let messageType = JS.string(msg["message_type"], default: "")
    let converted = await Converters.dispatch(rawContent, messageType, ctx)
    let content = Mentions.resolve(converted.content, mentions: ctx.mentions, stripBotMentions: ctx.stripBotMentions)

    guard let senderIds = ev[path: "sender", "sender_id"], senderIds.isObjectLike else {
        throw LarkChannelError(.unknown, "Cannot read properties of undefined (reading 'sender_id')")
    }
    let senderOpenId = JS.optionalString(senderIds["open_id"])
    let fallback = JS.optionalString(senderIds["user_id"]) ?? JS.optionalString(senderIds["union_id"]) ?? ""
    let senderId = senderOpenId ?? fallback
    let senderName = (senderOpenId?.isEmpty == false) ? options.resolveSenderName?(senderOpenId!) : nil

    let createMs: Int
    if JS.truthy(msg["create_time"]) {
        createMs = JS.parseIntValue(JS.interpolate(msg["create_time"])) ?? 0
    } else {
        createMs = 0
    }

    return NormalizedMessage(
        messageId: messageId,
        chatId: JS.string(msg["chat_id"], default: ""),
        chatType: ChatType(rawValue: JS.string(msg["chat_type"], default: "")),
        senderId: senderId,
        senderName: senderName,
        content: content,
        rawContentType: messageType,
        resources: converted.resources,
        mentions: extraction.mentionList,
        mentionAll: mentionAll,
        mentionedBot: extraction.mentionedBot,
        rootId: JS.optionalString(msg["root_id"]),
        threadId: JS.optionalString(msg["thread_id"]),
        replyToMessageId: JS.optionalString(msg["parent_id"]),
        createTime: createMs,
        raw: options.includeRaw ? event : JSONValue?.none)
}

private let mentionAllPattern = JS.regex("@_all(?![A-Za-z0-9_])")

/// Detects `@_all` in the serialized content (JS `/@_all\b/`).
func detectMentionAllInContent(_ content: String?) -> Bool {
    guard let content, !content.isEmpty else { return false }
    return JS.test(mentionAllPattern, content)
}

// MARK: - Event normalizers

/// Normalizes a `card.action.trigger` payload; `nil` when required ids are missing.
public func normalizeCardAction(_ event: RawCardActionEvent, includeRaw: Bool = false) -> CardActionEvent? {
    let e = OrderedJSON(event)
    let messageId = JS.optionalString(e[path: "context", "open_message_id"]) ?? JS.optionalString(e["open_message_id"])
    let chatId = JS.optionalString(e[path: "context", "open_chat_id"]) ?? JS.optionalString(e["open_chat_id"])
    let openId = JS.optionalString(e[path: "operator", "open_id"])
    guard let messageId, !messageId.isEmpty, let chatId, !chatId.isEmpty, let openId, !openId.isEmpty else { return nil }
    return CardActionEvent(
        messageId: messageId,
        chatId: chatId,
        operator: .init(
            openId: openId, userId: JS.optionalString(e[path: "operator", "user_id"]),
            name: JS.optionalString(e[path: "operator", "name"])),
        action: .init(
            value: event["action"]?["value"],
            tag: JS.optionalString(e[path: "action", "tag"]) ?? "unknown",
            name: JS.optionalString(e[path: "action", "name"]),
            option: JS.optionalString(e[path: "action", "option"])),
        raw: includeRaw ? event : JSONValue?.none)
}

/// Normalizes an `im.message.reaction.created_v1` / `deleted_v1` payload.
public func normalizeReaction(_ event: RawReactionEvent, action: ReactionAction, includeRaw: Bool = false) -> ReactionEvent? {
    let e = OrderedJSON(event)
    let messageId = JS.optionalString(e["message_id"])
    let emojiType = JS.optionalString(e[path: "reaction_type", "emoji_type"])
    let openId = JS.optionalString(e[path: "user_id", "open_id"])
    guard let messageId, !messageId.isEmpty, let emojiType, !emojiType.isEmpty, let openId, !openId.isEmpty else { return nil }
    var actionTime: Int?
    if JS.truthy(e["action_time"]) { actionTime = JS.parseIntValue(JS.interpolate(e["action_time"])) }
    return ReactionEvent(
        messageId: messageId,
        operator: .init(openId: openId, userId: JS.optionalString(e[path: "user_id", "user_id"])),
        emojiType: emojiType,
        action: action,
        actionTime: actionTime,
        raw: includeRaw ? event : JSONValue?.none)
}

/// Normalizes an `im.chat.member.bot.added_v1` payload.
public func normalizeBotAdded(_ event: RawBotAddedEvent, includeRaw: Bool = false) -> BotAddedEvent? {
    let e = OrderedJSON(event)
    let chatId = JS.optionalString(e["chat_id"])
    let openId = JS.optionalString(e[path: "operator_id", "open_id"])
    guard let chatId, !chatId.isEmpty, let openId, !openId.isEmpty else { return nil }
    let botName =
        JS.optionalString(e["name"]) ?? JS.optionalString(e[path: "i18n_names", "zh_cn"])
        ?? JS.optionalString(e[path: "i18n_names", "en_us"]) ?? JS.optionalString(e[path: "i18n_names", "ja_jp"])
    return BotAddedEvent(
        chatId: chatId,
        operator: .init(openId: openId, userId: JS.optionalString(e[path: "operator_id", "user_id"])),
        botName: botName,
        external: e["external"]?.boolValue,
        raw: includeRaw ? event : JSONValue?.none)
}

/// Normalizes a `drive.notice.comment_add_v1` payload.
public func normalizeComment(_ event: RawCommentEvent, includeRaw: Bool = false) -> CommentEvent? {
    let e = OrderedJSON(event)
    let fileToken = JS.optionalString(e["file_token"]) ?? JS.optionalString(e[path: "notice_meta", "file_token"])
    let fileType = JS.optionalString(e["file_type"]) ?? JS.optionalString(e[path: "notice_meta", "file_type"])
    let commentId = JS.optionalString(e["comment_id"])
    let user = nonNull(e[path: "notice_meta", "from_user_id"]) ?? nonNull(e["user_id"])
    let openId = JS.optionalString(user?["open_id"])
    guard let fileToken, !fileToken.isEmpty, let fileType, !fileType.isEmpty, let commentId, !commentId.isEmpty,
        let openId, !openId.isEmpty
    else { return nil }

    let ts = nonNull(e["create_time"]) ?? nonNull(e[path: "notice_meta", "timestamp"]) ?? nonNull(e["action_time"])
    let now = Int(nowMs())
    var timestamp = now
    if JS.truthy(ts) { timestamp = JS.parseIntValue(JS.interpolate(ts)) ?? now }

    let mentioned = nonNull(e["is_mentioned"]) ?? nonNull(e[path: "notice_meta", "is_mentioned"]) ?? nonNull(e["is_mention"])
    return CommentEvent(
        fileToken: fileToken,
        fileType: fileType,
        commentId: commentId,
        replyId: JS.optionalString(e["reply_id"]),
        operator: .init(openId: openId, userId: JS.optionalString(user?["user_id"]), unionId: JS.optionalString(user?["union_id"])),
        mentionedBot: JS.truthy(mentioned),
        timestamp: timestamp,
        raw: includeRaw ? event : JSONValue?.none)
}

/// `x ?? y` treats `null` as missing.
@inline(__always) func nonNull(_ v: OrderedJSON?) -> OrderedJSON? {
    guard let v, !v.isNull else { return nil }
    return v
}
