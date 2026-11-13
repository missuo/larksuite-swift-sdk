import Foundation
import LarkCore

/// Ports of node-sdk `channel/outbound/markdown/*` and `streaming/merge-text.ts`.
enum MarkdownTools {
    // MARK: compose-mentions

    /// `<at user_id="ou_x">name</at> ` tokens to prepend to text / markdown.
    static func composeMentionsTextPrefix(_ mentions: [MentionInfo]) -> String {
        var parts: [String] = []
        for m in mentions {
            guard let openId = m.openId, !openId.isEmpty else { continue }
            parts.append("<at user_id=\"\(openId)\">\(m.name ?? "")</at>")
        }
        return parts.isEmpty ? "" : parts.joined(separator: " ") + " "
    }

    /// `{tag: 'at', user_id, user_name}` post elements.
    static func composePostMentionElements(_ mentions: [MentionInfo]) -> [OrderedJSON] {
        var out: [OrderedJSON] = []
        for m in mentions {
            guard let openId = m.openId, !openId.isEmpty else { continue }
            var el = OrderedJSON.obj(["tag": "at", "user_id": .string(openId)])
            if let name = m.name { el["user_name"] = .string(name) }
            out.append(el)
        }
        return out
    }

    // MARK: to-post

    /// Markdown → post JSON with a single `md` element (after style optimisation).
    static func markdownToPost(_ md: String, mentions: [MentionInfo]? = nil, title: String? = nil) -> OrderedJSON {
        let prefix = composeMentionsTextPrefix(mentions ?? [])
        let text = optimizeMarkdownStyle(prefix + md, cardVersion: 1)
        return .obj([
            "zh_cn": .obj([
                "title": .string(title ?? ""),
                "content": [[.obj(["tag": "md", "text": .string(text)])]],
            ])
        ])
    }

    /// Plain-text rendering of a post's `zh_cn` body (format-error fallback).
    static func postToPlainText(_ post: OrderedJSON?) -> String {
        guard let content = post?["zh_cn"]?["content"], JS.truthy(content) else { return "" }
        var lines: [String] = []
        for paragraph in (try? Converters.iterate(content)) ?? [] {
            guard let els = paragraph.arrayValue else { continue }
            var parts: [String] = []
            for el in els {
                switch el["tag"]?.stringValue {
                case "md", "text", "a":
                    parts.append(JS.string(el["text"], default: ""))
                case "at":
                    parts.append(JS.truthy(el["user_name"]) ? "@\(JS.interpolate(el["user_name"]))" : "")
                case "img":
                    parts.append(JS.truthy(el["image_key"]) ? "[image]" : "")
                default:
                    break
                }
            }
            lines.append(parts.joined())
        }
        return JS.trim(lines.joined(separator: "\n"))
    }

    // MARK: splitter

    private static let fencePattern = JS.regex("\\A```([A-Za-z0-9_]*)\\z")
    private static let headingPattern = JS.regex("\\A#{1,6}[\(JS.ws)]")

    /// Splits markdown into chunks of at most `limit` UTF-16 units, closing and
    /// reopening code fences across chunk boundaries and preferring to break
    /// before headings.
    static func splitWithCodeFences(_ text: String, limit: Int) -> [String] {
        if JS.length(text) <= limit { return [text] }
        let lines = JS.splitLines(text)
        var out: [String] = []
        var buf: [String] = []
        var bufLen = 0
        var fenceLang: String?

        func flush() {
            if buf.isEmpty { return }
            var chunk = buf.joined(separator: "\n")
            if fenceLang != nil { chunk += "\n```" }
            out.append(chunk)
            buf = []
            bufLen = 0
            if let lang = fenceLang {
                buf.append("```" + lang)
                bufLen = JS.length(buf[0])
            }
        }

        for line in lines {
            let ns = line as NSString
            let m = fencePattern.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length))
            let lineLen = JS.length(line) + (buf.isEmpty ? 0 : 1)
            let isHeading = JS.test(headingPattern, line)
            let nearFull = Double(bufLen) > Double(limit) * 0.75
            if bufLen + lineLen > limit || (isHeading && nearFull && !buf.isEmpty) {
                flush()
            }
            buf.append(line)
            bufLen += lineLen
            if let m {
                fenceLang = fenceLang == nil ? (JS.group(m, 1, ns) ?? "") : nil
            }
        }
        flush()
        return out
    }

    /// Splits plain text into `limit`-sized UTF-16 slices.
    static func splitPlain(_ text: String, limit: Int) -> [String] {
        let length = JS.length(text)
        if length <= limit { return [text] }
        var out: [String] = []
        var i = 0
        while i < length {
            out.append(JS.slice(text, i, i + limit))
            i += max(limit, 1)
        }
        return out
    }

    // MARK: merge-text

    /// Merges a streaming chunk into the accumulator (delta and accumulated producers).
    static func mergeStreamingText(_ prev: String, _ next: String) -> String {
        if prev.isEmpty { return next }
        if next.isEmpty { return prev }
        let p = Array(prev.utf16), n = Array(next.utf16)
        if n.starts(with: p) { return next }
        if p.starts(with: n) { return prev }
        let maxOverlap = min(p.count, n.count)
        var len = maxOverlap
        while len > 0 {
            if p[(p.count - len)...].elementsEqual(n[0..<len]) {
                return prev + JS.slice(next, len)
            }
            len -= 1
        }
        return prev + next
    }

    // MARK: optimize-style

    private static let mark = "___CB_"
    private static let codeBlockPattern = JS.regex("(\\A|\\n)(`{3,})([^\\n]*)\\n[\\s\\S]*?\\n\\2(?=\\n|\\z)")
    private static let hasH1toH3 = JS.regex("\(JS.bol)#{1,3} ")
    private static let h2to6 = JS.regex("\(JS.bol)#{2,6} (\(JS.dot)+)\(JS.eol)")
    private static let h1 = JS.regex("\(JS.bol)# (\(JS.dot)+)\(JS.eol)")
    private static let consecutiveHeadings = JS.regex("\(JS.bol)(#{4,5} \(JS.dot)+)\\n{1,2}(#{4,5} )")
    private static let tableAfterText = JS.regex("\(JS.bol)([^|\\n]\(JS.dot)*)\\n(\\|\(JS.dot)+\\|)")
    private static let tableBlock = JS.regex("\\n\\n((?:\\|\(JS.dot)+\\|[\(JS.wsNoNewline)]*\\n?)+)")
    private static let tableRun = JS.regex("((?:\(JS.bol)\\|\(JS.dot)+\\|[\(JS.wsNoNewline)]*\\n?)+)")
    private static let leadingNewlines = JS.regex("\\A\\n+")
    private static let afterTable = JS.regex("\\A(---|#{4,5} |\\*\\*)")
    private static let tightenBefore = JS.regex("\(JS.bol)((?!#{4,5} )(?!\\*\\*)\(JS.dot)+)\\n\\n(<br>)\\n\\n(\\|)")
    private static let tightenBold = JS.regex("\(JS.bol)(\\*\\*\(JS.dot)+)\\n\\n(<br>)\\n\\n(\\|)")
    private static let tightenAfter = JS.regex("(\\|[^\\n]*\\n)\\n(<br>\\n)((?!#{4,5} )(?!\\*\\*))")
    private static let manyNewlines = JS.regex("\\n{3,}")

    /// Demotes headings and tidies blank lines so markdown renders well in a
    /// post `md` element (`cardVersion` 1) or CardKit v2 (`cardVersion` 2).
    static func optimizeMarkdownStyle(_ text: String, cardVersion: Int = 1) -> String {
        var codeBlocks: [String] = []
        var r = JS.replace(text, codeBlockPattern) { m, ns in
            let whole = ns.substring(with: m.range)
            let prefix = JS.group(m, 1, ns) ?? ""
            let block = JS.slice(whole, JS.length(prefix))
            codeBlocks.append(block)
            return "\(prefix)\(mark)\(codeBlocks.count - 1)___"
        }

        if JS.test(hasH1toH3, text) {
            r = JS.replace(r, h2to6, with: "##### $1")
            r = JS.replace(r, h1, with: "#### $1")
        }

        if cardVersion >= 2 {
            r = JS.replace(r, consecutiveHeadings, with: "$1\n<br>\n$2")
            r = JS.replace(r, tableAfterText, with: "$1\n\n$2")
            r = JS.replace(r, tableBlock, with: "\n\n<br>\n\n$1")
            let before = r
            r = JS.replace(r, tableRun) { m, ns in
                let whole = ns.substring(with: m.range)
                let rest = (before as NSString).substring(from: min(m.range.location + m.range.length, (before as NSString).length))
                let after = JS.replace(rest, leadingNewlines, with: "")
                if after.isEmpty || JS.test(afterTable, after) { return whole }
                return whole + "\n<br>\n"
            }
            r = JS.replace(r, tightenBefore, with: "$1\n$2\n$3")
            r = JS.replace(r, tightenBold, with: "$1\n$2\n\n$3")
            r = JS.replace(r, tightenAfter, with: "$1$2$3")
            for (i, block) in codeBlocks.enumerated() {
                r = JS.replaceFirst(r, "\(mark)\(i)___", "\n<br>\n\(block)\n<br>\n")
            }
        } else {
            for (i, block) in codeBlocks.enumerated() {
                r = JS.replaceFirst(r, "\(mark)\(i)___", block)
            }
        }

        return JS.replace(r, manyNewlines, with: "\n\n")
    }
}
