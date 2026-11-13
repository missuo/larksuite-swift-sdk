import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP methods used by the Open Platform.
public struct HTTPMethod: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.uppercased() }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public static let get = HTTPMethod(rawValue: "GET")
    public static let post = HTTPMethod(rawValue: "POST")
    public static let put = HTTPMethod(rawValue: "PUT")
    public static let patch = HTTPMethod(rawValue: "PATCH")
    public static let delete = HTTPMethod(rawValue: "DELETE")
    public static let head = HTTPMethod(rawValue: "HEAD")
}

/// A fully resolved HTTP request handed to a ``LarkHTTPClient``.
public struct LarkHTTPRequest: Sendable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval?

    public init(method: HTTPMethod, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// A raw HTTP response returned from a ``LarkHTTPClient``.
public struct LarkHTTPResponse: Sendable {
    public var statusCode: Int
    /// Response headers. Keys are lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        self.headers = lowered
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Pluggable transport. The default implementation is ``URLSessionHTTPClient``;
/// provide your own to integrate AsyncHTTPClient, add proxies, retries, tracing, etc.
public protocol LarkHTTPClient: Sendable {
    func send(_ request: LarkHTTPRequest) async throws -> LarkHTTPResponse
}

/// `URLSession`-backed transport.
public final class URLSessionHTTPClient: LarkHTTPClient, @unchecked Sendable {
    public let session: URLSession
    public let defaultTimeout: TimeInterval

    public init(session: URLSession = URLSession(configuration: .default), defaultTimeout: TimeInterval = 60) {
        self.session = session
        self.defaultTimeout = defaultTimeout
    }

    public func send(_ request: LarkHTTPRequest) async throws -> LarkHTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method.rawValue
        r.timeoutInterval = request.timeout ?? defaultTimeout
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = request.body
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw LarkError.transport(message: "non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String { headers[k] = "\(v)" }
        }
        return LarkHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

// MARK: - URL helpers

public enum LarkURL {
    /// Percent-escapes a value for use as a single path segment.
    public static func escapePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Fills `:name` placeholders in a path template.
    ///
    /// Only treats `:name` as a placeholder when it starts a path segment, so
    /// `http://host:8080` style authorities are left untouched.
    public static func fillPath(_ template: String, _ values: [String: String]) throws -> String {
        var out = ""
        var segments = template.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for i in segments.indices where segments[i].hasPrefix(":") && segments[i].count > 1 {
            let key = String(segments[i].dropFirst())
            guard let v = values[key] else { throw LarkError.invalidArgument("request miss \(key) path argument") }
            segments[i] = escapePathSegment(v)
        }
        out = segments.joined(separator: "/")
        return out
    }

    /// Builds a query string with repeated keys for arrays (`a=1&a=2`).
    public static func queryItems(from value: JSONValue?) -> [URLQueryItem] {
        guard case .object(let obj)? = value else { return [] }
        var items: [URLQueryItem] = []
        for key in obj.keys.sorted() {
            let v = obj[key]!
            switch v {
            case .null: continue
            case .array(let arr):
                for e in arr {
                    if let s = scalarString(e) { items.append(URLQueryItem(name: key, value: s)) }
                }
            default:
                if let s = scalarString(v) { items.append(URLQueryItem(name: key, value: s)) }
            }
        }
        return items
    }

    private static func scalarString(_ v: JSONValue) -> String? {
        switch v {
        case .null: return nil
        case .object, .array: return v.jsonString()
        default: return v.stringValue
        }
    }

    static func percentEncodeQuery(_ items: [URLQueryItem]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return items.map { item in
            let n = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
            let v = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(n)=\(v)"
        }.joined(separator: "&")
    }
}
