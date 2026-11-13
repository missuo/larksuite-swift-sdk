import Foundation

/// A decoded Open API response (`{code, msg, data}`).
public struct LarkResponse<T: Decodable & Sendable>: Sendable {
    public let code: Int
    public let msg: String
    /// Decoded `data` field.
    public let data: T?
    public let httpStatus: Int
    /// Response headers (lower-cased keys).
    public let headers: [String: String]
    /// Raw response body.
    public let body: Data

    /// The `X-Tt-Logid` header; include it when contacting support.
    public var logId: String? { headers["x-tt-logid"] }
    /// `true` when `code == 0`.
    public var success: Bool { code == 0 }
    /// The whole response body as untyped JSON (for fields outside `data`).
    public var json: JSONValue? { try? JSONValue(data: body) }

    public init(code: Int, msg: String, data: T?, httpStatus: Int, headers: [String: String], body: Data) {
        self.code = code
        self.msg = msg
        self.data = data
        self.httpStatus = httpStatus
        self.headers = headers
        self.body = body
    }

    private struct Envelope: Decodable {
        var code: Int?
        var msg: String?
        var data: T?

        enum CodingKeys: String, CodingKey { case code, msg, data }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = c.lenient(.code)
            msg = c.lenient(.msg)
            if c.contains(.data), (try? c.decodeNil(forKey: .data)) != true {
                data = try c.decode(T.self, forKey: .data)
            }
        }
    }

    /// Decodes an HTTP response, throwing for business or HTTP errors.
    public static func decode(_ resp: LarkHTTPResponse, logger: LoggerProxy? = nil) throws -> LarkResponse<T> {
        let ok = (200..<300).contains(resp.statusCode)
        let envelope: Envelope
        do {
            envelope = try LarkJSON.decoder.decode(Envelope.self, from: resp.body)
        } catch {
            if !ok {
                logger?.error("http error \(resp.statusCode): \(String(decoding: resp.body.prefix(1024), as: UTF8.self))")
                throw LarkError.http(statusCode: resp.statusCode, headers: resp.headers, body: resp.body)
            }
            if resp.body.isEmpty {
                return LarkResponse(code: 0, msg: "", data: nil, httpStatus: resp.statusCode, headers: resp.headers, body: resp.body)
            }
            // Try to surface an API error even if `data` failed to decode.
            if let json = try? JSONValue(data: resp.body), let code = json["code"]?.intValue, code != 0 {
                throw LarkError.api(
                    LarkAPIError(
                        code: code, msg: json["msg"]?.stringValue ?? "", httpStatus: resp.statusCode,
                        logId: resp.header("x-tt-logid"), headers: resp.headers, body: resp.body))
            }
            throw LarkError.decoding(message: "\(error)", body: resp.body)
        }
        let code = envelope.code ?? 0
        if code != 0 {
            let e = LarkAPIError(
                code: code, msg: envelope.msg ?? "", httpStatus: resp.statusCode, logId: resp.header("x-tt-logid"),
                headers: resp.headers, body: resp.body)
            logger?.error("\(e)")
            throw LarkError.api(e)
        }
        if !ok {
            throw LarkError.http(statusCode: resp.statusCode, headers: resp.headers, body: resp.body)
        }
        return LarkResponse(
            code: code, msg: envelope.msg ?? "", data: envelope.data, httpStatus: resp.statusCode, headers: resp.headers,
            body: resp.body)
    }
}

/// A binary (file download) response.
public struct LarkBinaryResponse: Sendable {
    public let statusCode: Int
    /// Response headers (lower-cased keys).
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String], data: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }

    public var contentType: String? { headers["content-type"] }

    /// File name parsed from `Content-Disposition`, if present.
    public var fileName: String? {
        guard let cd = headers["content-disposition"] else { return nil }
        for part in cd.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.lowercased().hasPrefix("filename*=") {
                let v = part.dropFirst("filename*=".count)
                if let r = v.range(of: "''") {
                    return String(v[r.upperBound...]).removingPercentEncoding
                }
            }
        }
        for part in cd.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.lowercased().hasPrefix("filename=") {
                var v = String(part.dropFirst("filename=".count))
                if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                return v.removingPercentEncoding ?? v
            }
        }
        return nil
    }

    /// Writes the file to disk (mirrors `writeFile` in the Node SDK).
    @discardableResult
    public func write(to url: URL) throws -> URL {
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Writes the file to a path on disk.
    @discardableResult
    public func writeFile(_ path: String) throws -> URL {
        try write(to: URL(fileURLWithPath: path))
    }
}
