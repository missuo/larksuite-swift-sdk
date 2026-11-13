import Foundation

/// The WHATWG `application/x-www-form-urlencoded` list behind JavaScript's `URLSearchParams`.
///
/// Used to reproduce node-sdk's wire output exactly: the registration request bodies
/// (`new URLSearchParams(params).toString()`) and the QR-code URL (`url.searchParams.set/append`,
/// which re-serialises the whole query of the URL).
struct FormURLEncoded: Sendable, Equatable {
    var items: [(name: String, value: String)]

    init(_ items: [(name: String, value: String)] = []) { self.items = items }

    static func == (lhs: FormURLEncoded, rhs: FormURLEncoded) -> Bool {
        lhs.items.map(\.name) == rhs.items.map(\.name) && lhs.items.map(\.value) == rhs.items.map(\.value)
    }

    /// The WHATWG urlencoded parser.
    init(parsing query: String) {
        var items: [(String, String)] = []
        for sequence in query.split(separator: "&", omittingEmptySubsequences: true) {
            let name: Substring
            let value: Substring
            if let eq = sequence.firstIndex(of: "=") {
                name = sequence[..<eq]
                value = sequence[sequence.index(after: eq)...]
            } else {
                name = sequence
                value = ""
            }
            items.append((Self.decode(name), Self.decode(value)))
        }
        self.items = items
    }

    /// `URLSearchParams.prototype.set`: replaces the first pair with `name` and drops the others,
    /// or appends when there is none.
    mutating func set(_ name: String, _ value: String) {
        guard let first = items.firstIndex(where: { $0.name == name }) else {
            items.append((name, value))
            return
        }
        items[first].value = value
        var i = items.index(after: first)
        while i < items.endIndex {
            if items[i].name == name { items.remove(at: i) } else { i = items.index(after: i) }
        }
    }

    /// `URLSearchParams.prototype.append`.
    mutating func append(_ name: String, _ value: String) { items.append((name, value)) }

    func get(_ name: String) -> String? { items.first { $0.name == name }?.value }
    func getAll(_ name: String) -> [String] { items.filter { $0.name == name }.map(\.value) }
    func has(_ name: String) -> Bool { items.contains { $0.name == name } }

    /// The WHATWG urlencoded serializer (`URLSearchParams.prototype.toString`).
    func serialized() -> String {
        items.map { "\(Self.encode($0.name))=\(Self.encode($0.value))" }.joined(separator: "&")
    }

    /// Percent-encodes with the `application/x-www-form-urlencoded` percent-encode set:
    /// only `*-._`, ASCII digits and letters are kept, and space becomes `+`.
    static func encode(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            switch byte {
            case 0x2A, 0x2D, 0x2E, 0x5F, 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case 0x20:
                out.append("+")
            default:
                out += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
            }
        }
        return out
    }

    /// `+` → space, then lenient percent-decoding (invalid escapes are kept verbatim).
    static func decode<S: StringProtocol>(_ string: S) -> String {
        var bytes: [UInt8] = []
        let input = Array(string.utf8)
        var i = 0
        while i < input.count {
            let b = input[i]
            if b == 0x2B {
                bytes.append(0x20)
            } else if b == 0x25, i + 2 < input.count, let h = hexValue(input[i + 1]), let l = hexValue(input[i + 2]) {
                bytes.append(h << 4 | l)
                i += 2
            } else {
                bytes.append(b)
            }
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}

/// An absolute URL whose query is edited through ``FormURLEncoded``, like `URL.searchParams`.
struct SearchParamsURL: Sendable {
    /// Everything before the query (`scheme://authority/path`).
    var base: String
    var query: FormURLEncoded
    /// The fragment including its leading `#`, if any.
    var fragment: String?

    /// Parses an absolute URL. Mirrors `new URL(string)` failing with "Invalid URL" for
    /// strings without a scheme and host.
    init?(_ string: String) {
        guard let url = URL(string: string), url.scheme != nil, url.host != nil else { return nil }
        var rest = Substring(string)
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[hash...])
            rest = rest[..<hash]
        }
        if let q = rest.firstIndex(of: "?") {
            query = FormURLEncoded(parsing: String(rest[rest.index(after: q)...]))
            rest = rest[..<q]
        } else {
            query = FormURLEncoded()
        }
        base = String(rest)
        // WHATWG URLs of special schemes always have a path: `https://host` → `https://host/`.
        if let schemeEnd = base.range(of: "://"), !base[schemeEnd.upperBound...].contains("/") {
            base += "/"
        }
    }

    var string: String {
        let q = query.serialized()
        return base + (q.isEmpty ? "" : "?" + q) + (fragment ?? "")
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
