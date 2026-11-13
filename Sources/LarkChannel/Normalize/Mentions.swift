import Foundation

/// Port of node-sdk `channel/normalize/mentions.ts`.
enum Mentions {
    struct Extraction: Sendable {
        /// By placeholder key.
        var mentions: MentionMap
        /// By open_id.
        var mentionsByOpenId: MentionMap
        /// Non-@all mentions, for the public message.
        var mentionList: [MentionInfo]
        var mentionAll: Bool
        var mentionedBot: Bool
    }

    static func isMentionAll(_ m: OrderedJSON) -> Bool {
        m["key"]?.stringValue == "@_all"
    }

    /// Builds the mention maps from the raw `message.mentions` array.
    static func extract(_ raw: [OrderedJSON]?, botOpenId: String?) -> Extraction {
        var mentions = MentionMap()
        var byOpenId = MentionMap()
        var list: [MentionInfo] = []
        var mentionAll = false
        var mentionedBot = false

        for m in raw ?? [] {
            let key = JS.string(m["key"], default: "")
            let name = JS.optionalString(m["name"])
            if isMentionAll(m) {
                mentionAll = true
                mentions.set(key, MentionInfo(key: key, name: name, isBot: false))
                continue
            }
            let openId = JS.string(m[path: "id", "open_id"], default: "")
            let userId = JS.optionalString(m[path: "id", "user_id"])
            let isBot = (botOpenId.map { !$0.isEmpty } ?? false) && openId == botOpenId
            if isBot { mentionedBot = true }

            let info = MentionInfo(key: key, openId: openId.isEmpty ? nil : openId, userId: userId, name: name, isBot: isBot)
            mentions.set(key, info)
            if !openId.isEmpty { byOpenId.set(openId, info) }
            list.append(info)
        }
        return Extraction(mentions: mentions, mentionsByOpenId: byOpenId, mentionList: list, mentionAll: mentionAll, mentionedBot: mentionedBot)
    }

    private static let collapse = JS.regex("[ \\t]{2,}")

    /// Second pass: replace placeholder keys with `@name`, or strip bot mentions.
    static func resolve(_ content: String, mentions: MentionMap, stripBotMentions: Bool) -> String {
        if content.isEmpty || mentions.count == 0 { return content }
        var out = content
        for (key, info) in mentions.entries where !key.isEmpty {
            if info.isBot && stripBotMentions {
                let re = JS.regex("[\(JS.ws)]?\(NSRegularExpression.escapedPattern(for: key))[\(JS.ws)]?")
                out = JS.replace(out, re, with: " ")
                continue
            }
            let replacement = info.name.flatMap { $0.isEmpty ? nil : "@\($0)" } ?? key
            out = JS.replaceAll(out, key, replacement)
        }
        return JS.trim(JS.replace(out, collapse, with: " "))
    }
}

extension OrderedJSON {
    /// `x.join(', ')`-style rendering helper for arrays of strings.
    var stringArray: [String]? {
        guard let a = arrayValue else { return nil }
        return a.compactMap { $0.stringValue }
    }
}
