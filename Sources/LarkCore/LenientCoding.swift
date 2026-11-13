import Foundation

/// Types that can be recovered from a JSON value whose shape does not match
/// the declared schema exactly (e.g. a number sent as a string).
public protocol LarkCoercible {
    static func coerce(from value: JSONValue) -> Self?
}

extension String: LarkCoercible {
    public static func coerce(from value: JSONValue) -> String? {
        switch value {
        case .object, .array: return value.jsonString()
        default: return value.stringValue
        }
    }
}

extension Int: LarkCoercible {
    public static func coerce(from value: JSONValue) -> Int? { value.intValue }
}

extension Int64: LarkCoercible {
    public static func coerce(from value: JSONValue) -> Int64? { value.intValue.map(Int64.init) }
}

extension Double: LarkCoercible {
    public static func coerce(from value: JSONValue) -> Double? { value.doubleValue }
}

extension Bool: LarkCoercible {
    public static func coerce(from value: JSONValue) -> Bool? { value.boolValue }
}

extension JSONValue: LarkCoercible {
    public static func coerce(from value: JSONValue) -> JSONValue? { value }
}

extension Array: LarkCoercible where Element: Decodable {
    public static func coerce(from value: JSONValue) -> [Element]? {
        switch value {
        case .array(let items):
            return items.compactMap { LarkCoercion.coerce($0, to: Element.self) }
        case .null:
            return nil
        default:
            // A single value where an array was expected.
            return LarkCoercion.coerce(value, to: Element.self).map { [$0] }
        }
    }
}

extension Dictionary: LarkCoercible where Key == String, Value: Decodable {
    public static func coerce(from value: JSONValue) -> [String: Value]? {
        guard case .object(let obj) = value else { return nil }
        var out: [String: Value] = [:]
        for (k, v) in obj {
            if let c = LarkCoercion.coerce(v, to: Value.self) { out[k] = c }
        }
        return out
    }
}

public enum LarkCoercion {
    public static func coerce<T: Decodable>(_ value: JSONValue, to type: T.Type) -> T? {
        if let direct = try? value.decode(as: T.self) { return direct }
        if let c = T.self as? LarkCoercible.Type, let v = c.coerce(from: value) as? T { return v }
        return nil
    }
}

extension KeyedDecodingContainer {
    /// Decodes an optional value, tolerating schema mismatches.
    ///
    /// A missing key, `null`, or a value that cannot be coerced into `T`
    /// yields `nil` instead of failing the whole response.
    @inlinable
    public func lenient<T: Decodable>(_ key: Key) -> T? {
        guard contains(key) else { return nil }
        if (try? decodeNil(forKey: key)) == true { return nil }
        if let v = try? decode(T.self, forKey: key) { return v }
        guard let raw = try? decode(JSONValue.self, forKey: key) else { return nil }
        return LarkCoercion.coerce(raw, to: T.self)
    }

    /// Decodes a required value, tolerating representation mismatches but
    /// throwing when the key is absent.
    @inlinable
    public func lenientRequired<T: Decodable>(_ key: Key) throws -> T {
        if let v: T = lenient(key) { return v }
        if contains(key) {
            return try decode(T.self, forKey: key)
        }
        throw DecodingError.keyNotFound(
            key, .init(codingPath: codingPath, debugDescription: "Missing required key \(key.stringValue)"))
    }
}

/// Marker for open string enumerations generated from the Open API schema.
///
/// Open enums accept any raw value so that new server-side values never break
/// decoding, while still offering well-known values as static members.
public protocol LarkOpenEnum: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible, LarkCoercible where RawValue == String
{
    init(rawValue: String)
}

extension LarkOpenEnum {
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self.init(rawValue: s)
        } else if let raw = try? c.decode(JSONValue.self), let s = raw.stringValue {
            self.init(rawValue: s)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected string enum value")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
    public static func coerce(from value: JSONValue) -> Self? { value.stringValue.map(Self.init(rawValue:)) }
}
