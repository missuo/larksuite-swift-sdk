import Foundation

/// Port of node-sdk `converters/merge-forward.ts`.
enum MergeForward {
    static let maxItems = 50
    private static let empty = ConvertResult(content: "<forwarded_messages/>", resources: [])

    @Sendable static func convert(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        guard let fetch = ctx.fetchSubMessages, ctx.dispatch != nil else { return empty }

        let items: [ApiMessageItem]
        do {
            items = try await fetch(ctx.messageId)
        } catch {
            return empty
        }
        if items.isEmpty { return empty }

        let capped = Array(items.prefix(maxItems))
        let truncated = items.count > maxItems

        // Pre-warm the sender name cache in one batch call.
        if let batch = ctx.batchResolveNames {
            var senderIds: [String] = []
            var seen = Set<String>()
            for it in capped {
                if let sid = it.senderId, !sid.isEmpty, it.messageId != ctx.messageId, !seen.contains(sid) {
                    seen.insert(sid)
                    senderIds.append(sid)
                }
            }
            if !senderIds.isEmpty {
                try? await batch(senderIds)
            }
        }

        let children = buildChildrenMap(capped, rootId: ctx.messageId)
        let content = await formatSubTree(ctx.messageId, children, ctx, truncated: truncated)
        return ConvertResult(content: content, resources: [])
    }

    static func createTime(_ item: ApiMessageItem) -> Double? {
        JS.parseInt(item.createTime ?? "0")
    }

    static func buildChildrenMap(_ items: [ApiMessageItem], rootId: String) -> [String: [ApiMessageItem]] {
        var map: [String: [ApiMessageItem]] = [:]
        for it in items {
            if it.messageId == rootId && (it.upperMessageId ?? "").isEmpty { continue }
            let pid = it.upperMessageId ?? rootId
            map[pid, default: []].append(it)
        }
        for (k, arr) in map {
            // Stable sort by create_time (NaN compares as equal, like `ta - tb`).
            map[k] = arr.enumerated().sorted { a, b in
                let ta = createTime(a.element), tb = createTime(b.element)
                if let ta, let tb, ta != tb { return ta < tb }
                return a.offset < b.offset
            }.map(\.element)
        }
        return map
    }

    static func formatSubTree(
        _ parentId: String, _ map: [String: [ApiMessageItem]], _ ctx: ConvertContext, truncated: Bool = false
    ) async -> String {
        guard let children = map[parentId], !children.isEmpty else { return "<forwarded_messages/>" }
        var parts: [String] = []
        for item in children {
            let sub = await renderItem(item, map, ctx)
            if !sub.isEmpty { parts.append(sub) }
        }
        if parts.isEmpty { return "<forwarded_messages/>" }
        let body = parts.joined(separator: "\n")
        let footer = truncated ? "\n... (truncated)" : ""
        return "<forwarded_messages>\n\(body)\(footer)\n</forwarded_messages>"
    }

    static func renderItem(_ item: ApiMessageItem, _ map: [String: [ApiMessageItem]], _ ctx: ConvertContext) async -> String {
        let msgType = item.msgType ?? "text"
        let senderId = item.senderId ?? "unknown"
        let createMs = createTime(item) ?? .nan
        let timestamp = createMs > 0 ? NormalizeUtils.formatRFC3339Beijing(createMs) : "unknown"
        let displayName = ctx.resolveUserName?(senderId) ?? senderId

        let content: String
        if msgType == "merge_forward" {
            // Nested forward — recurse locally without another API call.
            if let nestedId = item.messageId, !nestedId.isEmpty {
                content = await formatSubTree(nestedId, map, ctx)
            } else {
                content = "<forwarded_messages/>"
            }
        } else {
            let rawContent = item.content ?? "{}"
            if let dispatch = ctx.dispatch {
                content = await dispatch(rawContent, msgType, ctx).content
            } else {
                content = rawContent
            }
        }
        let indented = NormalizeUtils.indentLines(content, "    ")
        return "[\(timestamp)] \(displayName):\n\(indented)"
    }
}
