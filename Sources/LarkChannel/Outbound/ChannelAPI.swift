import Foundation
import LarkCore
import LarkIM

/// The Open Platform calls made by the channel.
///
/// Same methods, paths, query and body fields as the generated
/// `client.im.v1.*` / `client.cardkit.v1.*` methods node-sdk calls, but JSON
/// bodies are serialised from ``OrderedJSON`` so the bytes (including key
/// order and the stringified `content` / `settings` fields) match node-sdk's
/// `JSON.stringify`, and responses are read loosely (`r.data?.message_id`)
/// instead of being decoded into the generated models — node-sdk reads them
/// untyped, and e.g. a missing `card_id` must surface as the channel's own
/// error rather than a decoding failure.
struct ChannelAPI: Sendable {
    let client: LarkClient

    static let jsonContentType = "application/json; charset=utf-8"

    private func seg(_ s: String) -> String { LarkURL.escapePathSegment(s) }

    /// `encodeURIComponent`-style query encoding, keys kept in the given order (node `qs`).
    static func query(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(UInt8(0))...Unicode.Scalar(UInt8(0x7F))))
        allowed.insert(charactersIn: "-_.!~*'()")
        return items.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    @discardableResult
    func json(_ method: HTTPMethod, _ path: String, body: OrderedJSON? = nil) async throws -> LarkResponse<JSONValue> {
        let b: LarkRequestBody = body.map { .raw(Data($0.stringify().utf8), contentType: Self.jsonContentType) } ?? .none
        return try await client.request(method, path, body: b, as: JSONValue.self)
    }

    // MARK: im.v1.message

    /// `im.v1.message.create` — `POST /open-apis/im/v1/messages?receive_id_type=...`.
    func messageCreate(receiveIdType: String, receiveId: String, msgType: String, content: String) async throws -> LarkResponse<JSONValue> {
        try await json(
            .post, "/open-apis/im/v1/messages?\(Self.query([("receive_id_type", receiveIdType)]))",
            body: .obj(["receive_id": .string(receiveId), "msg_type": .string(msgType), "content": .string(content)]))
    }

    /// `im.v1.message.reply` — `POST /open-apis/im/v1/messages/:message_id/reply`.
    func messageReply(messageId: String, content: String, msgType: String, replyInThread: Bool?) async throws -> LarkResponse<JSONValue> {
        var body = OrderedJSON.obj(["content": .string(content), "msg_type": .string(msgType)])
        if let replyInThread { body["reply_in_thread"] = .bool(replyInThread) }
        return try await json(.post, "/open-apis/im/v1/messages/\(seg(messageId))/reply", body: body)
    }

    /// `im.v1.message.patch` — `PATCH /open-apis/im/v1/messages/:message_id`.
    func messagePatch(messageId: String, content: String) async throws {
        try await json(.patch, "/open-apis/im/v1/messages/\(seg(messageId))", body: .obj(["content": .string(content)]))
    }

    /// `im.v1.message.update` — `PUT /open-apis/im/v1/messages/:message_id`.
    func messageUpdate(messageId: String, msgType: String, content: String) async throws {
        try await json(.put, "/open-apis/im/v1/messages/\(seg(messageId))", body: .obj(["msg_type": .string(msgType), "content": .string(content)]))
    }

    /// `im.v1.message.delete` — `DELETE /open-apis/im/v1/messages/:message_id`.
    func messageDelete(messageId: String) async throws {
        try await json(.delete, "/open-apis/im/v1/messages/\(seg(messageId))")
    }

    /// `im.v1.message.get` — `GET /open-apis/im/v1/messages/:message_id`.
    func messageGet(messageId: String) async throws -> LarkResponse<JSONValue> {
        try await json(.get, "/open-apis/im/v1/messages/\(seg(messageId))")
    }

    // MARK: im.v1.messageReaction

    /// `im.v1.messageReaction.create` — `POST /open-apis/im/v1/messages/:message_id/reactions`.
    func reactionCreate(messageId: String, emojiType: String) async throws -> LarkResponse<JSONValue> {
        try await json(
            .post, "/open-apis/im/v1/messages/\(seg(messageId))/reactions",
            body: .obj(["reaction_type": .obj(["emoji_type": .string(emojiType)])]))
    }

    /// `im.v1.messageReaction.delete` — `DELETE /open-apis/im/v1/messages/:message_id/reactions/:reaction_id`.
    func reactionDelete(messageId: String, reactionId: String) async throws {
        try await json(.delete, "/open-apis/im/v1/messages/\(seg(messageId))/reactions/\(seg(reactionId))")
    }

    /// `im.v1.messageReaction.list` — `GET /open-apis/im/v1/messages/:message_id/reactions`.
    func reactionList(messageId: String, reactionType: String, pageSize: Int) async throws -> LarkResponse<JSONValue> {
        try await json(
            .get,
            "/open-apis/im/v1/messages/\(seg(messageId))/reactions?\(Self.query([("reaction_type", reactionType), ("page_size", String(pageSize))]))"
        )
    }

    // MARK: im.v1.image / im.v1.file

    /// `im.v1.image.create` — multipart `POST /open-apis/im/v1/images` (`image_type`, `image`).
    func imageCreate(_ data: Data) async throws -> LarkResponse<JSONValue> {
        var form = MultipartForm()
        form.append("image_type", "message")
        form.append("image", LarkFile(data: data, fileName: "image"))
        return try await client.request(.post, "/open-apis/im/v1/images", body: .multipart(form), as: JSONValue.self)
    }

    /// `im.v1.file.create` — multipart `POST /open-apis/im/v1/files`
    /// (`file_type`, `file_name`, `file`, optional `duration`).
    func fileCreate(fileType: String, fileName: String, data: Data, duration: Int?) async throws -> LarkResponse<JSONValue> {
        var form = MultipartForm()
        form.append("file_type", fileType)
        form.append("file_name", fileName)
        form.append("file", LarkFile(data: data, fileName: fileName))
        if let duration { form.append("duration", duration) }
        return try await client.request(.post, "/open-apis/im/v1/files", body: .multipart(form), as: JSONValue.self)
    }

    /// `im.v1.image.get` — `GET /open-apis/im/v1/images/:image_key`.
    func imageGet(imageKey: String) async throws -> LarkBinaryResponse {
        try await client.im.v1.image.get(imageKey: imageKey)
    }

    /// `im.v1.file.get` — `GET /open-apis/im/v1/files/:file_key`.
    func fileGet(fileKey: String) async throws -> LarkBinaryResponse {
        try await client.im.v1.file.get(fileKey: fileKey)
    }

    // MARK: im.v1.chat

    /// `im.v1.chat.get` — `GET /open-apis/im/v1/chats/:chat_id`.
    func chatGet(chatId: String) async throws -> LarkResponse<JSONValue> {
        try await json(.get, "/open-apis/im/v1/chats/\(seg(chatId))")
    }

    // MARK: cardkit.v1

    /// `cardkit.v1.card.create` — `POST /open-apis/cardkit/v1/cards`.
    func cardCreate(type: String, data: String) async throws -> LarkResponse<JSONValue> {
        try await json(.post, "/open-apis/cardkit/v1/cards", body: .obj(["type": .string(type), "data": .string(data)]))
    }

    /// `cardkit.v1.card.settings` — `PATCH /open-apis/cardkit/v1/cards/:card_id/settings`.
    func cardSettings(cardId: String, settings: String, sequence: Int, uuid: String) async throws {
        try await json(
            .patch, "/open-apis/cardkit/v1/cards/\(seg(cardId))/settings",
            body: .obj(["settings": .string(settings), "sequence": .number(Double(sequence)), "uuid": .string(uuid)]))
    }

    /// `cardkit.v1.cardElement.content` — `PUT /open-apis/cardkit/v1/cards/:card_id/elements/:element_id/content`.
    func cardElementContent(cardId: String, elementId: String, content: String, sequence: Int, uuid: String) async throws {
        try await json(
            .put, "/open-apis/cardkit/v1/cards/\(seg(cardId))/elements/\(seg(elementId))/content",
            body: .obj(["content": .string(content), "sequence": .number(Double(sequence)), "uuid": .string(uuid)]))
    }

    // MARK: bot

    /// `GET /open-apis/bot/v3/info` via the raw request path (node `client.request`):
    /// returns the whole body, throws only for HTTP errors.
    func botInfo() async throws -> JSONValue {
        let resp = try await client.send(.get, "/open-apis/bot/v3/info")
        if !(200..<300).contains(resp.statusCode) {
            if let json = try? JSONValue(data: resp.body), let code = json["code"]?.intValue, code != 0 {
                throw LarkError.api(
                    LarkAPIError(
                        code: code, msg: json["msg"]?.stringValue ?? "", httpStatus: resp.statusCode,
                        logId: resp.header("x-tt-logid"), headers: resp.headers, body: resp.body))
            }
            throw LarkError.http(statusCode: resp.statusCode, headers: resp.headers, body: resp.body)
        }
        return (try? JSONValue(data: resp.body)) ?? .null
    }
}
