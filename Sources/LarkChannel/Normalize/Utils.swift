import Foundation

/// Port of node-sdk `channel/normalize/utils.ts`.
enum NormalizeUtils {
    /// `JSON.parse` that returns `nil` on empty / invalid input.
    static func safeParse(_ raw: String) -> OrderedJSON? {
        if raw.isEmpty { return nil }
        return OrderedJSON.parse(raw)
    }

    /// Wraps text in Markdown / HTML for post `style` flags.
    static func applyStyle(_ text: String, _ style: [String]?) -> String {
        guard let style, !style.isEmpty else { return text }
        var out = text
        if style.contains("bold") { out = "**\(out)**" }
        if style.contains("italic") { out = "*\(out)*" }
        if style.contains("underline") { out = "<u>\(out)</u>" }
        if style.contains("lineThrough") || style.contains("strikethrough") { out = "~~\(out)~~" }
        if style.contains("codeInline") || style.contains("code") { out = "`\(out)`" }
        return out
    }

    static let localePriority = ["zh_cn", "en_us", "ja_jp"]

    /// Picks the locale body of a post (`{zh_cn: {...}}`) or the body itself.
    static func unwrapLocale(_ parsed: OrderedJSON) -> OrderedJSON? {
        if parsed.has("title") || parsed.has("content") { return parsed }
        for loc in localePriority {
            if let hit = parsed[loc], hit.isObjectLike { return hit }
        }
        if case .array(let items) = parsed {
            // `Object.keys(array)[0]` is "0".
            if let first = items.first, first.isObjectLike { return first }
            return nil
        }
        if let firstKey = parsed.keys.first, !firstKey.isEmpty {
            if let first = parsed[firstKey], first.isObjectLike { return first }
        }
        return nil
    }

    /// `1500` → `1.5s`, `1000` → `1s`, `800` → `800ms`.
    static func formatDuration(_ ms: Double?) -> String? {
        guard let ms, ms.isFinite, ms >= 0 else { return nil }
        if ms < 1000 { return "\(JS.numberString((ms + 0.5).rounded(.down)))ms" }
        if ms.truncatingRemainder(dividingBy: 1000) == 0 { return "\(JS.numberString(ms / 1000))s" }
        return "\(JS.toFixed1(ms / 1000))s"
    }

    /// Milliseconds (number or numeric string) → `YYYY-MM-DD HH:mm` in UTC+8.
    static func millisToDatetime(_ value: OrderedJSON?) -> String? {
        guard let value, !value.isNull else { return nil }
        let n: Double?
        switch value {
        case .string(let s): n = JS.parseInt(s)
        case .number(let d): n = d
        default: n = nil  // `Number.isFinite` rejects non-numbers
        }
        guard let n, n.isFinite, n > 0 else { return nil }
        if n + 8 * 3_600_000 > 8.64e15 { return "NaN-NaN-NaN NaN:NaN" }  // Invalid Date
        let c = beijingComponents(n)
        return "\(c.year)-\(pad(c.month))-\(pad(c.day)) \(pad(c.hour)):\(pad(c.minute))"
    }

    /// Milliseconds → RFC 3339 in UTC+8 (`2024-01-01T08:00:00+08:00`).
    static func formatRFC3339Beijing(_ ms: Double) -> String {
        if !ms.isFinite || abs(ms + 8 * 3_600_000) > 8.64e15 { return "NaN-NaN-NaNTNaN:NaN:NaN+08:00" }
        let c = beijingComponents(ms)
        return "\(c.year)-\(pad(c.month))-\(pad(c.day))T\(pad(c.hour)):\(pad(c.minute)):\(pad(c.second))+08:00"
    }

    static func indentLines(_ text: String, _ indent: String) -> String {
        JS.splitLines(text).map { indent + $0 }.joined(separator: "\n")
    }

    static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func pad(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    private struct Components {
        var year, month, day, hour, minute, second: Int
    }

    /// UTC calendar fields of `ms + 8h` (the `getUTC*` accessors), computed
    /// with exact integer arithmetic (days-from-civil inverse).
    private static func beijingComponents(_ ms: Double) -> Components {
        // JS `new Date(n)` truncates the time value to an integer.
        let shifted = Int64((ms + 8 * 3_600_000).rounded(.towardZero))
        let msPerDay: Int64 = 86_400_000
        var days = shifted / msPerDay
        var rem = shifted % msPerDay
        if rem < 0 {
            rem += msPerDay
            days -= 1
        }
        let second = Int(rem / 1000 % 60)
        let minute = Int(rem / 60_000 % 60)
        let hour = Int(rem / 3_600_000)
        // civil_from_days (Howard Hinnant).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = Int(doy - (153 * mp + 2) / 5 + 1)
        let month = Int(mp < 10 ? mp + 3 : mp - 9)
        let year = Int(yoe + era * 400 + (month <= 2 ? 1 : 0))
        return Components(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }
}
