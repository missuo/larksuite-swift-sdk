import Foundation
import LarkCore

/// Raw `im.message.receive_v1` payload (the flattened event object).
public typealias RawMessageEvent = JSONValue
/// Raw `card.action.trigger` payload.
public typealias RawCardActionEvent = JSONValue
/// Raw `im.message.reaction.created_v1` / `deleted_v1` payload.
public typealias RawReactionEvent = JSONValue
/// Raw `im.chat.member.bot.added_v1` payload.
public typealias RawBotAddedEvent = JSONValue
/// Raw `drive.notice.comment_add_v1` payload.
public typealias RawCommentEvent = JSONValue

/// One item of `im.v1.message.get` `data.items` (used to expand merge-forwards).
public struct ApiMessageItem: Sendable, Equatable {
    public var messageId: String?
    public var upperMessageId: String?
    public var msgType: String?
    /// `body.content`.
    public var content: String?
    public var senderId: String?
    public var senderIdType: String?
    public var senderType: String?
    /// `create_time` exactly as received (string or number, rendered with JS `String()`).
    public var createTime: String?

    public init(
        messageId: String? = nil, upperMessageId: String? = nil, msgType: String? = nil, content: String? = nil,
        senderId: String? = nil, senderIdType: String? = nil, senderType: String? = nil, createTime: String? = nil
    ) {
        self.messageId = messageId
        self.upperMessageId = upperMessageId
        self.msgType = msgType
        self.content = content
        self.senderId = senderId
        self.senderIdType = senderIdType
        self.senderType = senderType
        self.createTime = createTime
    }

    /// Reads an item from the raw API JSON.
    public init(json: JSONValue) {
        let o = OrderedJSON(json)
        self.init(
            messageId: JS.optionalString(o["message_id"]),
            upperMessageId: JS.optionalString(o["upper_message_id"]),
            msgType: JS.optionalString(o["msg_type"]),
            content: JS.optionalString(o[path: "body", "content"]),
            senderId: JS.optionalString(o[path: "sender", "id"]),
            senderIdType: JS.optionalString(o[path: "sender", "id_type"]),
            senderType: JS.optionalString(o[path: "sender", "sender_type"]),
            createTime: JS.optionalString(o["create_time"]))
    }
}

/// Mentions keyed by placeholder, iterated in insertion order (a JS `Map`).
struct MentionMap: Sendable {
    private(set) var keys: [String] = []
    private var values: [String: MentionInfo] = [:]

    init() {}

    init(_ entries: [(String, MentionInfo)]) {
        for (k, v) in entries { set(k, v) }
    }

    mutating func set(_ key: String, _ info: MentionInfo) {
        if values[key] == nil { keys.append(key) }
        values[key] = info
    }

    func get(_ key: String) -> MentionInfo? { values[key] }
    func has(_ key: String) -> Bool { values[key] != nil }
    var count: Int { keys.count }
    var entries: [(String, MentionInfo)] { keys.map { ($0, values[$0]!) } }
}

/// Output of a content converter.
struct ConvertResult: Sendable, Equatable {
    var content: String
    var resources: [ResourceDescriptor]
}

typealias ContentConverter = @Sendable (String, ConvertContext) async throws -> ConvertResult

/// Capabilities and state shared by the converters of one message.
struct ConvertContext: Sendable {
    var messageId: String
    var botOpenId: String?
    var mentions: MentionMap
    var mentionsByOpenId: MentionMap
    var stripBotMentions: Bool
    var fetchSubMessages: (@Sendable (String) async throws -> [ApiMessageItem])?
    var resolveUserName: (@Sendable (String) -> String?)?
    var batchResolveNames: (@Sendable ([String]) async throws -> Void)?
    var dispatch: (@Sendable (String, String, ConvertContext) async -> ConvertResult)?

    init(
        messageId: String, botOpenId: String? = nil, mentions: MentionMap = MentionMap(),
        mentionsByOpenId: MentionMap = MentionMap(), stripBotMentions: Bool = true,
        fetchSubMessages: (@Sendable (String) async throws -> [ApiMessageItem])? = nil,
        resolveUserName: (@Sendable (String) -> String?)? = nil,
        batchResolveNames: (@Sendable ([String]) async throws -> Void)? = nil,
        dispatch: (@Sendable (String, String, ConvertContext) async -> ConvertResult)? = nil
    ) {
        self.messageId = messageId
        self.botOpenId = botOpenId
        self.mentions = mentions
        self.mentionsByOpenId = mentionsByOpenId
        self.stripBotMentions = stripBotMentions
        self.fetchSubMessages = fetchSubMessages
        self.resolveUserName = resolveUserName
        self.batchResolveNames = batchResolveNames
        self.dispatch = dispatch
    }
}
