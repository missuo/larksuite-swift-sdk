import Foundation

/// Error thrown / emitted by the channel (node-sdk `LarkChannelError`).
public struct LarkChannelError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// Stable error codes (node-sdk `LarkChannelErrorCode`).
    public enum Code: String, Sendable, Hashable {
        case formatError = "format_error"
        case targetRevoked = "target_revoked"
        case rateLimited = "rate_limited"
        case permissionDenied = "permission_denied"
        case uploadFailed = "upload_failed"
        case ssrfBlocked = "ssrf_blocked"
        case sendTimeout = "send_timeout"
        case notConnected = "not_connected"
        case unknown
    }

    /// Where the error happened.
    public struct Context: Sendable, Hashable {
        public var to: String?
        public var messageId: String?
        public var attempt: Int?
        public init(to: String? = nil, messageId: String? = nil, attempt: Int? = nil) {
            self.to = to
            self.messageId = messageId
            self.attempt = attempt
        }
    }

    public var code: Code
    public var message: String
    /// The underlying error, if any.
    public var cause: (any Error)?
    public var context: Context?

    public init(_ code: Code, _ message: String, cause: (any Error)? = nil, context: Context? = nil) {
        self.code = code
        self.message = message
        self.cause = cause
        self.context = context
    }

    public var description: String { "LarkChannelError(\(code.rawValue)): \(message)" }
    public var errorDescription: String? { message }
}
