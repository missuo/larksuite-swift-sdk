import Foundation
import LarkCore

/// Builders for the JSON-encoded `content` field of IM messages.
///
/// ```swift
/// try await client.im.v1.message.create(
///     params: .init(receiveIdType: .chatId),
///     body: .init(receiveId: chatId, msgType: "text", content: MessageContent.text("hi \(MessageContent.at(openId))")))
/// ```
public enum MessageContent {
    /// `text` message content.
    public static func text(_ text: String) -> String {
        JSONValue.object(["text": .string(text)]).jsonString()
    }

    /// An @mention to embed in text messages. Use `"all"` to mention everyone.
    public static func at(_ openId: String, name: String = "") -> String {
        "<at user_id=\"\(openId)\">\(name)</at>"
    }

    /// `interactive` (card) message content from a card JSON object.
    public static func card(_ card: JSONValue) -> String { card.jsonString() }

    /// `interactive` content that references a card template.
    public static func cardTemplate(id: String, version: String? = nil, variables: JSONValue? = nil) -> String {
        var data: [String: JSONValue] = ["template_id": .string(id)]
        if let version { data["template_version_name"] = .string(version) }
        if let variables { data["template_variable"] = variables }
        return JSONValue.object(["type": "template", "data": .object(data)]).jsonString()
    }

    /// `image` message content.
    public static func image(key: String) -> String { JSONValue.object(["image_key": .string(key)]).jsonString() }

    /// `file` message content.
    public static func file(key: String) -> String { JSONValue.object(["file_key": .string(key)]).jsonString() }

    /// `post` (rich text) content for one locale.
    public static func post(title: String, paragraphs: [[JSONValue]], locale: String = "zh_cn") -> String {
        JSONValue.object([locale: ["title": .string(title), "content": .array(paragraphs.map { .array($0) })]]).jsonString()
    }

    /// Any encodable content.
    public static func json<T: Encodable>(_ value: T) throws -> String { try LarkJSON.string(value) }
}

extension IM.MessageCreateBody {
    /// A text message body.
    public static func text(to receiveId: String, _ text: String, uuid: String? = nil) -> Self {
        .init(receiveId: receiveId, msgType: "text", content: MessageContent.text(text), uuid: uuid)
    }

    /// A card (`interactive`) message body.
    public static func card(to receiveId: String, _ card: JSONValue, uuid: String? = nil) -> Self {
        .init(receiveId: receiveId, msgType: "interactive", content: MessageContent.card(card), uuid: uuid)
    }
}

extension IM.MessageReplyBody {
    /// A text reply body.
    public static func text(_ text: String, replyInThread: Bool? = nil, uuid: String? = nil) -> Self {
        .init(content: MessageContent.text(text), msgType: "text", replyInThread: replyInThread, uuid: uuid)
    }

    /// A card (`interactive`) reply body.
    public static func card(_ card: JSONValue, replyInThread: Bool? = nil, uuid: String? = nil) -> Self {
        .init(content: MessageContent.card(card), msgType: "interactive", replyInThread: replyInThread, uuid: uuid)
    }
}

extension IM.MessageReceiveV1Event {
    /// The plain text of a `text` message (mention placeholders such as `@_user_1` are kept).
    public var text: String? {
        guard let message, message.messageType == "text", let content = message.content,
            let json = try? JSONValue(jsonString: content)
        else { return nil }
        return json["text"]?.stringValue
    }
}
