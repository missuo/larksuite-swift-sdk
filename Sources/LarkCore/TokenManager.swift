import Foundation

/// Fetches and caches `tenant_access_token` / `app_access_token`.
///
/// Concurrent callers asking for the same token share a single in-flight request.
public actor TokenManager {
    public nonisolated let appId: String
    nonisolated let appSecret: String
    nonisolated let appType: LarkAppType
    nonisolated let baseURL: String
    nonisolated let cache: any LarkCache
    nonisolated let logger: LoggerProxy
    nonisolated let http: any LarkHTTPClient
    nonisolated let assertionProvider: (any ClientAssertionProvider)?
    nonisolated let oauthBaseURL: String?
    nonisolated let userAgent: String

    private var inflight: [String: Task<String, Error>] = [:]

    /// Tokens expire 3 minutes earlier than the server says to absorb latency.
    static let expiryMargin: TimeInterval = 180

    init(config: LarkConfiguration, baseURL: String, logger: LoggerProxy, userAgent: String) {
        self.appId = config.appId
        self.appSecret = config.appSecret
        self.appType = config.appType
        self.baseURL = baseURL
        self.cache = config.cache
        self.logger = logger
        self.http = config.httpClient
        self.assertionProvider = config.clientAssertionProvider
        self.oauthBaseURL = config.oauthBaseURL
        self.userAgent = userAgent
    }

    // MARK: Public API

    /// Returns a tenant access token, fetching one if needed.
    /// - Parameter tenantKey: Required for marketplace (ISV) apps.
    public func tenantAccessToken(tenantKey: String? = nil) async throws -> String {
        switch appType {
        case .selfBuild:
            logger.debug("get custom app token")
            return try await deduplicated("tat") { try await self.fetchCustomTenantAccessToken() }
        case .isv:
            logger.debug("get market app token")
            if assertionProvider != nil {
                throw LarkError.clientAssertion(
                    code: ClientAssertionErrorCode.providerNotConfigured,
                    msg: "ClientAssertion mode is not supported for ISV apps")
            }
            guard let tenantKey, !tenantKey.isEmpty else {
                logger.error("market app request need tenant key")
                throw LarkError.tokenUnavailable("market app request need tenant key")
            }
            return try await deduplicated("tat:\(tenantKey)") { try await self.fetchMarketTenantAccessToken(tenantKey) }
        }
    }

    /// Returns an `app_access_token`.
    public func appAccessToken() async throws -> String {
        if assertionProvider != nil {
            throw LarkError.clientAssertion(
                code: ClientAssertionErrorCode.modeNotSupported,
                msg: "app_access_token is not available in ClientAssertion mode")
        }
        return try await deduplicated("aat") { try await self.fetchAppAccessToken() }
    }

    /// Stores an app ticket pushed by the platform (ISV apps).
    public func setAppTicket(_ ticket: String) async {
        _ = await cache.set(LarkCacheKey.appTicket, value: ticket, expiresAt: nil, namespace: appId)
    }

    /// Returns the cached app ticket, asking the platform to resend one if absent.
    public func appTicket() async -> String? {
        if let t = await cache.get(LarkCacheKey.appTicket, namespace: appId) {
            logger.debug("use cache app ticket")
            return t
        }
        await requestAppTicketResend()
        return nil
    }

    /// Asks the platform to push a new `app_ticket` event.
    public func requestAppTicketResend() async {
        logger.debug("request app ticket")
        do {
            _ = try await postJSON(
                "\(baseURL)/open-apis/auth/v3/app_ticket/resend",
                body: ["app_id": .string(appId), "app_secret": .string(appSecret)])
        } catch {
            logger.error("request app ticket failed: \(error)")
        }
    }

    // MARK: Implementation

    private func deduplicated(_ key: String, _ op: @escaping @Sendable () async throws -> String) async throws -> String {
        if let t = inflight[key] { return try await t.value }
        let task = Task { try await op() }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    private func fetchCustomTenantAccessToken() async throws -> String {
        if assertionProvider != nil { return try await fetchTenantTokenByClientAssertion() }

        if let cached = await cache.get(LarkCacheKey.tenantAccessToken, namespace: appId) {
            logger.debug("use cache token")
            return cached
        }
        logger.debug("request token")
        let resp = try await requestToken(
            "\(baseURL)/open-apis/auth/v3/tenant_access_token/internal",
            body: ["app_id": .string(appId), "app_secret": .string(appSecret)],
            requiredField: "tenant_access_token")
        let token = resp["tenant_access_token"]!.stringValue!
        let expire = resp["expire"]?.doubleValue ?? 0
        _ = await cache.set(
            LarkCacheKey.tenantAccessToken, value: token,
            expiresAt: Date().addingTimeInterval(expire - Self.expiryMargin), namespace: appId)
        return token
    }

    private func fetchTenantTokenByClientAssertion() async throws -> String {
        let oauthBase = try LarkOAuth.resolveBaseURL(oauthBaseURL: oauthBaseURL, domain: baseURL)
        let aud = try LarkOAuth.extractAud(fromURL: oauthBase)

        if let cached = await cache.get(LarkCacheKey.tenantAccessToken, namespace: appId) {
            logger.debug("use cache token")
            return cached
        }

        let assertion: ClientAssertionToken
        do {
            assertion = try await assertionProvider!.retrieveToken(aud: aud)
        } catch {
            throw LarkError.clientAssertion(
                code: ClientAssertionErrorCode.retrieveFailed, msg: "\(error)")
        }
        guard !assertion.value.isEmpty else {
            throw LarkError.clientAssertion(code: ClientAssertionErrorCode.tokenEmpty, msg: "client assertion token is empty")
        }

        var url = oauthBase + LarkOAuth.tokenURI
        var headers: [String: String] = [:]
        if let target = assertion.targetInfo {
            url = try LarkOAuth.buildProxyURL(target, apiPath: LarkOAuth.tokenURI)
            headers[LarkOAuth.targetServiceHeader] = aud
        }
        logger.debug("request token (client assertion)")
        let body: JSONValue = [
            "grant_type": .string(LarkOAuth.grantTypeJWTBearer),
            "client_assertion_type": .string(LarkOAuth.clientAssertionTypeJWTBearer),
            "client_assertion": .string(assertion.value),
            "client_id": .string(appId),
        ]
        let resp: LarkHTTPResponse
        do {
            resp = try await sendJSON(url, body: body, headers: headers)
        } catch {
            throw LarkError.clientAssertion(code: 0, msg: "client assertion token exchange failed: \(error)")
        }
        let json = try? JSONValue(data: resp.body)
        guard (200..<300).contains(resp.statusCode), let token = json?["access_token"]?.stringValue, !token.isEmpty else {
            throw LarkError.clientAssertion(
                code: json?["code"]?.intValue ?? 0,
                msg: json?["error_description"]?.stringValue ?? json?["error"]?.stringValue
                    ?? "oauth token response missing access token")
        }
        let expiresIn = json?["expires_in"]?.doubleValue ?? 0
        _ = await cache.set(
            LarkCacheKey.tenantAccessToken, value: token,
            expiresAt: Date().addingTimeInterval(max(expiresIn - Self.expiryMargin, 0)), namespace: appId)
        return token
    }

    private func fetchAppAccessToken() async throws -> String {
        let cacheKey = "app-access-token"
        if let cached = await cache.get(cacheKey, namespace: appId) { return cached }
        let resp: JSONValue
        switch appType {
        case .selfBuild:
            resp = try await requestToken(
                "\(baseURL)/open-apis/auth/v3/app_access_token/internal",
                body: ["app_id": .string(appId), "app_secret": .string(appSecret)],
                requiredField: "app_access_token")
        case .isv:
            guard let ticket = await appTicket() else {
                logger.warn("no app ticket")
                throw LarkError.tokenUnavailable("no app ticket")
            }
            resp = try await requestToken(
                "\(baseURL)/open-apis/auth/v3/app_access_token",
                body: ["app_id": .string(appId), "app_secret": .string(appSecret), "app_ticket": .string(ticket)],
                requiredField: "app_access_token")
        }
        let token = resp["app_access_token"]!.stringValue!
        let expire = resp["expire"]?.doubleValue ?? 0
        _ = await cache.set(cacheKey, value: token, expiresAt: Date().addingTimeInterval(expire - Self.expiryMargin), namespace: appId)
        return token
    }

    private func fetchMarketTenantAccessToken(_ tenantKey: String) async throws -> String {
        let key = LarkCacheKey.marketTenantAccessToken(tenantKey)
        if let cached = await cache.get(key, namespace: appId) {
            logger.debug("use cache token")
            return cached
        }
        logger.debug("get app access token")
        let appToken = try await fetchAppAccessToken()
        logger.debug("get tenant access token")
        let resp = try await requestToken(
            "\(baseURL)/open-apis/auth/v3/tenant_access_token",
            body: ["app_access_token": .string(appToken), "tenant_key": .string(tenantKey)],
            requiredField: "tenant_access_token")
        let token = resp["tenant_access_token"]!.stringValue!
        let expire = resp["expire"]?.doubleValue ?? 0
        _ = await cache.set(key, value: token, expiresAt: Date().addingTimeInterval(expire - Self.expiryMargin), namespace: appId)
        return token
    }

    private func requestToken(_ url: String, body: JSONValue, requiredField: String) async throws -> JSONValue {
        let json: JSONValue
        do {
            json = try await postJSON(url, body: body)
        } catch {
            logger.error("token request failed: \(error)")
            throw error
        }
        guard let v = json[requiredField]?.stringValue, !v.isEmpty else {
            let code = json["code"]?.stringValue ?? "unknown"
            let msg = json["msg"]?.stringValue ?? "no message"
            throw LarkError.tokenUnavailable("failed to get \(requiredField), code: \(code), msg: \(msg)")
        }
        return json
    }

    private func postJSON(_ url: String, body: JSONValue) async throws -> JSONValue {
        let resp = try await sendJSON(url, body: body, headers: [:])
        guard let json = try? JSONValue(data: resp.body) else {
            throw LarkError.http(statusCode: resp.statusCode, headers: resp.headers, body: resp.body)
        }
        return json
    }

    nonisolated func sendJSON(_ url: String, body: JSONValue, headers: [String: String]) async throws -> LarkHTTPResponse {
        guard let u = URL(string: url) else { throw LarkError.invalidArgument("invalid url \(url)") }
        var h = headers
        h["Content-Type"] = "application/json; charset=utf-8"
        h["User-Agent"] = userAgent
        let data = try LarkJSON.encoder.encode(body)
        return try await http.send(LarkHTTPRequest(method: .post, url: u, headers: h, body: data))
    }
}
