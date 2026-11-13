import Foundation
import LarkCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Port of node-sdk `channel/outbound/errors.ts`.
///
/// node-sdk inspects axios-shaped errors (`err.response.status`,
/// `err.response.data.code/msg`, `err.code`, `err.message`). The Swift SDK
/// surfaces the same information as ``LarkError``:
///
/// | node-sdk                         | Swift                                              |
/// |----------------------------------|----------------------------------------------------|
/// | `response.status`                | `LarkAPIError.httpStatus` / `LarkError.http` status |
/// | `response.data.code` / `.msg`    | `LarkAPIError.code` / `.msg` (or the `.http` body) |
/// | `code === 'ETIMEDOUT'` etc.      | `URLError.timedOut`, or a transport message containing `timed out` |
/// | `message`                        | the error description                              |
///
/// Unlike node-sdk (which only sees business codes on HTTP errors), the Swift
/// client throws for any `code != 0`, so business codes are classified even
/// on HTTP 200 responses.
enum ChannelErrors {
    struct Inspected {
        var status: Int?
        var feishuCode: Int?
        var message: String
        var errorCode: String?
    }

    static func inspect(_ err: any Error) -> Inspected {
        if let e = err as? LarkError {
            switch e {
            case .api(let api):
                return Inspected(status: api.httpStatus, feishuCode: api.code, message: api.msg.isEmpty ? e.description : api.msg)
            case .http(let status, _, let body):
                let json = try? JSONValue(data: body)
                var code: Int?
                if case .number(let n)? = json?["code"] { code = Int(exactly: n) }
                let msg = nonEmpty(json?["msg"]?.stringValue) ?? nonEmpty(json?["message"]?.stringValue) ?? e.description
                return Inspected(status: status, feishuCode: code, message: msg)
            case .transport(let m):
                // LarkClient stringifies transport failures; NSURLErrorTimedOut is -1001.
                let timedOut = m.contains("Code=-1001") || m.contains("NSURLErrorTimedOut")
                return Inspected(status: nil, feishuCode: nil, message: m, errorCode: timedOut ? "ETIMEDOUT" : nil)
            default:
                return Inspected(status: nil, feishuCode: nil, message: e.description)
            }
        }
        if let u = err as? URLError {
            return Inspected(
                status: nil, feishuCode: nil, message: u.localizedDescription,
                errorCode: u.code == .timedOut ? "ETIMEDOUT" : nil)
        }
        if let s = err as? SSRFBlockedError { return Inspected(status: nil, feishuCode: nil, message: s.message) }
        return Inspected(status: nil, feishuCode: nil, message: "\(err)")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func inferCode(_ i: Inspected) -> LarkChannelError.Code {
        let msg = i.message.lowercased()
        if let c = i.feishuCode {
            if c == 230020 || c == 230017 { return .targetRevoked }
            if c == 99991400 || c == 99991401 { return .permissionDenied }
            if c == 230002 || c == 230001 { return .formatError }
        }
        switch i.status {
        case 429: return .rateLimited
        case 401, 403: return .permissionDenied
        case 400: return .formatError
        case 404: return .targetRevoked
        default: break
        }
        if msg.hasPrefix("ssrf_blocked") { return .ssrfBlocked }
        if msg.contains("timeout") || msg.contains("timed out") || i.errorCode == "ETIMEDOUT" || i.errorCode == "ECONNABORTED" {
            return .sendTimeout
        }
        return .unknown
    }
}

/// Classifies any error into a ``LarkChannelError`` with a stable code
/// (an existing ``LarkChannelError`` passes through untouched).
func classifyError(_ err: any Error, context: LarkChannelError.Context? = nil) -> LarkChannelError {
    if let e = err as? LarkChannelError { return e }
    let i = ChannelErrors.inspect(err)
    return LarkChannelError(ChannelErrors.inferCode(i), i.message, cause: err, context: context)
}

/// Retryable codes: `rate_limited` and `unknown`.
func isRetryable(_ err: LarkChannelError) -> Bool { err.code == .rateLimited || err.code == .unknown }
func isFormatError(_ err: LarkChannelError) -> Bool { err.code == .formatError }
func isReplyTargetGone(_ err: LarkChannelError) -> Bool { err.code == .targetRevoked }

/// Exponential backoff (`base * 3^(attempt-1)`) for retryable errors only.
func retry<T: Sendable>(
    maxAttempts: Int? = nil, baseDelayMs: Int? = nil, _ op: @Sendable (Int) async throws -> T
) async throws -> T {
    let max = maxAttempts ?? 3
    let base = Double(baseDelayMs ?? 500)
    var lastErr: LarkChannelError?
    var attempt = 1
    while attempt <= max {
        do {
            return try await op(attempt)
        } catch {
            let err = classifyError(error, context: .init(attempt: attempt))
            lastErr = err
            if attempt >= max || !isRetryable(err) { throw err }
            await sleepMs(base * pow(3, Double(attempt - 1)))
        }
        attempt += 1
    }
    throw lastErr ?? LarkChannelError(.unknown, "retry: no attempts")
}
