import Foundation

/// Parameters for exchanging an OAuth authorization code.
public struct AuthorizationCodeParams: Sendable {
    public var code: String
    public var redirectURI: String?
    public var codeVerifier: String?
    public var scope: String?
    public var headers: [String: String]

    public init(code: String, redirectURI: String? = nil, codeVerifier: String? = nil, scope: String? = nil, headers: [String: String] = [:]) {
        self.code = code
        self.redirectURI = redirectURI
        self.codeVerifier = codeVerifier
        self.scope = scope
        self.headers = headers
    }
}

/// Parameters for refreshing a user access token.
public struct RefreshTokenParams: Sendable {
    public var refreshToken: String
    public var scope: String?
    public var headers: [String: String]

    public init(refreshToken: String, scope: String? = nil, headers: [String: String] = [:]) {
        self.refreshToken = refreshToken
        self.scope = scope
        self.headers = headers
    }
}

/// Result of the OAuth v3 token endpoint.
public struct AccessTokenResponse: Sendable, Hashable {
    public var accessToken: String
    public var tokenType: String?
    public var expiresIn: Int?
    public var refreshToken: String?
    public var refreshTokenExpiresIn: Int?
    public var scope: String?
}

/// `client.accessToken` — credential-agnostic user-access-token service.
///
/// Uses the OAuth endpoint `{oauthBaseURL}/oauth/v3/token`, authenticating the
/// client with the ClientAssertion provider if configured, otherwise with the
/// app secret.
public struct AccessTokenService: Sendable {
    let appId: String
    let appSecret: String
    let provider: (any ClientAssertionProvider)?
    let oauthBaseURL: String?
    let baseURL: String
    let http: any LarkHTTPClient
    let logger: LoggerProxy
    let userAgent: String

    init(config: LarkConfiguration, baseURL: String, logger: LoggerProxy, userAgent: String) {
        appId = config.appId
        appSecret = config.appSecret
        provider = config.clientAssertionProvider
        oauthBaseURL = config.oauthBaseURL
        self.baseURL = baseURL
        http = config.httpClient
        self.logger = logger
        self.userAgent = userAgent
    }

    /// Exchanges an authorization code for a user access token.
    public func retrieve(byAuthorizationCode params: AuthorizationCodeParams) async throws -> AccessTokenResponse {
        var body: [String: JSONValue] = [
            "grant_type": .string(LarkOAuth.grantTypeAuthorizationCode),
            "code": .string(params.code),
        ]
        if let v = params.redirectURI { body["redirect_uri"] = .string(v) }
        if let v = params.codeVerifier { body["code_verifier"] = .string(v) }
        if let v = params.scope { body["scope"] = .string(v) }
        return try await doRequest(body, headers: params.headers)
    }

    /// Refreshes a user access token.
    public func refresh(_ params: RefreshTokenParams) async throws -> AccessTokenResponse {
        var body: [String: JSONValue] = [
            "grant_type": .string(LarkOAuth.grantTypeRefreshToken),
            "refresh_token": .string(params.refreshToken),
        ]
        if let v = params.scope { body["scope"] = .string(v) }
        return try await doRequest(body, headers: params.headers)
    }

    private func doRequest(_ raw: [String: JSONValue], headers callerHeaders: [String: String]) async throws -> AccessTokenResponse {
        let oauthBase = try LarkOAuth.resolveBaseURL(oauthBaseURL: oauthBaseURL, domain: baseURL)
        let aud = try LarkOAuth.extractAud(fromURL: oauthBase)
        var body = raw
        body["client_id"] = .string(appId)
        var url = oauthBase + LarkOAuth.tokenURI
        var headers = callerHeaders

        if let provider {
            let assertion: ClientAssertionToken
            do {
                assertion = try await provider.retrieveToken(aud: aud)
            } catch {
                throw LarkError.clientAssertion(code: ClientAssertionErrorCode.retrieveFailed, msg: "\(error)")
            }
            guard !assertion.value.isEmpty else {
                throw LarkError.clientAssertion(code: ClientAssertionErrorCode.tokenEmpty, msg: "client assertion token is empty")
            }
            body["client_assertion_type"] = .string(LarkOAuth.clientAssertionTypeJWTBearer)
            body["client_assertion"] = .string(assertion.value)
            if let target = assertion.targetInfo {
                url = try LarkOAuth.buildProxyURL(target, apiPath: LarkOAuth.tokenURI)
                headers[LarkOAuth.targetServiceHeader] = aud
            }
        } else if !appSecret.isEmpty {
            body["client_secret"] = .string(appSecret)
        } else {
            throw LarkError.clientAssertion(
                code: ClientAssertionErrorCode.appSecretAndClientAssertionEmpty,
                msg: "appSecret and clientAssertionProvider cannot both be empty for accessToken APIs")
        }

        guard let u = URL(string: url) else { throw LarkError.invalidArgument("invalid url \(url)") }
        headers["Content-Type"] = "application/json; charset=utf-8"
        headers["User-Agent"] = userAgent
        let resp: LarkHTTPResponse
        do {
            resp = try await http.send(
                LarkHTTPRequest(method: .post, url: u, headers: headers, body: try LarkJSON.encoder.encode(JSONValue.object(body))))
        } catch {
            // Never surface the request (it carries secrets).
            logger.error("oauth token request failed")
            throw LarkError.accessToken(statusCode: 0, code: 0, error: "", errorDescription: "oauth token request failed: \(error.localizedDescription)")
        }
        let json = try? JSONValue(data: resp.body)
        let code = json?["code"]?.intValue ?? 0
        let isError = json == nil || json?["error"] != nil && json?["error"]?.isNull == false || code != 0
        if resp.statusCode != 200 || isError {
            throw LarkError.accessToken(
                statusCode: resp.statusCode, code: code, error: json?["error"]?.stringValue ?? "",
                errorDescription: json?["error_description"]?.stringValue ?? json?["msg"]?.stringValue ?? "")
        }
        func nonEmpty(_ v: JSONValue?) -> String? {
            guard let s = v?.stringValue, !s.isEmpty, s != "0" else { return nil }
            return s
        }
        guard let token = nonEmpty(json?["access_token"]) else {
            throw LarkError.accessToken(
                statusCode: resp.statusCode, code: code, error: json?["error"]?.stringValue ?? "",
                errorDescription: json?["error_description"]?.stringValue ?? "oauth token response missing access_token")
        }
        return AccessTokenResponse(
            accessToken: token,
            tokenType: nonEmpty(json?["token_type"]),
            expiresIn: json?["expires_in"]?.intValue.flatMap { $0 == 0 ? nil : $0 },
            refreshToken: nonEmpty(json?["refresh_token"]),
            refreshTokenExpiresIn: json?["refresh_token_expires_in"]?.intValue.flatMap { $0 == 0 ? nil : $0 },
            scope: nonEmpty(json?["scope"]))
    }
}

/// Cached user access token record.
public struct UserTokenInfo: Codable, Sendable, Hashable {
    public var code: String?
    public var token: String?
    public var refreshToken: String?
    /// Absolute expiry time.
    public var expiredTime: Date?

    public init(code: String? = nil, token: String? = nil, refreshToken: String? = nil, expiredTime: Date? = nil) {
        self.code = code
        self.token = token
        self.refreshToken = refreshToken
        self.expiredTime = expiredTime
    }
}

/// `client.userAccessToken` — caches user access tokens by an arbitrary key and
/// refreshes them transparently (OIDC flow, mirrors the Node SDK).
public final class UserAccessTokenManager: @unchecked Sendable {
    let appId: String
    let cache: any LarkCache
    let logger: LoggerProxy
    private let lock = NSLock()
    private weak var _client: LarkClient?

    init(appId: String, cache: any LarkCache, logger: LoggerProxy) {
        self.appId = appId
        self.cache = cache
        self.logger = logger
    }

    func attach(_ client: LarkClient) {
        lock.lock()
        _client = client
        lock.unlock()
    }

    private var client: LarkClient? {
        lock.lock()
        defer { lock.unlock() }
        return _client
    }

    private func cacheKey(_ key: String, namespace: String?) -> String {
        "\(namespace ?? appId)/\(LarkCacheKey.userAccessToken)/\(key)"
    }

    private static func calibrate(_ seconds: Int?) -> Date {
        Date().addingTimeInterval(TimeInterval(seconds ?? 0) - 180)
    }

    private func oidc(_ path: String, _ body: JSONValue) async throws -> (token: String, refresh: String?, expiresIn: Int?)? {
        guard let client else { return nil }
        let resp: LarkResponse<JSONValue>
        do {
            // Same authorisation as the Node SDK (`client.authen.oidcAccessToken.create`).
            resp = try await client.request(.post, path, json: body)
        } catch {
            logger.error("user access token request failed: \(error)")
            return nil
        }
        guard let token = resp.data?["access_token"]?.stringValue else { return nil }
        return (token, resp.data?["refresh_token"]?.stringValue, resp.data?["expires_in"]?.intValue)
    }

    /// Exchanges login codes for tokens and caches them under the given keys.
    @discardableResult
    public func initWithCode(_ keyToCode: [String: String], namespace: String? = nil) async throws -> [String: UserTokenInfo] {
        var out: [String: UserTokenInfo] = [:]
        for (key, code) in keyToCode {
            guard let r = try await oidc("/open-apis/authen/v1/oidc/access_token", ["grant_type": "authorization_code", "code": .string(code)]) else {
                logger.error("init user access token error: \(key)")
                continue
            }
            out[key] = UserTokenInfo(code: code, token: r.token, refreshToken: r.refresh, expiredTime: Self.calibrate(r.expiresIn))
        }
        await update(out, namespace: namespace)
        return out
    }

    /// Merges token info into the cache.
    public func update(_ keyToInfo: [String: UserTokenInfo], namespace: String? = nil) async {
        for (key, info) in keyToInfo {
            let ck = cacheKey(key, namespace: namespace)
            var current = await load(ck) ?? UserTokenInfo()
            if let v = info.code { current.code = v }
            if let v = info.token { current.token = v }
            if let v = info.refreshToken { current.refreshToken = v }
            if let v = info.expiredTime { current.expiredTime = v }
            if let s = try? LarkJSON.string(current) {
                _ = await cache.set(ck, value: s, expiresAt: nil, namespace: nil)
            }
        }
    }

    private func load(_ ck: String) async -> UserTokenInfo? {
        guard let s = await cache.get(ck, namespace: nil) else { return nil }
        return try? JSONDecoder().decode(UserTokenInfo.self, from: Data(s.utf8))
    }

    /// Returns a valid user access token for `key`, refreshing it if needed.
    public func get(_ key: String, namespace: String? = nil) async throws -> String? {
        let ck = cacheKey(key, namespace: namespace)
        guard let info = await load(ck) else {
            logger.error("user access token needs to be initialized or updated first")
            return nil
        }
        if let token = info.token, let exp = info.expiredTime, exp > Date() { return token }

        if let refresh = info.refreshToken {
            if let r = try await oidc("/open-apis/authen/v1/oidc/refresh_access_token", ["grant_type": "refresh_token", "refresh_token": .string(refresh)]) {
                await update([key: UserTokenInfo(token: r.token, refreshToken: r.refresh, expiredTime: Self.calibrate(r.expiresIn))], namespace: namespace)
                return r.token
            }
            logger.error("get user access token by refresh token failed.")
            return nil
        }
        if let code = info.code {
            if let r = try await oidc("/open-apis/authen/v1/oidc/access_token", ["grant_type": "authorization_code", "code": .string(code)]) {
                await update([key: UserTokenInfo(token: r.token, refreshToken: r.refresh, expiredTime: Self.calibrate(r.expiresIn))], namespace: namespace)
                return r.token
            }
            logger.error("get user access token by code failed.")
        }
        return nil
    }
}
