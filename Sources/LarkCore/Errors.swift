import Foundation

/// A business error returned by the Open Platform (`code != 0`).
public struct LarkAPIError: Error, Sendable, CustomStringConvertible {
    /// Business error code. See https://open.feishu.cn/document/server-docs/api-call-guide/generic-error-code
    public let code: Int
    public let msg: String
    public let httpStatus: Int
    /// The `X-Tt-Logid` response header; include it when contacting support.
    public let logId: String?
    /// Raw response headers (lower-cased keys).
    public let headers: [String: String]
    /// Raw response body.
    public let body: Data

    public init(code: Int, msg: String, httpStatus: Int, logId: String?, headers: [String: String], body: Data) {
        self.code = code
        self.msg = msg
        self.httpStatus = httpStatus
        self.logId = logId
        self.headers = headers
        self.body = body
    }

    /// The parsed response body, including any `error` troubleshooting details.
    public var json: JSONValue? { try? JSONValue(data: body) }

    public var description: String {
        var s = "LarkAPIError(code: \(code), msg: \(msg), httpStatus: \(httpStatus)"
        if let logId { s += ", logId: \(logId)" }
        if let troubleshooter = json?["error"]?["troubleshooter"]?.stringValue { s += ", troubleshooter: \(troubleshooter)" }
        return s + ")"
    }
}

/// Errors thrown by the SDK.
public enum LarkError: Error, Sendable, CustomStringConvertible {
    /// The server returned a non-zero business code.
    case api(LarkAPIError)
    /// The server returned a non-2xx status without a recognizable Lark error body.
    case http(statusCode: Int, headers: [String: String], body: Data)
    /// The response body could not be decoded.
    case decoding(message: String, body: Data)
    /// The transport failed (network, TLS, ...).
    case transport(message: String)
    /// An argument passed to the SDK was invalid.
    case invalidArgument(String)
    /// The SDK could not obtain an access token.
    case tokenUnavailable(String)
    /// ClientAssertion (keyless) credential chain failure (codes 7100-7104).
    case clientAssertion(code: Int, msg: String)
    /// `/oauth/v3/token` returned an error.
    case accessToken(statusCode: Int, code: Int, error: String, errorDescription: String)
    /// Event / card callback verification failed.
    case verificationFailed(String)
    /// The operation is not supported in the current configuration.
    case unsupported(String)

    public var description: String {
        switch self {
        case .api(let e): return e.description
        case .http(let status, _, let body):
            return "LarkError.http(status: \(status), body: \(String(decoding: body.prefix(512), as: UTF8.self)))"
        case .decoding(let m, _): return "LarkError.decoding(\(m))"
        case .transport(let m): return "LarkError.transport(\(m))"
        case .invalidArgument(let m): return "LarkError.invalidArgument(\(m))"
        case .tokenUnavailable(let m): return "LarkError.tokenUnavailable(\(m))"
        case .clientAssertion(let code, let msg): return "LarkError.clientAssertion(code: \(code), msg: \(msg))"
        case .accessToken(let status, let code, let error, let desc):
            return "LarkError.accessToken(status: \(status), code: \(code), error: \(error), description: \(desc))"
        case .verificationFailed(let m): return "LarkError.verificationFailed(\(m))"
        case .unsupported(let m): return "LarkError.unsupported(\(m))"
        }
    }

    /// The business error if this is an API error.
    public var apiError: LarkAPIError? {
        if case .api(let e) = self { return e }
        return nil
    }
}

/// ClientAssertion error codes, matching the other official SDKs.
public enum ClientAssertionErrorCode {
    public static let providerNotConfigured = 7100
    public static let tokenEmpty = 7101
    public static let retrieveFailed = 7102
    public static let modeNotSupported = 7103
    public static let appSecretAndClientAssertionEmpty = 7104
}
