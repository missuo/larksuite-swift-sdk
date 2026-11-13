import Foundation
import LarkCore

/// Arguments of one raw send (node-sdk `RawSendArgs`).
struct RawSendArgs: Sendable {
    var to: String
    var idType: ReceiveIdType
    var msgType: String
    /// Parsed content; stringified at the edge.
    var content: OrderedJSON
    var replyTo: String?
    var replyInThread: Bool?
}

/// Port of node-sdk `channel/outbound/sender.ts`.
final class OutboundSender: StreamingSender, Sendable {
    static let defaultChunkLimit = 3500

    let api: ChannelAPI
    let config: OutboundConfig
    let logger: LoggerProxy
    let uploader: MediaUploader
    let chunkLimit: Int

    init(api: ChannelAPI, config: OutboundConfig, logger: LoggerProxy) {
        self.api = api
        self.config = config
        self.logger = logger
        self.uploader = MediaUploader(api: api, config: config)
        self.chunkLimit = config.textChunkLimit ?? Self.defaultChunkLimit
    }

    // MARK: Public entry points

    func send(_ to: String, _ input: SendInput, _ opts: SendOptions = SendOptions()) async throws -> SendResult {
        let idType = try detectReceiveIdType(to)
        switch input {
        case .markdown(let md): return try await sendMarkdown(to, idType, md, opts)
        case .text(let text): return try await sendText(to, idType, text, opts)
        case .post(let post): return try await sendSingle(to, idType, "post", OrderedJSON(post), opts)
        case .image(let source):
            let up = try await uploader.upload(.init(kind: .image, source: source))
            return try await sendSingle(to, idType, "image", .obj(["image_key": .string(up.fileKey)]), opts)
        case .file(let source, let fileName):
            let up = try await uploader.upload(.init(kind: .file, source: source, fileName: fileName))
            return try await sendSingle(to, idType, "file", .obj(["file_key": .string(up.fileKey)]), opts)
        case .audio(let source, let duration):
            let up = try await uploader.upload(.init(kind: .audio, source: source, duration: duration))
            return try await sendSingle(to, idType, "audio", .obj(["file_key": .string(up.fileKey)]), opts)
        case .video(let source, let duration, let cover):
            let up = try await uploader.upload(.init(kind: .video, source: source, duration: duration))
            var content = OrderedJSON.obj(["file_key": .string(up.fileKey)])
            if let cover, !cover.isEmpty { content["image_key"] = .string(cover) }
            return try await sendSingle(to, idType, "media", content, opts)
        case .card(let card): return try await sendSingle(to, idType, "interactive", OrderedJSON(card), opts)
        case .shareChat(let chatId): return try await sendSingle(to, idType, "share_chat", .obj(["chat_id": .string(chatId)]), opts)
        case .shareUser(let userId): return try await sendSingle(to, idType, "share_user", .obj(["user_id": .string(userId)]), opts)
        case .sticker(let fileKey): return try await sendSingle(to, idType, "sticker", .obj(["file_key": .string(fileKey)]), opts)
        }
    }

    func stream(_ to: String, _ input: StreamInput, _ opts: SendOptions = SendOptions()) async throws -> SendResult {
        let idType = try detectReceiveIdType(to)
        switch input {
        case .markdown(let producer):
            return try await MarkdownStreamSession(sender: self, to: to, idType: idType, opts: opts).run(producer)
        case .card(let initial, let producer):
            return try await CardStreamSession(sender: self, to: to, idType: idType, opts: opts, initial: initial).run(producer)
        }
    }

    // MARK: Text / markdown

    private func sendMarkdown(_ to: String, _ idType: ReceiveIdType, _ md: String, _ opts: SendOptions) async throws -> SendResult {
        let chunks = MarkdownTools.splitWithCodeFences(md, limit: chunkLimit)
        var ids: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let post = convertMarkdown(chunk, mentions: i == 0 ? opts.mentions : nil)
            let id = try await sendOneWithFallback(
                RawSendArgs(
                    to: to, idType: idType, msgType: "post", content: post, replyTo: i == 0 ? opts.replyTo : nil,
                    replyInThread: opts.replyInThread))
            ids.append(id)
        }
        return makeResult(ids)
    }

    private func sendText(_ to: String, _ idType: ReceiveIdType, _ text: String, _ opts: SendOptions) async throws -> SendResult {
        let body = MarkdownTools.composeMentionsTextPrefix(opts.mentions ?? []) + text
        let chunks = MarkdownTools.splitPlain(body, limit: chunkLimit)
        var ids: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let id = try await sendOneWithFallback(
                RawSendArgs(
                    to: to, idType: idType, msgType: "text", content: .obj(["text": .string(chunk)]),
                    replyTo: i == 0 ? opts.replyTo : nil, replyInThread: opts.replyInThread))
            ids.append(id)
        }
        return makeResult(ids)
    }

    private func convertMarkdown(_ md: String, mentions: [MentionInfo]?) -> OrderedJSON {
        if case .custom(let fn)? = config.markdownConverter { return OrderedJSON(fn(md)) }
        return MarkdownTools.markdownToPost(md, mentions: mentions)
    }

    private func sendSingle(_ to: String, _ idType: ReceiveIdType, _ msgType: String, _ content: OrderedJSON, _ opts: SendOptions) async throws -> SendResult {
        let id = try await sendOneWithFallback(
            RawSendArgs(to: to, idType: idType, msgType: msgType, content: content, replyTo: opts.replyTo, replyInThread: opts.replyInThread))
        return SendResult(messageId: id)
    }

    private func makeResult(_ ids: [String]) -> SendResult {
        SendResult(messageId: ids.first ?? "", chunkIds: ids.count > 1 ? ids : nil)
    }

    // MARK: Raw send with fallback & retry

    /// One send with a single fallback: a vanished reply target → fresh message;
    /// a rejected `post` → plain text.
    func sendOneWithFallback(_ args: RawSendArgs) async throws -> String {
        do {
            return try await rawSendWithRetry(args)
        } catch {
            let err = classifyError(error, context: .init(to: args.to))
            if isReplyTargetGone(err), let replyTo = args.replyTo, !replyTo.isEmpty {
                var next = args
                next.replyTo = nil
                return try await rawSendWithRetry(next)
            }
            if isFormatError(err) && args.msgType == "post" {
                let plain = MarkdownTools.postToPlainText(args.content)
                var next = args
                next.msgType = "text"
                next.content = .obj(["text": .string(plain.isEmpty ? "[message]" : plain)])
                return try await rawSendWithRetry(next)
            }
            throw err
        }
    }

    func rawSendWithRetry(_ args: RawSendArgs) async throws -> String {
        try await retry(maxAttempts: config.retry?.maxAttempts, baseDelayMs: config.retry?.baseDelayMs) { _ in
            try await self.rawSend(args)
        }
    }

    private func rawSend(_ args: RawSendArgs) async throws -> String {
        let content = args.content.stringify()
        if let replyTo = args.replyTo, !replyTo.isEmpty {
            let r = try await api.messageReply(messageId: replyTo, content: content, msgType: args.msgType, replyInThread: args.replyInThread)
            guard let id = r.data?["message_id"]?.stringValue, !id.isEmpty else {
                throw LarkChannelError(.unknown, "message_id missing from reply response")
            }
            return id
        }
        let r = try await api.messageCreate(receiveIdType: args.idType.rawValue, receiveId: args.to, msgType: args.msgType, content: content)
        guard let id = r.data?["message_id"]?.stringValue, !id.isEmpty else {
            throw LarkChannelError(.unknown, "message_id missing from create response")
        }
        return id
    }

    // MARK: Streaming helpers

    /// Full card replace via `im.v1.message.patch`.
    func patchCard(_ messageId: String, _ card: OrderedJSON) async throws {
        try await api.messagePatch(messageId: messageId, content: card.stringify())
    }

    /// `cardkit.v1.card.create` with `type: card_json`; returns the `card_id`.
    func createCardInstance(_ spec: OrderedJSON) async throws -> String {
        let r = try await api.cardCreate(type: "card_json", data: spec.stringify())
        guard let cardId = r.data?["card_id"]?.stringValue, !cardId.isEmpty else {
            throw LarkChannelError(.unknown, "cardkit.card.create returned no card_id")
        }
        return cardId
    }

    /// Sends an interactive message referencing a card instance (no fallback, with retry).
    func sendCardByReference(to: String, idType: ReceiveIdType, cardId: String, opts: SendOptions) async throws -> String {
        try await rawSendWithRetry(
            RawSendArgs(
                to: to, idType: idType, msgType: "interactive",
                content: .obj(["type": "card", "data": .obj(["card_id": .string(cardId)])]),
                replyTo: opts.replyTo, replyInThread: opts.replyInThread))
    }

    /// Typewriter update of a card element (`uuid` = `c_<cardId>_<sequence>`).
    func updateCardElementContent(cardId: String, elementId: String, content: String, sequence: Int) async throws {
        try await api.cardElementContent(cardId: cardId, elementId: elementId, content: content, sequence: sequence, uuid: "c_\(cardId)_\(sequence)")
    }

    /// Turns `streaming_mode` off (and optionally sets the preview summary).
    func finishStreamingCard(cardId: String, sequence: Int, summary: String?) async throws {
        var cfg = OrderedJSON.obj(["streaming_mode": false])
        if let summary { cfg["summary"] = .obj(["content": .string(summary)]) }
        let settings = OrderedJSON.obj(["config": cfg]).stringify()
        try await api.cardSettings(cardId: cardId, settings: settings, sequence: sequence, uuid: "s_\(cardId)_\(sequence)")
    }
}
