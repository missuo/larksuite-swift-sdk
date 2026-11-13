import Foundation

// Port of node-sdk `scene/registration` (`registerApp`): one-click app creation through the
// OAuth 2.0 Device Authorization Grant (RFC 8628).

/// Registers (or updates) a Feishu/Lark app by letting a user scan a QR code.
///
/// ```swift
/// let result = try await registerApp(.init(
///     addons: AppAddons(scopes: .init(tenant: ["im:message:send_as_bot"])),
///     onStatusChange: { print($0.status) },
///     onQRCodeReady: { info in print("Scan: \(info.url) (expires in \(info.expireIn)s)") }))
/// let client = try LarkClient(appId: result.clientId, appSecret: result.clientSecret)
/// ```
///
/// Flow (identical to node-sdk): `POST https://<domain>/oauth/v1/app/registration` with
/// `action=begin`, report the verification URL through `onQRCodeReady`, then poll with
/// `action=poll` every `interval` seconds until the user authorises, denies, or the code expires.
///
/// Errors:
/// - ``RegisterAppError`` with code `access_denied`, `expired_token` (also when the
///   `expires_in` window elapses: "Polling timed out"), `abort`, or any other `error` the
///   server returns.
/// - ``LarkError/invalidArgument(_:)`` for invalid `appId`, `appPreset` or `addons` (node-sdk
///   throws a plain `Error` with the same message).
/// - ``LarkError`` transport / HTTP errors when the server cannot be reached.
///
/// Cancellation: cancelling the calling task is node-sdk's `AbortSignal`. The call then fails
/// with ``RegisterAppError`` code `abort` immediately, even while a poll request is in flight
/// (its response is dropped and nothing is scheduled afterwards). As in node-sdk, the `begin`
/// request itself is not cancellable: it completes and `onQRCodeReady` fires before the abort
/// is observed.
public func registerApp(_ options: RegisterAppOptions) async throws -> RegisterAppResult {
    try await AppRegistration.register(options, timers: .live)
}

/// Options of ``registerApp(_:)`` (node-sdk `RegisterAppOptions`).
public struct RegisterAppOptions: Sendable {
    /// Accounts host (no scheme). Default `accounts.feishu.cn`.
    public var domain: String?
    /// Lark accounts host, used once the tenant brand is detected as Lark.
    /// Default `accounts.larksuite.com`.
    public var larkDomain: String?
    /// Caller tag, carried on the QR-code URL as `source=node-sdk/<source>`.
    public var source: String?
    /// Pre-fill values for the app-creation page.
    public var appPreset: AppPreset?
    /// Incremental scopes / events / callbacks pre-filled into the confirm page.
    public var addons: AppAddons?
    /// App id (`cli_xxx`) of an existing app to update (carried as `clientID`).
    /// Ignored by the page when ``createOnly`` is `true`.
    public var appId: String?
    /// When `true`, the landing page only allows creating a new app. Any other value keeps the
    /// default page flow (the parameter is omitted).
    public var createOnly: Bool?
    /// Transport used for the registration requests.
    public var httpClient: any LarkHTTPClient
    /// Called on polling status changes.
    public var onStatusChange: (@Sendable (StatusChangeInfo) -> Void)?
    /// Called once the verification URL is ready; render it as a QR code or a link.
    public var onQRCodeReady: @Sendable (QRCodeInfo) -> Void

    public init(
        domain: String? = nil,
        larkDomain: String? = nil,
        source: String? = nil,
        appPreset: AppPreset? = nil,
        addons: AppAddons? = nil,
        appId: String? = nil,
        createOnly: Bool? = nil,
        httpClient: any LarkHTTPClient = URLSessionHTTPClient(),
        onStatusChange: (@Sendable (StatusChangeInfo) -> Void)? = nil,
        onQRCodeReady: @escaping @Sendable (QRCodeInfo) -> Void
    ) {
        self.domain = domain
        self.larkDomain = larkDomain
        self.source = source
        self.appPreset = appPreset
        self.addons = addons
        self.appId = appId
        self.createOnly = createOnly
        self.httpClient = httpClient
        self.onStatusChange = onStatusChange
        self.onQRCodeReady = onQRCodeReady
    }
}

/// Pre-fill values shown on the app-creation page (node-sdk `AppPreset`). The user can still
/// edit them; the final values are whatever the user submits.
public struct AppPreset: Sendable, Hashable {
    /// App avatar URL(s): 1-6 publicly reachable images (png / jpg / jpeg / webp / gif).
    /// The first one is the default selection.
    public var avatar: [String]?
    /// App name. Supports the `{user}` placeholder (the scanning user's name).
    public var name: String?
    /// App description. Supports the `{user}` placeholder.
    public var desc: String?

    public init(avatar: [String]? = nil, name: String? = nil, desc: String? = nil) {
        self.avatar = avatar
        self.name = name
        self.desc = desc
    }

    /// A single avatar URL (node-sdk accepts `string | string[]`).
    public init(avatar: String, name: String? = nil, desc: String? = nil) {
        self.init(avatar: [avatar], name: name, desc: desc)
    }
}

/// Argument of `onQRCodeReady`.
public struct QRCodeInfo: Sendable, Hashable {
    /// The verification URL to show as a QR code or link.
    public let url: String
    /// Seconds until the code expires (`expires_in`, default 600).
    public let expireIn: TimeInterval

    public init(url: String, expireIn: TimeInterval) {
        self.url = url
        self.expireIn = expireIn
    }
}

/// Argument of `onStatusChange`.
public struct StatusChangeInfo: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        /// `authorization_pending`: still waiting for the user.
        case polling
        /// `slow_down`: the polling interval grew by 5 seconds.
        case slowDown = "slow_down"
        /// The tenant is a Lark tenant; polling continues on the Lark domain.
        case domainSwitched = "domain_switched"
    }
    public let status: Status
    /// The new polling interval in seconds (only for ``Status/slowDown``).
    public let interval: TimeInterval?

    public init(status: Status, interval: TimeInterval? = nil) {
        self.status = status
        self.interval = interval
    }
}

/// The scanning user (node-sdk `UserInfo`).
public struct RegisterAppUserInfo: Sendable, Hashable {
    public var openId: String?
    /// `"feishu"` or `"lark"`.
    public var tenantBrand: String?

    public init(openId: String? = nil, tenantBrand: String? = nil) {
        self.openId = openId
        self.tenantBrand = tenantBrand
    }
}

/// Credentials of the registered app (node-sdk `RegisterAppResult`).
public struct RegisterAppResult: Sendable, Hashable {
    /// App ID (`client_id`).
    public let clientId: String
    /// App secret (`client_secret`).
    public let clientSecret: String
    /// The scanning user (`user_info`).
    public let userInfo: RegisterAppUserInfo?

    public init(clientId: String, clientSecret: String, userInfo: RegisterAppUserInfo? = nil) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.userInfo = userInfo
    }
}

/// Error codes of ``RegisterAppError`` (open: any server `error` string is preserved).
public struct RegisterAppErrorCode: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }

    /// The user denied the authorisation.
    public static let accessDenied: Self = "access_denied"
    /// The QR code expired, or polling timed out.
    public static let expiredToken: Self = "expired_token"
    /// The calling task was cancelled (node-sdk: `AbortSignal`).
    public static let abort: Self = "abort"
}

/// The error thrown by ``registerApp(_:)`` for terminal registration outcomes
/// (node-sdk `RegisterAppError` `{ code, description }`).
public struct RegisterAppError: Error, Sendable, Hashable, CustomStringConvertible {
    public let code: RegisterAppErrorCode
    public let description: String

    public init(code: RegisterAppErrorCode, description: String) {
        self.code = code
        self.description = description
    }
}

// MARK: - Implementation

enum AppRegistration {
    /// Carried in the QR-code `source` parameter (node-sdk's `SDK_NAME`, kept verbatim).
    static let sdkName = "node-sdk"
    static let defaultFeishuDomain = "accounts.feishu.cn"
    static let defaultLarkDomain = "accounts.larksuite.com"
    static let endpoint = "/oauth/v1/app/registration"
    static let avatarMaxCount = 6

    /// Sleeps used by the polling loop; injectable so tests run instantly.
    struct Timers: Sendable {
        /// Waits before the next poll (`setTimeout(poll, interval)`), in milliseconds.
        var pollDelay: @Sendable (_ milliseconds: Double) async throws -> Void
        /// The overall `expires_in` window (`setTimeout(..., expireIn)`), in milliseconds.
        var expiry: @Sendable (_ milliseconds: Double) async throws -> Void

        static let live = Timers(pollDelay: jsSleep, expiry: jsSleep)

        /// `setTimeout` delay semantics: NaN, < 1 or > 2^31-1 ms become 1 ms.
        static func jsDelay(_ ms: Double) -> Double {
            (ms >= 1 && ms <= 2_147_483_647) ? ms : 1
        }

        @Sendable static func jsSleep(_ ms: Double) async throws {
            try await Task.sleep(nanoseconds: UInt64(jsDelay(ms) * 1_000_000))
        }
    }

    struct BeginResponse: Sendable {
        var deviceCode: String
        var verificationURIComplete: String
        /// Seconds (`interval ?? 5`); NaN when the server sends a non-numeric value.
        var interval: Double
        /// Seconds (`expires_in ?? 600`).
        var expiresIn: Double
    }

    struct PollResponse: Sendable {
        var clientId: String?
        var clientSecret: String?
        var userInfo: RegisterAppUserInfo?
        var error: String?
        var errorDescription: String?

        init(_ json: JSONValue) {
            clientId = json["client_id"]?.stringValue
            clientSecret = json["client_secret"]?.stringValue
            if case .object? = json["user_info"] {
                userInfo = RegisterAppUserInfo(
                    openId: json["user_info"]?["open_id"]?.stringValue,
                    tenantBrand: json["user_info"]?["tenant_brand"]?.stringValue)
            }
            error = json["error"]?.stringValue
            errorDescription = json["error_description"]?.stringValue
        }
    }

    static func register(_ options: RegisterAppOptions, timers: Timers) async throws -> RegisterAppResult {
        if let appId = options.appId, appId.isEmpty {
            throw LarkError.invalidArgument("appId must be a non-empty string")
        }
        let http = options.httpClient
        let baseURL = "https://\(options.domain ?? defaultFeishuDomain)"

        // node-sdk does not pass the abort signal to the begin request: run it detached from
        // the caller's cancellation so it always completes.
        let begin = try await Task { try await beginRequest(http, baseURL: baseURL) }.value

        let qrCodeURL = try buildQRCodeURL(begin.verificationURIComplete, options: options)
        options.onQRCodeReady(QRCodeInfo(url: qrCodeURL, expireIn: begin.expiresIn))

        return try await startPolling(
            http: http,
            baseURL: baseURL,
            larkBaseURL: "https://\(options.larkDomain ?? defaultLarkDomain)",
            deviceCode: begin.deviceCode,
            interval: begin.interval * 1000,
            expireIn: begin.expiresIn * 1000,
            onStatusChange: options.onStatusChange,
            timers: timers)
    }

    // MARK: QR code URL

    static func buildQRCodeURL(_ verificationURIComplete: String, options: RegisterAppOptions) throws -> String {
        guard var url = SearchParamsURL(verificationURIComplete) else {
            throw LarkError.decoding(
                message: "Invalid URL: verification_uri_complete \(verificationURIComplete)",
                body: Data(verificationURIComplete.utf8))
        }
        url.query.set("from", "sdk")
        url.query.set("source", options.source.map { $0.isEmpty ? sdkName : "\(sdkName)/\($0)" } ?? sdkName)
        url.query.set("tp", "sdk")
        if let preset = options.appPreset {
            try applyAppPreset(&url.query, preset)
        }
        if let addons = options.addons {
            url.query.set("addons", try AddonsEncoder.encode(addons))
        }
        // The landing page only honours the literal 'true'; otherwise the param is omitted.
        if options.createOnly == true {
            url.query.set("createOnly", "true")
        }
        // With both present the page gives createOnly precedence, so both are passed through.
        if let appId = options.appId, !appId.isEmpty {
            url.query.set("clientID", appId)
        }
        return url.string
    }

    static func applyAppPreset(_ query: inout FormURLEncoded, _ preset: AppPreset) throws {
        if let avatars = preset.avatar {
            if avatars.isEmpty {
                throw LarkError.invalidArgument("appPreset.avatar must contain at least 1 URL")
            }
            if avatars.count > avatarMaxCount {
                throw LarkError.invalidArgument(
                    "appPreset.avatar supports at most \(avatarMaxCount) URLs, got \(avatars.count)")
            }
            for (idx, url) in avatars.enumerated() {
                if url.isEmpty {
                    throw LarkError.invalidArgument("appPreset.avatar[\(idx)] must be a non-empty string")
                }
                query.append("avatar", url)
            }
        }
        if let name = preset.name { query.set("name", name) }
        if let desc = preset.desc { query.set("desc", desc) }
    }

    // MARK: HTTP

    /// `POST {baseURL}/oauth/v1/app/registration` with a form-encoded body.
    ///
    /// Like node-sdk (axios), a non-2xx response with a body is returned as data: RFC 8628
    /// reports `authorization_pending`, `slow_down`, ... with HTTP 400. A non-2xx response
    /// without a body throws ``LarkError/http(statusCode:headers:body:)``. A body that is not a
    /// JSON object yields an empty object (all fields absent), as a string `data` does in JS.
    static func request(_ http: any LarkHTTPClient, baseURL: String, params: [(name: String, value: String)]) async throws -> JSONValue {
        let urlString = baseURL + endpoint
        guard let url = URL(string: urlString) else { throw LarkError.invalidArgument("invalid url: \(urlString)") }
        let body = FormURLEncoded(params).serialized()
        let request = LarkHTTPRequest(
            method: .post,
            url: url,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": UserAgent.build(source: nil, extraTags: []),
            ],
            body: Data(body.utf8))
        let response: LarkHTTPResponse
        do {
            response = try await http.send(request)
        } catch let e as LarkError {
            throw e
        } catch {
            throw LarkError.transport(message: "\(error)")
        }
        if !(200..<300).contains(response.statusCode) && response.body.isEmpty {
            throw LarkError.http(statusCode: response.statusCode, headers: response.headers, body: response.body)
        }
        if let json = try? JSONValue(data: response.body), case .object = json { return json }
        return .object([:])
    }

    static func beginRequest(_ http: any LarkHTTPClient, baseURL: String) async throws -> BeginResponse {
        let json = try await request(http, baseURL: baseURL, params: [
            ("action", "begin"),
            ("archetype", "PersonalAgent"),
            ("auth_method", "client_secret"),
            ("request_user_info", "open_id"),
        ])
        func seconds(_ key: String, default value: Double) -> Double {
            guard let v = json[key], !v.isNull else { return value }
            return v.doubleValue ?? .nan
        }
        let body = Data(json.jsonString().utf8)
        guard let uri = json["verification_uri_complete"]?.stringValue else {
            throw LarkError.decoding(message: "Invalid URL: verification_uri_complete is missing", body: body)
        }
        guard let deviceCode = json["device_code"]?.stringValue else {
            throw LarkError.decoding(message: "device_code is missing", body: body)
        }
        return BeginResponse(
            deviceCode: deviceCode,
            verificationURIComplete: uri,
            interval: seconds("interval", default: 5),
            expiresIn: seconds("expires_in", default: 600))
    }

    // MARK: Polling

    /// Settles a registration exactly once, like node-sdk's `succeed()` / `fail()`: the first
    /// outcome wins, the timers are cancelled, and every later outcome is ignored.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private var outcome: Result<RegisterAppResult, any Error>?
        private var continuation: CheckedContinuation<RegisterAppResult, any Error>?
        private var tasks: [Task<Void, Never>] = []

        var isSettled: Bool { lock.withLock { settled } }

        func succeed(_ result: RegisterAppResult) { settle(.success(result)) }
        func fail(_ error: any Error) { settle(.failure(error)) }

        private func settle(_ result: Result<RegisterAppResult, any Error>) {
            let (cont, pending): (CheckedContinuation<RegisterAppResult, any Error>?, [Task<Void, Never>]) = lock.withLock {
                guard !settled else { return (nil, []) }
                settled = true
                let c = continuation
                if c == nil { outcome = result }
                continuation = nil
                let t = tasks
                tasks = []
                return (c, t)
            }
            for t in pending { t.cancel() }
            cont?.resume(with: result)
        }

        func install(_ c: CheckedContinuation<RegisterAppResult, any Error>) {
            let early: Result<RegisterAppResult, any Error>? = lock.withLock {
                if let outcome { return outcome }
                continuation = c
                return nil
            }
            if let early { c.resume(with: early) }
        }

        func track(_ task: Task<Void, Never>) {
            let cancelNow: Bool = lock.withLock {
                if settled { return true }
                tasks.append(task)
                return false
            }
            if cancelNow { task.cancel() }
        }
    }

    static func abortError() -> RegisterAppError {
        RegisterAppError(code: .abort, description: "Registration was aborted")
    }

    static func startPolling(
        http: any LarkHTTPClient,
        baseURL: String,
        larkBaseURL: String,
        deviceCode: String,
        interval: Double,
        expireIn: Double,
        onStatusChange: (@Sendable (StatusChangeInfo) -> Void)?,
        timers: Timers
    ) async throws -> RegisterAppResult {
        let run = Run()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RegisterAppResult, any Error>) in
                run.install(continuation)
                if Task.isCancelled {
                    run.fail(abortError())
                    return
                }
                run.track(Task {
                    do { try await timers.expiry(expireIn) } catch { return }
                    if Task.isCancelled { return }
                    run.fail(RegisterAppError(code: .expiredToken, description: "Polling timed out"))
                })
                run.track(Task {
                    await pollLoop(
                        run: run, http: http, baseURL: baseURL, larkBaseURL: larkBaseURL, deviceCode: deviceCode,
                        interval: interval, onStatusChange: onStatusChange, timers: timers)
                })
            }
        } onCancel: {
            run.fail(abortError())
        }
    }

    private static func pollLoop(
        run: Run,
        http: any LarkHTTPClient,
        baseURL initialBaseURL: String,
        larkBaseURL: String,
        deviceCode: String,
        interval initialInterval: Double,
        onStatusChange: (@Sendable (StatusChangeInfo) -> Void)?,
        timers: Timers
    ) async {
        var baseURL = initialBaseURL
        var interval = initialInterval
        var domainSwitched = false

        while !run.isSettled {
            let response: PollResponse
            do {
                response = PollResponse(
                    try await request(http, baseURL: baseURL, params: [("action", "poll"), ("device_code", deviceCode)]))
            } catch {
                run.fail(error)
                return
            }
            // Aborted or expired while the request was in flight: drop the response.
            if run.isSettled { return }

            // Lark domain switch (once only), then poll again immediately.
            if response.userInfo?.tenantBrand == "lark" && !domainSwitched {
                baseURL = larkBaseURL
                domainSwitched = true
                onStatusChange?(StatusChangeInfo(status: .domainSwitched, interval: nil))
                continue
            }

            if let clientId = response.clientId, !clientId.isEmpty,
                let clientSecret = response.clientSecret, !clientSecret.isEmpty
            {
                run.succeed(RegisterAppResult(clientId: clientId, clientSecret: clientSecret, userInfo: response.userInfo))
                return
            }

            switch response.error {
            case "authorization_pending":
                onStatusChange?(StatusChangeInfo(status: .polling, interval: nil))
            case "slow_down":
                interval += 5000
                onStatusChange?(StatusChangeInfo(status: .slowDown, interval: interval / 1000))
            case let error? where !error.isEmpty:
                run.fail(RegisterAppError(code: RegisterAppErrorCode(rawValue: error), description: response.errorDescription ?? "Unknown error"))
                return
            default:
                break
            }

            // A status callback may have aborted the run: do not schedule another poll.
            if run.isSettled { return }
            do { try await timers.pollDelay(interval) } catch { return }
        }
    }
}
