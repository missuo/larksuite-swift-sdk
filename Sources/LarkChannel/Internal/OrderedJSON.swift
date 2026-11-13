import Foundation
import LarkCore

/// A JSON value that keeps object keys in insertion order, mirroring a
/// JavaScript object. The channel uses it wherever node-sdk's behaviour
/// depends on key order (`JSON.stringify` output on the wire, "first key"
/// lookups in `unwrapLocale`).
///
/// Values coming from the public API as ``JSONValue`` (whose objects are
/// unordered) are converted with their keys sorted, which keeps
/// serialisation deterministic.
indirect enum OrderedJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    struct Member: Sendable, Equatable {
        var key: String
        var value: OrderedJSON
    }

    // MARK: Construction

    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .number(let n): self = .number(n)
        case .string(let s): self = .string(s)
        case .array(let a): self = .array(a.map(OrderedJSON.init))
        case .object(let o):
            self = .object(o.keys.sorted().map { Member(key: $0, value: OrderedJSON(o[$0]!)) })
        }
    }

    /// Builds an object from ordered pairs (later duplicates overwrite in place).
    static func obj(_ pairs: KeyValuePairs<String, OrderedJSON>) -> OrderedJSON {
        var o = OrderedJSON.object([])
        for (k, v) in pairs { o[k] = v }
        return o
    }

    var jsonValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(\.jsonValue))
        case .object(let members):
            var d: [String: JSONValue] = [:]
            for m in members { d[m.key] = m.value.jsonValue }
            return .object(d)
        }
    }

    // MARK: Access

    var isNull: Bool { if case .null = self { return true } else { return false } }
    var isObject: Bool { if case .object = self { return true } else { return false } }
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var arrayValue: [OrderedJSON]? { if case .array(let a) = self { return a } else { return nil } }
    var members: [Member]? { if case .object(let m) = self { return m } else { return nil } }
    var keys: [String] { members?.map(\.key) ?? [] }

    /// JS `typeof x === 'object' && x !== null` (objects and arrays).
    var isObjectLike: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    func has(_ key: String) -> Bool { members?.contains { $0.key == key } ?? false }

    subscript(key: String) -> OrderedJSON? {
        get { members?.first { $0.key == key }?.value }
        set {
            var m = members ?? []
            if let i = m.firstIndex(where: { $0.key == key }) {
                if let newValue { m[i].value = newValue } else { m.remove(at: i) }
            } else if let newValue {
                m.append(Member(key: key, value: newValue))
            }
            self = .object(m)
        }
    }

    /// Optional-chaining helper: `value?.a?.b`.
    subscript(path first: String, _ rest: String...) -> OrderedJSON? {
        var cur = self[first]
        for k in rest { cur = cur?[k] }
        return cur
    }

    // MARK: Serialisation (JSON.stringify)

    /// `JSON.stringify(value)`.
    func stringify() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.isFinite ? JS.numberString(n) : "null"
        case .string(let s): OrderedJSON.quote(s, into: &out)
        case .array(let a):
            out += "["
            for (i, e) in a.enumerated() {
                if i > 0 { out += "," }
                e.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, m) in members.enumerated() {
                if i > 0 { out += "," }
                OrderedJSON.quote(m.key, into: &out)
                out += ":"
                m.value.write(into: &out)
            }
            out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: Parsing (JSON.parse)

    /// `JSON.parse(text)`; returns `nil` where JS would throw.
    static func parse(_ text: String) -> OrderedJSON? {
        var p = Parser(Array(text.utf16))
        p.skipWS()
        guard let v = p.parseValue() else { return nil }
        p.skipWS()
        return p.atEnd ? v : nil
    }

    private struct Parser {
        let u: [UInt16]
        var i = 0
        init(_ u: [UInt16]) { self.u = u }

        var atEnd: Bool { i >= u.count }

        mutating func skipWS() {
            while i < u.count, u[i] == 0x20 || u[i] == 0x09 || u[i] == 0x0A || u[i] == 0x0D { i += 1 }
        }

        mutating func parseValue() -> OrderedJSON? {
            guard i < u.count else { return nil }
            switch u[i] {
            case 0x7B: return parseObject()
            case 0x5B: return parseArray()
            case 0x22: return parseString().map(OrderedJSON.string)
            case 0x74: return literal("true", .bool(true))
            case 0x66: return literal("false", .bool(false))
            case 0x6E: return literal("null", .null)
            default: return parseNumber()
            }
        }

        mutating func literal(_ word: String, _ v: OrderedJSON) -> OrderedJSON? {
            let w = Array(word.utf16)
            guard i + w.count <= u.count, Array(u[i..<(i + w.count)]) == w else { return nil }
            i += w.count
            return v
        }

        mutating func parseNumber() -> OrderedJSON? {
            let start = i
            if i < u.count, u[i] == 0x2D { i += 1 }
            guard i < u.count, isDigit(u[i]) else { return nil }
            if u[i] == 0x30 {
                i += 1
            } else {
                while i < u.count, isDigit(u[i]) { i += 1 }
            }
            if i < u.count, u[i] == 0x2E {
                i += 1
                guard i < u.count, isDigit(u[i]) else { return nil }
                while i < u.count, isDigit(u[i]) { i += 1 }
            }
            if i < u.count, u[i] == 0x65 || u[i] == 0x45 {
                i += 1
                if i < u.count, u[i] == 0x2B || u[i] == 0x2D { i += 1 }
                guard i < u.count, isDigit(u[i]) else { return nil }
                while i < u.count, isDigit(u[i]) { i += 1 }
            }
            let s = String(decoding: u[start..<i], as: UTF16.self)
            guard let d = Double(s) else { return nil }
            return .number(d)
        }

        func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

        mutating func parseString() -> String? {
            guard i < u.count, u[i] == 0x22 else { return nil }
            i += 1
            var out: [UInt16] = []
            while i < u.count {
                let c = u[i]
                if c == 0x22 {
                    i += 1
                    return String(decoding: out, as: UTF16.self)
                }
                if c < 0x20 { return nil }
                if c == 0x5C {
                    i += 1
                    guard i < u.count else { return nil }
                    let e = u[i]
                    switch e {
                    case 0x22: out.append(0x22)
                    case 0x5C: out.append(0x5C)
                    case 0x2F: out.append(0x2F)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    case 0x75:
                        guard i + 4 < u.count else { return nil }
                        let hex = String(decoding: u[(i + 1)...(i + 4)], as: UTF16.self)
                        guard let v = UInt16(hex, radix: 16) else { return nil }
                        out.append(v)
                        i += 4
                    default: return nil
                    }
                    i += 1
                    continue
                }
                out.append(c)
                i += 1
            }
            return nil
        }

        mutating func parseArray() -> OrderedJSON? {
            i += 1
            var items: [OrderedJSON] = []
            skipWS()
            if i < u.count, u[i] == 0x5D {
                i += 1
                return .array(items)
            }
            while true {
                skipWS()
                guard let v = parseValue() else { return nil }
                items.append(v)
                skipWS()
                guard i < u.count else { return nil }
                if u[i] == 0x2C {
                    i += 1
                    continue
                }
                if u[i] == 0x5D {
                    i += 1
                    return .array(items)
                }
                return nil
            }
        }

        mutating func parseObject() -> OrderedJSON? {
            i += 1
            var obj = OrderedJSON.object([])
            skipWS()
            if i < u.count, u[i] == 0x7D {
                i += 1
                return obj
            }
            while true {
                skipWS()
                guard let key = parseString() else { return nil }
                skipWS()
                guard i < u.count, u[i] == 0x3A else { return nil }
                i += 1
                skipWS()
                guard let v = parseValue() else { return nil }
                obj[key] = v
                skipWS()
                guard i < u.count else { return nil }
                if u[i] == 0x2C {
                    i += 1
                    continue
                }
                if u[i] == 0x7D {
                    i += 1
                    return obj
                }
                return nil
            }
        }
    }
}

extension OrderedJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: OrderedJSON...) { self = .array(elements) }
}
