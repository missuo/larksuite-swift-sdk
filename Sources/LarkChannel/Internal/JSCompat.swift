import Foundation

/// Small helpers that reproduce JavaScript semantics the node-sdk channel
/// relies on (UTF-16 string lengths, `parseInt`, `Number#toString`,
/// `Number#toFixed`, `String#trim`, `String#replace` substitutions, regexes).
///
/// The channel measures and slices text in UTF-16 code units exactly like
/// node-sdk (`str.length`, `str.slice`). Slicing in the middle of a surrogate
/// pair produces U+FFFD in Swift (a JS string would keep a lone surrogate).
enum JS {
    // MARK: Whitespace

    /// JS `\s` / `String#trim` whitespace set (WhiteSpace + LineTerminator).
    static let whitespaceScalars: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
    ]

    /// ICU character class body equivalent to JS `\s`.
    static let ws = #"\t\n\u000B\f\r    -     　﻿"#
    /// ICU class body equivalent to JS `[^\S\n]` (whitespace except `\n`).
    static let wsNoNewline = #"\t\u000B\f\r    -     　﻿"#
    /// ICU pattern equivalent to JS `.` (anything but a JS line terminator).
    static let dot = #"[^\n\r  ]"#
    /// ICU pattern equivalent to JS `^` under the `m` flag.
    static let bol = #"(?:\A|(?<=[\n\r  ]))"#
    /// ICU pattern equivalent to JS `$` under the `m` flag.
    static let eol = #"(?=[\n\r  ]|\z)"#

    static func isWhitespace(_ u: UInt16) -> Bool { whitespaceScalars.contains(UInt32(u)) }

    /// `String.prototype.trim`.
    static func trim(_ s: String) -> String {
        let units = Array(s.utf16)
        var start = 0
        var end = units.count
        while start < end && isWhitespace(units[start]) { start += 1 }
        while end > start && isWhitespace(units[end - 1]) { end -= 1 }
        if start == 0 && end == units.count { return s }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    // MARK: UTF-16 length / slicing

    /// `str.length`.
    @inline(__always) static func length(_ s: String) -> Int { s.utf16.count }

    /// `str.slice(start, end)` with non-negative indices.
    static func slice(_ s: String, _ start: Int, _ end: Int? = nil) -> String {
        let u = s.utf16
        let count = u.count
        let lo = max(0, min(start, count))
        let hi = max(lo, min(end ?? count, count))
        if lo == 0 && hi == count { return s }
        let a = u.index(u.startIndex, offsetBy: lo)
        let b = u.index(u.startIndex, offsetBy: hi)
        if let str = String(u[a..<b]) { return str }
        return String(decoding: Array(u[a..<b]), as: UTF16.self)
    }

    /// `str.split('\n')` on UTF-16 code units (keeps empty pieces and `\r`).
    static func splitLines(_ s: String) -> [String] {
        var out: [String] = []
        var cur: [UInt16] = []
        for u in s.utf16 {
            if u == 0x0A {
                out.append(String(decoding: cur, as: UTF16.self))
                cur.removeAll(keepingCapacity: true)
            } else {
                cur.append(u)
            }
        }
        out.append(String(decoding: cur, as: UTF16.self))
        return out
    }

    // MARK: Numbers

    /// `parseInt(str, 10)`; `nil` stands for `NaN`.
    static func parseInt(_ s: String) -> Double? {
        let units = Array(s.utf16)
        var i = 0
        while i < units.count && isWhitespace(units[i]) { i += 1 }
        var negative = false
        if i < units.count && (units[i] == 0x2B || units[i] == 0x2D) {
            negative = units[i] == 0x2D
            i += 1
        }
        var value: Double = 0
        var digits = 0
        while i < units.count, units[i] >= 0x30, units[i] <= 0x39 {
            value = value * 10 + Double(units[i] - 0x30)
            digits += 1
            i += 1
        }
        if digits == 0 { return nil }
        return negative ? -value : value
    }

    /// `parseInt(x, 10)` producing an integer when finite.
    static func parseIntValue(_ s: String?) -> Int? {
        guard let s, let d = parseInt(s), d.isFinite, abs(d) < 9.2e18 else { return nil }
        return Int(d)
    }

    /// `Number.prototype.toString()` (and `String(n)` / template interpolation).
    static func numberString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return "0" }
        let negative = d < 0
        let desc = "\(abs(d))"
        // Swift prints the shortest round-trip digits; re-layout them JS style.
        var mantissa = desc
        var exp = 0
        if let eIdx = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(desc[..<eIdx])
            exp = Int(desc[desc.index(after: eIdx)...]) ?? 0
        }
        var intPart = mantissa
        var fracPart = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = String(mantissa[..<dot])
            fracPart = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = intPart + fracPart
        var n = intPart.count + exp  // decimal point position relative to digits start
        // Strip leading zeros.
        while digits.hasPrefix("0") && digits.count > 1 {
            digits.removeFirst()
            n -= 1
        }
        // Strip trailing zeros.
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        let k = digits.count
        var out: String
        if k <= n && n <= 21 {
            out = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let idx = digits.index(digits.startIndex, offsetBy: n)
            out = String(digits[..<idx]) + "." + String(digits[idx...])
        } else if -6 < n && n <= 0 {
            out = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            if k == 1 {
                out = digits + "e" + sign + String(abs(e))
            } else {
                out = String(digits.prefix(1)) + "." + String(digits.dropFirst()) + "e" + sign + String(abs(e))
            }
        }
        return negative ? "-" + out : out
    }

    /// `x.toFixed(1)` for finite, non-negative `x` below 1e21.
    static func toFixed1(_ x: Double) -> String {
        // printf rounds exact ties to even; JS picks the larger candidate.
        let quadruple = x * 4
        if quadruple == quadruple.rounded(), quadruple.truncatingRemainder(dividingBy: 2) == 1 {
            let n = (x * 10).rounded(.down) + 1
            return String(format: "%.1f", n / 10)
        }
        return String(format: "%.1f", x)
    }

    // MARK: Truthiness / interpolation

    /// JS truthiness of an optional JSON value (`undefined` is `nil`).
    static func truthy(_ v: OrderedJSON?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// `String(value)` / template-literal interpolation.
    static func interpolate(_ v: OrderedJSON?) -> String {
        guard let v else { return "undefined" }
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return numberString(n)
        case .string(let s): return s
        case .array(let a):
            return a.map { e -> String in
                if case .null = e { return "" }
                return interpolate(e)
            }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// `x ?? fallback` followed by interpolation: `null`/`undefined` → fallback.
    static func string(_ v: OrderedJSON?, default fallback: String) -> String {
        guard let v, !v.isNull else { return fallback }
        return interpolate(v)
    }

    /// Non-nullish string-ish value (`undefined`/`null` → nil).
    static func optionalString(_ v: OrderedJSON?) -> String? {
        guard let v, !v.isNull else { return nil }
        return interpolate(v)
    }

    // MARK: Regex helpers

    static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants (or escaped user input); failure is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    static func test(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// `str.replace(globalRegex, replacement)` using JS `GetSubstitution` rules.
    static func replace(_ s: String, _ re: NSRegularExpression, with template: String) -> String {
        replace(s, re) { match, ns in substitute(template, match: match, in: ns) }
    }

    /// `str.replace(globalRegex, fn)`; the closure receives the match and the input.
    static func replace(_ s: String, _ re: NSRegularExpression, _ fn: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += fn(m, ns)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// The text of capture group `i`, or `nil` when it did not participate.
    static func group(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String? {
        guard i < m.numberOfRanges else { return nil }
        let r = m.range(at: i)
        if r.location == NSNotFound { return nil }
        return ns.substring(with: r)
    }

    /// `GetSubstitution` for a regex match.
    static func substitute(_ template: String, match m: NSTextCheckingResult, in ns: NSString) -> String {
        let t = Array(template.utf16)
        if !t.contains(0x24) { return template }
        var out: [UInt16] = []
        var i = 0
        let groups = m.numberOfRanges - 1
        while i < t.count {
            let c = t[i]
            guard c == 0x24, i + 1 < t.count else {
                out.append(c)
                i += 1
                continue
            }
            let n = t[i + 1]
            switch n {
            case 0x24:  // $$
                out.append(0x24)
                i += 2
            case 0x26:  // $&
                out += Array(ns.substring(with: m.range).utf16)
                i += 2
            case 0x60:  // $`
                out += Array(ns.substring(to: m.range.location).utf16)
                i += 2
            case 0x27:  // $'
                out += Array(ns.substring(from: m.range.location + m.range.length).utf16)
                i += 2
            case 0x30...0x39:
                // Two-digit group if valid, else one digit.
                var consumed = 0
                var index = 0
                if i + 2 < t.count, t[i + 2] >= 0x30, t[i + 2] <= 0x39 {
                    let two = Int(n - 0x30) * 10 + Int(t[i + 2] - 0x30)
                    if two >= 1 && two <= groups {
                        index = two
                        consumed = 3
                    }
                }
                if consumed == 0 {
                    let one = Int(n - 0x30)
                    if one >= 1 && one <= groups {
                        index = one
                        consumed = 2
                    }
                }
                if consumed == 0 {
                    out.append(c)
                    i += 1
                } else {
                    out += Array((group(m, index, ns) ?? "").utf16)
                    i += consumed
                }
            default:
                out.append(c)
                i += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// `str.replace(searchString, replacement)` — first occurrence only, with
    /// `GetSubstitution` applied to `replacement` (no capture groups).
    static func replaceFirst(_ s: String, _ search: String, _ replacement: String) -> String {
        let ns = s as NSString
        let r = ns.range(of: search, options: .literal)
        if r.location == NSNotFound { return s }
        let re = regex(NSRegularExpression.escapedPattern(for: search))
        guard let m = re.firstMatch(in: s, options: [], range: r) else { return s }
        let sub = substitute(replacement, match: m, in: ns)
        return ns.replacingCharacters(in: r, with: sub)
    }

    /// `str.split(sep).join(replacement)` (literal, non-overlapping, left to right).
    static func replaceAll(_ s: String, _ sep: String, _ replacement: String) -> String {
        if sep.isEmpty {
            let units = Array(s.utf16)
            return units.map { String(decoding: [$0], as: UTF16.self) }.joined(separator: replacement)
        }
        return (s as NSString).replacingOccurrences(of: sep, with: replacement, options: .literal, range: NSRange(location: 0, length: (s as NSString).length))
    }
}
