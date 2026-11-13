import Foundation

/// Ports of node-sdk `channel/normalize/converters/*` and `registry.ts`.
enum Converters {
    typealias U = NormalizeUtils

    private static func result(_ content: String, _ resources: [ResourceDescriptor] = []) -> ConvertResult {
        ConvertResult(content: content, resources: resources)
    }

    /// Duration as stored on a resource (`durationMs: parsed.duration`).
    private static func durationInt(_ v: OrderedJSON?) -> Int? {
        guard let d = v?.numberValue, d.isFinite, abs(d) < 9.2e18 else { return nil }
        return Int(d)
    }

    /// A JS `TypeError` inside a converter (handled by ``dispatch(_:_:_:)``).
    enum ConvertError: Error { case typeError }

    /// `for (const x of value ?? [])`: arrays yield elements, strings yield
    /// characters, `null` yields nothing, anything else throws.
    static func iterate(_ value: OrderedJSON) throws -> [OrderedJSON] {
        switch value {
        case .array(let a): return a
        case .string(let s): return s.utf16.map { .string(String(decoding: [$0], as: UTF16.self)) }
        case .null: return []
        default: throw ConvertError.typeError
        }
    }

    // MARK: Registry

    static let registry: [String: ContentConverter] = [
        "text": text,
        "post": post,
        "image": image,
        "file": file,
        "audio": audio,
        "video": video,
        "media": video,
        "sticker": sticker,
        "interactive": interactive,
        "merge_forward": MergeForward.convert,
        "share_chat": shareChat,
        "share_user": shareUser,
        "location": location,
        "system": system,
        "vote": vote,
        "todo": todo,
        "calendar": calendar,
        "general_calendar": generalCalendar,
        "share_calendar_event": shareCalendarEvent,
        "folder": folder,
        "hongbao": hongbao,
        "video_chat": videoChat,
    ]

    /// Dispatches to the matching converter; any thrown error falls back to ``unknown``.
    @Sendable static func dispatch(_ raw: String, _ msgType: String, _ ctx: ConvertContext) async -> ConvertResult {
        let fn = registry[msgType] ?? unknown
        do {
            return try await fn(raw, ctx)
        } catch {
            return (try? await unknown(raw, ctx)) ?? result("[unsupported message]")
        }
    }

    // MARK: Simple converters

    @Sendable static func text(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let parsed = U.safeParse(raw)
        return result(JS.string(parsed?["text"], default: ""))
    }

    @Sendable static func unknown(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        if let t = U.safeParse(raw)?["text"]?.stringValue { return result(t) }
        return result("[unsupported message]")
    }

    @Sendable static func image(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let v = U.safeParse(raw)?["image_key"]
        guard JS.truthy(v) else { return result("[image]") }
        let key = JS.interpolate(v)
        return result("![image](\(key))", [ResourceDescriptor(type: .image, fileKey: key)])
    }

    @Sendable static func file(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let parsed = U.safeParse(raw)
        let v = parsed?["file_key"]
        guard JS.truthy(v) else { return result("[file]") }
        let key = JS.interpolate(v)
        let fileName = JS.optionalString(parsed?["file_name"])
        let nameAttr = JS.truthy(parsed?["file_name"]) ? " name=\"\(U.escapeAttr(fileName ?? ""))\"" : ""
        return result("<file key=\"\(key)\"\(nameAttr)/>", [ResourceDescriptor(type: .file, fileKey: key, fileName: fileName)])
    }

    @Sendable static func audio(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let parsed = U.safeParse(raw)
        let v = parsed?["file_key"]
        guard JS.truthy(v) else { return result("[audio]") }
        let key = JS.interpolate(v)
        let duration = parsed?["duration"]
        let durAttr = U.formatDuration(duration?.numberValue).map { " duration=\"\($0)\"" } ?? ""
        return result("<audio key=\"\(key)\"\(durAttr)/>", [ResourceDescriptor(type: .audio, fileKey: key, durationMs: durationInt(duration))])
    }

    @Sendable static func video(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let parsed = U.safeParse(raw)
        let v = parsed?["file_key"]
        guard JS.truthy(v) else { return result("[video]") }
        let key = JS.interpolate(v)
        let nameAttr = JS.truthy(parsed?["file_name"]) ? " name=\"\(U.escapeAttr(JS.interpolate(parsed?["file_name"])))\"" : ""
        let durAttr = U.formatDuration(parsed?["duration"]?.numberValue).map { " duration=\"\($0)\"" } ?? ""
        let resource = ResourceDescriptor(
            type: .video, fileKey: key, fileName: JS.optionalString(parsed?["file_name"]),
            durationMs: durationInt(parsed?["duration"]), coverImageKey: JS.optionalString(parsed?["image_key"]))
        return result("<video key=\"\(key)\"\(nameAttr)\(durAttr)/>", [resource])
    }

    @Sendable static func sticker(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let v = U.safeParse(raw)?["file_key"]
        guard JS.truthy(v) else { return result("[sticker]") }
        let key = JS.interpolate(v)
        return result("<sticker key=\"\(key)\"/>", [ResourceDescriptor(type: .sticker, fileKey: key)])
    }

    @Sendable static func folder(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let parsed = U.safeParse(raw)
        let v = parsed?["file_key"]
        guard JS.truthy(v) else { return result("[folder]") }
        let nameAttr = JS.truthy(parsed?["file_name"]) ? " name=\"\(U.escapeAttr(JS.interpolate(parsed?["file_name"])))\"" : ""
        return result("<folder key=\"\(JS.interpolate(v))\"\(nameAttr)/>")
    }

    @Sendable static func hongbao(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let parsed = U.safeParse(raw)
        let textAttr = JS.truthy(parsed?["text"]) ? " text=\"\(U.escapeAttr(JS.interpolate(parsed?["text"])))\"" : ""
        return result("<hongbao\(textAttr)/>")
    }

    @Sendable static func location(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let parsed = U.safeParse(raw)
        let name = parsed?["name"], lat = parsed?["latitude"], lng = parsed?["longitude"]
        let nameAttr = JS.truthy(name) ? " name=\"\(U.escapeAttr(JS.interpolate(name)))\"" : ""
        let coordsAttr = JS.truthy(lat) && JS.truthy(lng) ? " coords=\"lat:\(JS.interpolate(lat)),lng:\(JS.interpolate(lng))\"" : ""
        return result("<location\(nameAttr)\(coordsAttr)/>")
    }

    @Sendable static func shareChat(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        result("<group_card id=\"\(JS.string(U.safeParse(raw)?["chat_id"], default: ""))\"/>")
    }

    @Sendable static func shareUser(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        result("<contact_card id=\"\(JS.string(U.safeParse(raw)?["user_id"], default: ""))\"/>")
    }

    private static let systemPlaceholder = JS.regex("\\{([a-z_]+)\\}")

    @Sendable static func system(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        guard let parsed = U.safeParse(raw), JS.truthy(parsed["template"]) else { return result("[system message]") }
        // `template.replace` throws in JS for non-strings → fallback converter.
        guard let template = parsed["template"]?.stringValue else { throw ConvertError.typeError }
        let out = JS.replace(template, systemPlaceholder) { m, ns in
            let name = JS.group(m, 1, ns) ?? ""
            let val = parsed[name]
            // Inherited Object.prototype members resolve to non-null objects in JS.
            if case .none = val, (name == "constructor" || name == "__proto__") { return ns.substring(with: m.range) }
            switch val {
            case .array(let items):
                return items.map { e -> String in
                    if case .null = e { return "" }
                    return JS.interpolate(e)
                }.joined(separator: ", ")
            case .string(let s): return s
            case .none, .some(.null): return ""
            default: return ns.substring(with: m.range)
            }
        }
        let trimmed = JS.trim(out)
        return result(trimmed.isEmpty ? "[system message]" : trimmed)
    }

    @Sendable static func vote(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let parsed = U.safeParse(raw)
        let topic = parsed?["topic"]
        let options = parsed?["options"]?.arrayValue
        guard let parsed, JS.truthy(topic) || !(options?.isEmpty ?? true) else {
            return result("<vote>\n[vote]\n</vote>")
        }
        var lines: [String] = []
        if JS.truthy(topic) { lines.append(JS.interpolate(topic)) }
        for opt in parsed["options"]?.arrayValue ?? [] { lines.append("• \(JS.interpolate(opt))") }
        return result("<vote>\n\(lines.joined(separator: "\n"))\n</vote>")
    }

    @Sendable static func todo(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        let parsed = U.safeParse(raw)
        guard let summary = parsed?["summary"], JS.truthy(summary) else { return result("<todo>\n[todo]\n</todo>") }
        var lines: [String] = []
        if JS.truthy(summary["title"]) { lines.append(JS.interpolate(summary["title"])) }
        let body = try extractPostPlainText(summary["content"])
        if !body.isEmpty { lines.append(body) }
        if let due = U.millisToDatetime(parsed?["due_time"]) { lines.append("Due: \(due)") }
        if lines.isEmpty { return result("<todo>\n[todo]\n</todo>") }
        return result("<todo>\n\(lines.joined(separator: "\n"))\n</todo>")
    }

    private static func extractPostPlainText(_ blocks: OrderedJSON?) throws -> String {
        guard let blocks, JS.truthy(blocks) else { return "" }
        var lines: [String] = []
        for paragraph in try iterate(blocks) {
            guard let els = paragraph.arrayValue else { continue }
            var parts: [String] = []
            for el in els {
                if el.isNull { throw ConvertError.typeError }
                let tag = el["tag"]?.stringValue
                if (tag == "text" || tag == "a") && JS.truthy(el["text"]) { parts.append(JS.interpolate(el["text"])) }
            }
            if !parts.isEmpty { lines.append(parts.joined()) }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatCalendarInner(_ raw: String) -> String {
        guard let parsed = U.safeParse(raw) else { return "[calendar event]" }
        var lines: [String] = []
        if JS.truthy(parsed["summary"]) { lines.append("📅 \(JS.interpolate(parsed["summary"]))") }
        let start = U.millisToDatetime(parsed["start_time"])
        let end = U.millisToDatetime(parsed["end_time"])
        if let start, let end {
            lines.append("🕙 \(start) ~ \(end)")
        } else if let start {
            lines.append("🕙 \(start)")
        }
        return lines.isEmpty ? "[calendar event]" : lines.joined(separator: "\n")
    }

    @Sendable static func calendar(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        result("<calendar_invite>\n\(formatCalendarInner(raw))\n</calendar_invite>")
    }

    @Sendable static func generalCalendar(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        result("<calendar>\n\(formatCalendarInner(raw))\n</calendar>")
    }

    @Sendable static func shareCalendarEvent(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        result("<calendar_share>\n\(formatCalendarInner(raw))\n</calendar_share>")
    }

    @Sendable static func videoChat(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        guard let parsed = U.safeParse(raw) else { return result("<meeting>\n[video chat]\n</meeting>") }
        var lines: [String] = []
        if JS.truthy(parsed["topic"]) { lines.append("📹 \(JS.interpolate(parsed["topic"]))") }
        if let start = U.millisToDatetime(parsed["start_time"]) { lines.append("🕙 \(start)") }
        let inner = lines.isEmpty ? "[video chat]" : lines.joined(separator: "\n")
        return result("<meeting>\n\(inner)\n</meeting>")
    }

    // MARK: Post

    @Sendable static func post(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        guard let parsed = U.safeParse(raw), parsed.isObjectLike else { return result("[rich text message]") }
        guard let body = U.unwrapLocale(parsed) else { return result("[rich text message]") }

        var resources: [ResourceDescriptor] = []
        var lines: [String] = []
        if JS.truthy(body["title"]) {
            lines.append("**\(JS.interpolate(body["title"]))**")
            lines.append("")
        }
        for paragraph in try iterate(body["content"] ?? .array([])) {
            guard let els = paragraph.arrayValue else { continue }
            var line = ""
            for el in els {
                if el.isNull { throw ConvertError.typeError }  // `el.tag` on null throws in JS
                line += renderPostElement(el, ctx, &resources)
            }
            lines.append(line)
        }
        let content = JS.trim(lines.joined(separator: "\n"))
        return result(content.isEmpty ? "[rich text message]" : content, resources)
    }

    private static func renderPostElement(_ el: OrderedJSON, _ ctx: ConvertContext, _ resources: inout [ResourceDescriptor]) -> String {
        let text = el["text"]
        switch el["tag"]?.stringValue {
        case "text":
            let style = el["style"]?.stringArray
            return U.applyStyle(JS.string(text, default: ""), style)
        case "a":
            let label = JS.optionalString(text) ?? JS.optionalString(el["href"]) ?? ""
            return JS.truthy(el["href"]) ? "[\(label)](\(JS.interpolate(el["href"])))" : label
        case "at":
            let userId = JS.string(el["user_id"], default: "")
            if userId == "all" || userId == "all_members" { return "@all" }
            if let info = ctx.mentionsByOpenId.get(userId) { return info.key }
            return JS.truthy(el["user_name"]) ? "@\(JS.interpolate(el["user_name"]))" : "@\(userId)"
        case "img":
            if JS.truthy(el["image_key"]) {
                let key = JS.interpolate(el["image_key"])
                resources.append(ResourceDescriptor(type: .image, fileKey: key))
                return "![image](\(key))"
            }
            return ""
        case "media":
            if JS.truthy(el["file_key"]) {
                let key = JS.interpolate(el["file_key"])
                resources.append(ResourceDescriptor(type: .file, fileKey: key))
                return "<file key=\"\(key)\"/>"
            }
            return ""
        case "code_block":
            let lang = JS.string(el["language"], default: "")
            let code = JS.string(text, default: "")
            return "\n```\(lang)\n\(code)\n```\n"
        case "hr":
            return "\n---\n"
        default:
            return JS.string(text, default: "")
        }
    }

    // MARK: Interactive

    @Sendable static func interactive(_ raw: String, _ ctx: ConvertContext) async throws -> ConvertResult {
        guard let parsed = U.safeParse(raw), parsed.isObjectLike else { return result("[interactive card]") }
        let pieces = CardWalker.walk(parsed)
        if pieces.isEmpty { return result("[interactive card]") }
        var seen = Set<String>()
        var out: [String] = []
        for p in pieces {
            let key = JS.trim(p)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            out.append(key)
        }
        return result(out.joined(separator: "\n"))
    }
}

/// Port of `converters/interactive/card-walker.ts`.
enum CardWalker {
    static func walk(_ node: OrderedJSON) -> [String] {
        var out: [String] = []
        visit(node, &out)
        return out.filter { !$0.isEmpty && !JS.trim($0).isEmpty }
    }

    private static func visit(_ node: OrderedJSON?, _ out: inout [String]) {
        guard let node else { return }
        switch node {
        case .null, .string, .number, .bool: return
        case .array(let items):
            for child in items { visit(child, &out) }
            return
        case .object: break
        }

        let tag = node["tag"]?.stringValue
        if let tag, tag == "plain_text" || tag == "lark_md" || tag == "markdown" {
            if let c = node["content"]?.stringValue { out.append(c) }
            return
        }

        if let header = node["header"], JS.truthy(header), header.isObjectLike {
            if JS.truthy(header["title"]) { visit(header["title"], &out) }
        }

        if JS.truthy(node["text"]) { visit(node["text"], &out) }

        if tag == "button" {
            if JS.truthy(node["text"]) { visit(node["text"], &out) }
        }

        if JS.truthy(node["label"]) { visit(node["label"], &out) }
        if JS.truthy(node["placeholder"]) { visit(node["placeholder"], &out) }
        if let options = node["options"]?.arrayValue {
            for opt in options where JS.truthy(opt["text"]) { visit(opt["text"], &out) }
        }

        for key in ["elements", "fields", "actions", "columns"] {
            if let items = node[key]?.arrayValue {
                for el in items { visit(el, &out) }
            }
        }

        if JS.truthy(node["body"]) { visit(node["body"], &out) }
    }
}
