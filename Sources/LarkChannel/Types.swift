import Foundation
import LarkCore

// MARK: - Normalized inbound message

/// Chat type of an inbound message (`p2p` or `group`).
///
/// Open string type: unknown values sent by the platform (or returned by
/// ``LarkChannel/getChatInfo(_:)``, e.g. `topic`) are preserved verbatim, like
/// node-sdk which passes the raw string through.
public struct ChatType: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let p2p = ChatType(rawValue: "p2p")
    public static let group = ChatType(rawValue: "group")
}

/// A Feishu message event normalized into a channel-friendly shape
/// (node-sdk `NormalizedMessage`).
public struct NormalizedMessage: Sendable, Equatable {
    public var messageId: String
    public var chatId: String
    public var chatType: ChatType
    public var senderId: String
    public var senderName: String?
    /// Markdown-ish rendering of the message content, mentions resolved.
    public var content: String
    /// The original `message_type` (`text`, `post`, `image`, ...).
    public var rawContentType: String
    public var resources: [ResourceDescriptor]
    /// Mentions other than `@all`.
    public var mentions: [MentionInfo]
    public var mentionAll: Bool
    public var mentionedBot: Bool
    public var rootId: String?
    public var threadId: String?
    public var replyToMessageId: String?
    /// Message creation time in milliseconds (0 when unknown).
    public var createTime: Int
    /// The raw (flattened) event payload when `includeRawEvent` is enabled.
    public var raw: JSONValue?

    public init(
        messageId: String, chatId: String, chatType: ChatType, senderId: String, senderName: String? = nil,
        content: String, rawContentType: String, resources: [ResourceDescriptor] = [], mentions: [MentionInfo] = [],
        mentionAll: Bool = false, mentionedBot: Bool = false, rootId: String? = nil, threadId: String? = nil,
        replyToMessageId: String? = nil, createTime: Int, raw: JSONValue? = nil
    ) {
        self.messageId = messageId
        self.chatId = chatId
        self.chatType = chatType
        self.senderId = senderId
        self.senderName = senderName
        self.content = content
        self.rawContentType = rawContentType
        self.resources = resources
        self.mentions = mentions
        self.mentionAll = mentionAll
        self.mentionedBot = mentionedBot
        self.rootId = rootId
        self.threadId = threadId
        self.replyToMessageId = replyToMessageId
        self.createTime = createTime
        self.raw = raw
    }
}

/// A downloadable resource referenced by a message (node-sdk `ResourceDescriptor`).
public struct ResourceDescriptor: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case image, file, audio, video, sticker
    }

    public var type: Kind
    public var fileKey: String
    public var fileName: String?
    /// The content's numeric `duration` (node-sdk copies the raw value, so a
    /// non-numeric duration would appear there; Swift drops it).
    public var durationMs: Int?
    public var coverImageKey: String?

    public init(type: Kind, fileKey: String, fileName: String? = nil, durationMs: Int? = nil, coverImageKey: String? = nil) {
        self.type = type
        self.fileKey = fileKey
        self.fileName = fileName
        self.durationMs = durationMs
        self.coverImageKey = coverImageKey
    }
}

/// A user mentioned in a message, or a mention to add to an outbound message.
public struct MentionInfo: Sendable, Hashable {
    /// Placeholder key used in the content (e.g. `@_user_1`).
    public var key: String
    public var openId: String?
    public var userId: String?
    public var name: String?
    public var isBot: Bool

    public init(key: String, openId: String? = nil, userId: String? = nil, name: String? = nil, isBot: Bool = false) {
        self.key = key
        self.openId = openId
        self.userId = userId
        self.name = name
        self.isBot = isBot
    }
}

/// The bot's own identity, resolved from `GET /open-apis/bot/v3/info` on connect.
public struct BotIdentity: Sendable, Hashable {
    public var openId: String
    public var userId: String?
    public var name: String

    public init(openId: String, userId: String? = nil, name: String) {
        self.openId = openId
        self.userId = userId
        self.name = name
    }
}

// MARK: - Outbound

/// Media payload for outbound image/file/audio/video messages
/// (node-sdk `string | Buffer`).
public enum MediaSource: Sendable, Hashable, ExpressibleByStringLiteral {
    /// Raw bytes.
    case data(Data)
    /// An `http(s)://` URL (fetched through the SSRF guard) or a local file
    /// path (checked against the POSIX blocklist / `allowedFileDirs`).
    case location(String)

    public init(stringLiteral value: String) { self = .location(value) }
}

/// What to send (node-sdk `SendInput`).
///
/// `post` / `card` payloads are ``JSONValue`` objects, which carry no key
/// order; they are serialised with sorted keys (node-sdk keeps the caller's
/// insertion order). Payloads the channel builds itself (text, markdown posts,
/// streaming cards, settings) are byte-identical to node-sdk.
public enum SendInput: Sendable {
    /// Markdown, sent as `post` messages with a single `md` element, split into
    /// chunks of `textChunkLimit` characters (code fences preserved).
    case markdown(String)
    /// Plain text, split into chunks of `textChunkLimit` characters.
    case text(String)
    /// A raw post body (`{"zh_cn": {...}}`).
    case post(JSONValue)
    case image(MediaSource)
    case file(MediaSource, fileName: String)
    /// Opus audio; `duration` in milliseconds (parsed from the Ogg stream when nil).
    case audio(MediaSource, duration: Int? = nil)
    /// MP4 video; `duration` in milliseconds (parsed from the `mvhd` box when nil).
    case video(MediaSource, duration: Int? = nil, coverImageKey: String? = nil)
    /// An interactive card JSON.
    case card(JSONValue)
    case shareChat(chatId: String)
    case shareUser(userId: String)
    case sticker(fileKey: String)
}

/// Send options (node-sdk `SendOptions`).
public struct SendOptions: Sendable {
    /// Reply to this message id (falls back to a fresh message if the target is gone).
    public var replyTo: String?
    public var replyInThread: Bool?
    /// Users to mention at the start of the message.
    public var mentions: [MentionInfo]?

    public init(replyTo: String? = nil, replyInThread: Bool? = nil, mentions: [MentionInfo]? = nil) {
        self.replyTo = replyTo
        self.replyInThread = replyInThread
        self.mentions = mentions
    }
}

/// Result of a send (node-sdk `SendResult`).
public struct SendResult: Sendable, Hashable {
    /// The first (or only) message id.
    public var messageId: String
    /// All message ids when the content was split into several messages.
    public var chunkIds: [String]?

    public init(messageId: String, chunkIds: [String]? = nil) {
        self.messageId = messageId
        self.chunkIds = chunkIds
    }
}

/// Drives a streaming markdown reply.
public typealias MarkdownStreamProducer = @Sendable (any MarkdownStreamController) async throws -> Void
/// Drives a streaming card reply.
public typealias CardStreamProducer = @Sendable (any CardStreamController) async throws -> Void

/// Streaming input (node-sdk `StreamInput`).
public enum StreamInput: Sendable {
    /// Streaming markdown rendered with CardKit's native typewriter effect.
    case markdown(MarkdownStreamProducer)
    /// A card patched in place (throttled) as the producer updates it.
    case card(initial: JSONValue, producer: CardStreamProducer)
}

/// Handle passed to a ``MarkdownStreamProducer``.
public protocol MarkdownStreamController: Sendable {
    /// Appends a chunk. Delta and accumulated producers are both supported.
    func append(_ chunk: String) async throws
    /// Replaces the whole content.
    func setContent(_ full: String) async throws
    /// The head card's message id.
    var messageId: String { get async }
}

/// Handle passed to a ``CardStreamProducer``.
public protocol CardStreamController: Sendable {
    /// Replaces the card.
    func update(_ next: JSONValue) async
    /// Replaces the card with a value derived from the current one.
    func update(_ transform: @Sendable (JSONValue) -> JSONValue) async
    var messageId: String { get async }
    var current: JSONValue { get async }
}

// MARK: - Events

/// Policy-level reasons for rejecting an inbound message (node-sdk `RejectReason`).
public enum RejectReason: String, Sendable, Hashable {
    case groupNotAllowed = "group_not_allowed"
    case senderNotAllowed = "sender_not_allowed"
    case noMention = "no_mention"
    case dmDisabled = "dm_disabled"
    case mentionAllBlocked = "mention_all_blocked"
}

/// Emitted when the policy gate rejects a message.
public struct RejectEvent: Sendable, Hashable {
    public var messageId: String
    public var chatId: String
    public var senderId: String
    public var reason: RejectReason

    public init(messageId: String, chatId: String, senderId: String, reason: RejectReason) {
        self.messageId = messageId
        self.chatId = chatId
        self.senderId = senderId
        self.reason = reason
    }
}

/// A card button / form interaction (`card.action.trigger`).
public struct CardActionEvent: Sendable, Equatable {
    public struct Operator: Sendable, Hashable {
        public var openId: String
        public var userId: String?
        public var name: String?
        public init(openId: String, userId: String? = nil, name: String? = nil) {
            self.openId = openId
            self.userId = userId
            self.name = name
        }
    }

    public struct Action: Sendable, Equatable {
        /// The element's `value` (`nil` when absent).
        public var value: JSONValue?
        public var tag: String
        public var name: String?
        public var option: String?
        public init(value: JSONValue? = nil, tag: String, name: String? = nil, option: String? = nil) {
            self.value = value
            self.tag = tag
            self.name = name
            self.option = option
        }
    }

    public var messageId: String
    public var chatId: String
    public var `operator`: Operator
    public var action: Action
    public var raw: JSONValue?
}

/// Whether a reaction was added or removed.
public enum ReactionAction: String, Sendable, Hashable {
    case added, removed
}

/// A reaction added to / removed from a message.
public struct ReactionEvent: Sendable, Equatable {
    public struct Operator: Sendable, Hashable {
        public var openId: String
        public var userId: String?
    }

    public var messageId: String
    public var `operator`: Operator
    public var emojiType: String
    public var action: ReactionAction
    public var actionTime: Int?
    public var raw: JSONValue?
}

/// The bot was added to a chat (`im.chat.member.bot.added_v1`).
public struct BotAddedEvent: Sendable, Equatable {
    public struct Operator: Sendable, Hashable {
        public var openId: String
        public var userId: String?
    }

    public var chatId: String
    public var `operator`: Operator
    /// The bot's own name as carried in the event's `name` field (not the chat name).
    public var botName: String?
    public var external: Bool?
    public var raw: JSONValue?
}

/// A comment on a cloud document (`drive.notice.comment_add_v1`).
public struct CommentEvent: Sendable, Equatable {
    public struct Operator: Sendable, Hashable {
        public var openId: String
        public var userId: String?
        public var unionId: String?
    }

    public var fileToken: String
    public var fileType: String
    public var commentId: String
    public var replyId: String?
    public var `operator`: Operator
    public var mentionedBot: Bool
    /// Milliseconds.
    public var timestamp: Int
    public var raw: JSONValue?
}

// MARK: - Low-level return types

/// Chat details returned by ``LarkChannel/getChatInfo(_:)``.
public struct ChatInfo: Sendable, Hashable {
    public var chatId: String
    public var name: String?
    public var description: String?
    /// The raw `chat_mode` (`p2p`, `group`, `topic`, ...), `group` when absent.
    public var chatType: ChatType
    public var ownerId: String?
    /// `user_count` (the API returns it as a string; parsed to an integer here).
    public var memberCount: Int?
}

/// Chat mode returned by ``LarkChannel/getChatMode(_:)``.
public enum ChatMode: String, Sendable, Hashable {
    case p2p, group, topic
}

/// Resource kind for ``LarkChannel/downloadResource(_:type:)``.
public enum ResourceType: String, Sendable, Hashable {
    case image, file
}
