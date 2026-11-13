import Foundation

/// Open Platform domain.
public enum LarkDomain: Sendable, Hashable {
    /// 飞书 https://open.feishu.cn
    case feishu
    /// Lark https://open.larksuite.com
    case lark
    /// A custom domain (private deployment, proxy, test server...).
    case custom(String)

    public var baseURL: String {
        switch self {
        case .feishu: return "https://open.feishu.cn"
        case .lark: return "https://open.larksuite.com"
        case .custom(let s):
            var s = s
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
    }
}

/// Application type.
public enum LarkAppType: Sendable, Hashable {
    /// 企业自建应用 (custom / self-built app).
    case selfBuild
    /// 应用商店应用 (marketplace / ISV app).
    case isv
}

/// Short-lived credential returned by a ``ClientAssertionProvider``.
public struct ClientAssertionToken: Sendable {
    public var value: String
    public var targetInfo: TargetInfo?

    public init(value: String, targetInfo: TargetInfo? = nil) {
        self.value = value
        self.targetInfo = targetInfo
    }
}

/// GDPR proxy routing info.
public struct TargetInfo: Sendable {
    public var targetService: String
    public var targetPrefix: String?

    public init(targetService: String, targetPrefix: String? = nil) {
        self.targetService = targetService
        self.targetPrefix = targetPrefix
    }
}

/// Keyless (ClientAssertion / RFC 7523 `private_key_jwt`) credential source.
///
/// The SDK never signs JWTs itself: an external signer returns a short-lived
/// assertion for the given audience host, which the SDK exchanges for tokens.
public protocol ClientAssertionProvider: Sendable {
    func retrieveToken(aud: String) async throws -> ClientAssertionToken
}

/// Closure-based ``ClientAssertionProvider``.
public struct ClosureClientAssertionProvider: ClientAssertionProvider {
    let body: @Sendable (String) async throws -> ClientAssertionToken
    public init(_ body: @escaping @Sendable (String) async throws -> ClientAssertionToken) { self.body = body }
    public func retrieveToken(aud: String) async throws -> ClientAssertionToken { try await body(aud) }
}

/// Client configuration.
public struct LarkConfiguration: Sendable {
    public var appId: String
    /// App secret. Provide either `appSecret` or `clientAssertionProvider`.
    public var appSecret: String
    /// Keyless credential provider (self-built apps only). Takes precedence over `appSecret`.
    public var clientAssertionProvider: (any ClientAssertionProvider)?
    /// OAuth base URL, e.g. `https://accounts.feishu.cn`. Auto-derived for official domains.
    public var oauthBaseURL: String?
    public var domain: LarkDomain
    public var appType: LarkAppType
    public var logLevel: LarkLogLevel
    public var logger: any LarkLogger
    public var cache: any LarkCache
    /// When true, the SDK never fetches tenant tokens automatically; pass
    /// tokens per request via ``RequestOptions``.
    public var disableTokenCache: Bool
    public var helpDeskId: String?
    public var helpDeskToken: String?
    public var httpClient: any LarkHTTPClient
    /// Default request timeout in seconds.
    public var timeout: TimeInterval?
    /// Caller tag appended to the User-Agent as `source/<name>`.
    public var source: String?
    /// Extra User-Agent tokens (used by sub-modules).
    public var extraUserAgentTags: [String]

    public init(
        appId: String,
        appSecret: String = "",
        clientAssertionProvider: (any ClientAssertionProvider)? = nil,
        oauthBaseURL: String? = nil,
        domain: LarkDomain = .feishu,
        appType: LarkAppType = .selfBuild,
        logLevel: LarkLogLevel = .info,
        logger: any LarkLogger = ConsoleLarkLogger(),
        cache: any LarkCache = DefaultLarkCache.shared,
        disableTokenCache: Bool = false,
        helpDeskId: String? = nil,
        helpDeskToken: String? = nil,
        httpClient: any LarkHTTPClient = URLSessionHTTPClient(),
        timeout: TimeInterval? = nil,
        source: String? = nil,
        extraUserAgentTags: [String] = []
    ) {
        self.appId = appId
        self.appSecret = appSecret
        self.clientAssertionProvider = clientAssertionProvider
        self.oauthBaseURL = oauthBaseURL
        self.domain = domain
        self.appType = appType
        self.logLevel = logLevel
        self.logger = logger
        self.cache = cache
        self.disableTokenCache = disableTokenCache
        self.helpDeskId = helpDeskId
        self.helpDeskToken = helpDeskToken
        self.httpClient = httpClient
        self.timeout = timeout
        self.source = source
        self.extraUserAgentTags = extraUserAgentTags
    }
}

/// Per-request options (equivalent to the Node SDK `withXxx` helpers).
public struct RequestOptions: Sendable {
    /// Tenant key, required for marketplace (ISV) apps.
    public var tenantKey: String?
    /// Call the API as a user with this `user_access_token`.
    public var userAccessToken: String?
    /// Use this `tenant_access_token` instead of the managed one.
    public var tenantAccessToken: String?
    /// Use this `app_access_token`.
    public var appAccessToken: String?
    /// Add the help desk `X-Lark-Helpdesk-Authorization` header.
    public var withHelpDeskCredential: Bool
    /// Extra headers (override generated ones).
    public var headers: [String: String]
    /// Extra query parameters (override generated ones).
    public var query: [String: String]
    /// Extra path parameters.
    public var path: [String: String]
    /// Request timeout in seconds.
    public var timeout: TimeInterval?

    public init(
        tenantKey: String? = nil,
        userAccessToken: String? = nil,
        tenantAccessToken: String? = nil,
        appAccessToken: String? = nil,
        withHelpDeskCredential: Bool = false,
        headers: [String: String] = [:],
        query: [String: String] = [:],
        path: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) {
        self.tenantKey = tenantKey
        self.userAccessToken = userAccessToken
        self.tenantAccessToken = tenantAccessToken
        self.appAccessToken = appAccessToken
        self.withHelpDeskCredential = withHelpDeskCredential
        self.headers = headers
        self.query = query
        self.path = path
        self.timeout = timeout
    }

    public static var none: RequestOptions { RequestOptions() }

    public static func tenantKey(_ key: String) -> RequestOptions { RequestOptions(tenantKey: key) }
    public static func userAccessToken(_ token: String) -> RequestOptions { RequestOptions(userAccessToken: token) }
    public static func tenantAccessToken(_ token: String) -> RequestOptions { RequestOptions(tenantAccessToken: token) }
    public static var helpDeskCredential: RequestOptions { RequestOptions(withHelpDeskCredential: true) }

    /// Merges several option sets; later values win (mirrors `withAll`).
    public static func all(_ list: [RequestOptions]) -> RequestOptions {
        var out = RequestOptions()
        for o in list {
            out.tenantKey = o.tenantKey ?? out.tenantKey
            out.userAccessToken = o.userAccessToken ?? out.userAccessToken
            out.tenantAccessToken = o.tenantAccessToken ?? out.tenantAccessToken
            out.appAccessToken = o.appAccessToken ?? out.appAccessToken
            out.withHelpDeskCredential = out.withHelpDeskCredential || o.withHelpDeskCredential
            out.headers.merge(o.headers) { _, n in n }
            out.query.merge(o.query) { _, n in n }
            out.path.merge(o.path) { _, n in n }
            out.timeout = o.timeout ?? out.timeout
        }
        return out
    }
}

enum UserAgent {
    static let sdkVersion = LarkSDK.version

    static func sanitize(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { s -> Character in
            let c = Character(s)
            if c.isASCII, c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" { return c }
            return "_"
        }
        return String(String(mapped).prefix(64))
    }

    static func build(source: String?, extraTags: [String]) -> String {
        var ua = "oapi-swift-sdk/\(sdkVersion)"
        if let source, !sanitize(source).isEmpty { ua += " source/\(sanitize(source))" }
        for t in extraTags where !sanitize(t).isEmpty { ua += " \(sanitize(t))" }
        return ua
    }
}

/// SDK metadata.
public enum LarkSDK {
    public static let version = "1.0.0"
    /// The `@larksuiteoapi/node-sdk` version the API surface was generated from.
    public static let generatedFromNodeSDKVersion = LarkGeneratedInfo.nodeSDKVersion
}
