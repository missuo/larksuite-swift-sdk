import Foundation

/// Entry point of the SDK.
///
/// ```swift
/// let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx")
/// let resp = try await client.im.v1.message.create(
///     params: .init(receiveIdType: .chatId),
///     body: .init(receiveId: "oc_xxx", msgType: "text", content: #"{"text":"hello"}"#))
/// print(resp.data?.messageId ?? "")
/// ```
///
/// API namespaces (`client.im`, `client.contact`, ...) are provided by the
/// per-domain modules (`LarkIM`, `LarkContact`, ...) or all at once by `Lark`.
public final class LarkClient: Sendable {
    public let config: LarkConfiguration
    public let logger: LoggerProxy
    /// Normalised Open Platform base URL, e.g. `https://open.feishu.cn`.
    public let baseURL: String
    public let tokenManager: TokenManager
    /// OAuth v3 user-access-token service (works with app secret or ClientAssertion).
    public let accessToken: AccessTokenService
    /// Cached user-access-token helper (legacy OIDC flow).
    public let userAccessToken: UserAccessTokenManager
    public let userAgent: String

    public init(_ config: LarkConfiguration) throws {
        self.config = config
        self.logger = LoggerProxy(level: config.logLevel, sink: config.logger)
        guard !config.appId.isEmpty else {
            logger.error("appId is needed")
            throw LarkError.invalidArgument("appId is needed")
        }
        if config.appSecret.isEmpty && config.clientAssertionProvider == nil {
            throw LarkError.clientAssertion(
                code: ClientAssertionErrorCode.appSecretAndClientAssertionEmpty,
                msg: "appSecret or clientAssertionProvider is required")
        }
        if config.clientAssertionProvider != nil && config.appType == .isv {
            throw LarkError.clientAssertion(
                code: ClientAssertionErrorCode.providerNotConfigured,
                msg: "ClientAssertion mode is not supported for ISV apps")
        }
        self.baseURL = config.domain.baseURL
        self.userAgent = UserAgent.build(source: config.source, extraTags: config.extraUserAgentTags)
        self.tokenManager = TokenManager(config: config, baseURL: baseURL, logger: logger, userAgent: userAgent)
        self.accessToken = AccessTokenService(config: config, baseURL: baseURL, logger: logger, userAgent: userAgent)
        self.userAccessToken = UserAccessTokenManager(appId: config.appId, cache: config.cache, logger: logger)
        logger.debug("use domain url: \(baseURL)")
        if config.appType == .isv {
            let tm = tokenManager
            Task {
                if await tm.cache.get(LarkCacheKey.appTicket, namespace: tm.appId) == nil {
                    await tm.requestAppTicketResend()
                }
            }
        }
        userAccessToken.attach(self)
        logger.info("client ready")
    }

    public convenience init(
        appId: String,
        appSecret: String,
        domain: LarkDomain = .feishu,
        appType: LarkAppType = .selfBuild,
        logLevel: LarkLogLevel = .info
    ) throws {
        try self.init(LarkConfiguration(appId: appId, appSecret: appSecret, domain: domain, appType: appType, logLevel: logLevel))
    }

    // MARK: - Request pipeline

    /// Resolves authorisation and common headers for a request.
    public func prepareHeaders(_ options: RequestOptions, auth: Bool = true) async throws -> [String: String] {
        var headers: [String: String] = ["User-Agent": userAgent]
        if auth {
            if let uat = options.userAccessToken {
                logger.debug("use passed token")
                headers["Authorization"] = "Bearer \(uat)"
            } else if let tat = options.tenantAccessToken {
                headers["Authorization"] = "Bearer \(tat)"
            } else if let aat = options.appAccessToken {
                headers["Authorization"] = "Bearer \(aat)"
            } else if !config.disableTokenCache {
                do {
                    let token = try await tokenManager.tenantAccessToken(tenantKey: options.tenantKey)
                    headers["Authorization"] = "Bearer \(token)"
                } catch {
                    logger.warn("failed to obtain token: \(error)")
                    throw error
                }
            }
        }
        if options.withHelpDeskCredential {
            logger.debug("generate help desk credential")
            let cred = Data("\(config.helpDeskId ?? ""):\(config.helpDeskToken ?? "")".utf8).base64EncodedString()
            headers["X-Lark-Helpdesk-Authorization"] = "Bearer \(cred)"
        }
        headers.merge(options.headers) { _, n in n }
        return headers
    }

    /// Builds the absolute URL for an API path and query.
    public func makeURL(path: String, query: (any Encodable & Sendable)?, options: RequestOptions) throws -> URL {
        var resolvedPath = path
        if !options.path.isEmpty || path.contains("/:") {
            resolvedPath = try LarkURL.fillPath(path, options.path)
        }
        let base: String
        if resolvedPath.hasPrefix("http://") || resolvedPath.hasPrefix("https://") {
            base = resolvedPath
        } else {
            base = baseURL + (resolvedPath.hasPrefix("/") ? "" : "/") + resolvedPath
        }
        var items: [URLQueryItem] = []
        if let query {
            let json = try JSONValue(encoding: query)
            items = LarkURL.queryItems(from: json)
        }
        if !options.query.isEmpty {
            items.removeAll { options.query[$0.name] != nil }
            for k in options.query.keys.sorted() { items.append(URLQueryItem(name: k, value: options.query[k])) }
        }
        let full = items.isEmpty ? base : base + (base.contains("?") ? "&" : "?") + LarkURL.percentEncodeQuery(items)
        guard let url = URL(string: full) else { throw LarkError.invalidArgument("invalid url: \(full)") }
        return url
    }

    /// Sends a request and returns the raw HTTP response without interpreting it.
    public func send(
        _ method: HTTPMethod,
        _ path: String,
        query: (any Encodable & Sendable)? = nil,
        body: LarkRequestBody = .none,
        options: RequestOptions = .none,
        authenticated: Bool = true
    ) async throws -> LarkHTTPResponse {
        let url = try makeURL(path: path, query: query, options: options)
        var headers = try await prepareHeaders(options, auth: authenticated)
        var data: Data?
        switch body {
        case .none:
            break
        case .json(let value):
            data = try LarkJSON.encoder.encode(value)
            if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json; charset=utf-8" }
        case .multipart(let form):
            let encoded = form.encode()
            data = encoded.body
            headers["Content-Type"] = encoded.contentType
        case .raw(let d, let contentType):
            data = d
            headers["Content-Type"] = contentType
        }
        logger.trace("send request [\(method.rawValue)]: \(url.absoluteString)")
        do {
            return try await config.httpClient.send(
                LarkHTTPRequest(method: method, url: url, headers: headers, body: data, timeout: options.timeout ?? config.timeout))
        } catch let e as LarkError {
            logger.error("request [\(method.rawValue)] \(url.path) failed: \(e)")
            throw e
        } catch {
            logger.error("request [\(method.rawValue)] \(url.path) failed: \(error)")
            throw LarkError.transport(message: "\(error)")
        }
    }

    /// Sends a request and decodes the standard `{code, msg, data}` envelope.
    ///
    /// Throws ``LarkError/api(_:)`` when `code != 0`.
    public func request<T: Decodable & Sendable>(
        _ method: HTTPMethod,
        _ path: String,
        query: (any Encodable & Sendable)? = nil,
        body: LarkRequestBody = .none,
        options: RequestOptions = .none,
        as type: T.Type = T.self
    ) async throws -> LarkResponse<T> {
        let resp = try await send(method, path, query: query, body: body, options: options)
        return try LarkResponse<T>.decode(resp, logger: logger)
    }

    /// Convenience overload for JSON bodies.
    public func request<T: Decodable & Sendable>(
        _ method: HTTPMethod,
        _ path: String,
        query: (any Encodable & Sendable)? = nil,
        json: (any Encodable & Sendable)?,
        options: RequestOptions = .none,
        as type: T.Type = T.self
    ) async throws -> LarkResponse<T> {
        try await request(method, path, query: query, body: json.map { .json($0) } ?? .none, options: options, as: type)
    }

    /// Sends a request whose response is a file (downloads).
    public func download(
        _ method: HTTPMethod,
        _ path: String,
        query: (any Encodable & Sendable)? = nil,
        body: LarkRequestBody = .none,
        options: RequestOptions = .none
    ) async throws -> LarkBinaryResponse {
        let resp = try await send(method, path, query: query, body: body, options: options)
        let contentType = resp.header("content-type") ?? ""
        if !(200..<300).contains(resp.statusCode) || contentType.contains("application/json") {
            // Error responses come back as JSON envelopes.
            if let json = try? JSONValue(data: resp.body), let code = json["code"]?.intValue, code != 0 {
                throw LarkError.api(
                    LarkAPIError(
                        code: code, msg: json["msg"]?.stringValue ?? "", httpStatus: resp.statusCode,
                        logId: resp.header("x-tt-logid"), headers: resp.headers, body: resp.body))
            }
            if !(200..<300).contains(resp.statusCode) {
                throw LarkError.http(statusCode: resp.statusCode, headers: resp.headers, body: resp.body)
            }
        }
        return LarkBinaryResponse(statusCode: resp.statusCode, headers: resp.headers, data: resp.body)
    }
}

/// Request body variants.
public enum LarkRequestBody: Sendable {
    case none
    case json(any Encodable & Sendable)
    case multipart(MultipartForm)
    case raw(Data, contentType: String)
}

/// Placeholder for APIs whose response `data` is empty.
public struct LarkEmpty: Codable, Sendable, Hashable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
    public func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: AnyCodingKey.self)
    }
}

/// A coding key that accepts any string.
public struct AnyCodingKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int?
    public init(_ s: String) { stringValue = s }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
