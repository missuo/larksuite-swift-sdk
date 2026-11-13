import Foundation

/// A type-erased, `Sendable` JSON value.
///
/// Used for loosely typed fields (`any` in the Open API schema), raw requests
/// and as an escape hatch for reading any response field that is not modelled.
@dynamicMemberLookup
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Accessors

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return JSONValue.formatNumber(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let n): return n.isFinite && n.rounded() == n && abs(n) < 9.3e18 ? Int(n) : nil
        case .string(let s): return Int(s) ?? Double(s).flatMap { $0.rounded() == $0 && abs($0) < 9.3e18 ? Int($0) : nil }
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    public subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            var obj = objectValue ?? [:]
            obj[key] = newValue
            self = .object(obj)
        }
    }

    public subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, a.indices.contains(index) else { return nil }
        return a[index]
    }

    public subscript(dynamicMember member: String) -> JSONValue? {
        self[member]
    }

    static func formatNumber(_ n: Double) -> String {
        if n.isFinite, n.rounded() == n, abs(n) < 9.007199254740992e15 {
            return String(Int64(n))
        }
        return String(n)
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .number(Double(i))
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.isFinite, n.rounded() == n, abs(n) < 9.007199254740992e15 {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Conversions

extension JSONValue {
    /// Parses raw JSON bytes.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parses a JSON string.
    public init(jsonString: String) throws {
        try self.init(data: Data(jsonString.utf8))
    }

    /// Converts any `Encodable` value into a `JSONValue`.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try LarkJSON.encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value into a `Decodable` type.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try LarkJSON.encoder.encode(self)
        return try LarkJSON.decoder.decode(T.self, from: data)
    }

    /// Serialises the value as compact JSON text.
    public func jsonString(sortedKeys: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = sortedKeys ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString() }
}

/// Shared JSON coders used by the SDK.
public enum LarkJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    public static var decoder: JSONDecoder { JSONDecoder() }

    /// Encodes a value as a JSON string (handy for message `content` fields).
    public static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
