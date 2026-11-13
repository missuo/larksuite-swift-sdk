import Foundation

/// OAuth constants and helpers shared by the keyless (ClientAssertion) flow.
public enum LarkOAuth {
    public static let tokenURI = "/oauth/v3/token"
    public static let grantTypeJWTBearer = "urn:ietf:params:oauth:grant-type:jwt-bearer"
    public static let clientAssertionTypeJWTBearer = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    public static let grantTypeAuthorizationCode = "authorization_code"
    public static let grantTypeRefreshToken = "refresh_token"
    public static let targetServiceHeader = "X-Target-Service"

    /// Official OpenAPI host → OAuth base URL.
    public static let domainMap: [String: String] = [
        "open.feishu.cn": "https://accounts.feishu.cn",
        "open.larksuite.com": "https://accounts.larksuite.com",
    ]

    static func ensureScheme(_ raw: String) -> String {
        raw.contains("://") ? raw : "https://\(raw)"
    }

    /// Extracts `host[:port]` from a URL.
    public static func extractAud(fromURL raw: String) throws -> String {
        guard let comps = URLComponents(string: ensureScheme(raw)), let host = comps.host, !host.isEmpty else {
            throw LarkError.invalidArgument("invalid url: \(raw)")
        }
        if let port = comps.port { return "\(host):\(port)" }
        return host
    }

    /// Resolves the OAuth base URL: explicit value → official mapping → error.
    public static func resolveBaseURL(oauthBaseURL: String?, domain: String) throws -> String {
        if let oauthBaseURL, !oauthBaseURL.isEmpty {
            var s = ensureScheme(oauthBaseURL)
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        let aud = try extractAud(fromURL: domain)
        if let mapped = domainMap[aud] { return mapped }
        throw LarkError.invalidArgument(
            "oauthBaseUrl is not configured. When domain is a non-default value (neither open.feishu.cn nor open.larksuite.com), set oauthBaseURL explicitly."
        )
    }

    public static func resolveAud(oauthBaseURL: String?, domain: String) throws -> String {
        try extractAud(fromURL: resolveBaseURL(oauthBaseURL: oauthBaseURL, domain: domain))
    }

    /// Builds the GDPR proxy URL, validating that the target is https, carries
    /// no userinfo and has no path traversal.
    public static func buildProxyURL(_ target: TargetInfo, apiPath: String) throws -> String {
        guard let comps = URLComponents(string: ensureScheme(target.targetService)), let host = comps.host else {
            throw LarkError.invalidArgument("invalid targetService")
        }
        guard comps.scheme == "https" else { throw LarkError.invalidArgument("targetService must use https") }
        if comps.user != nil || comps.password != nil {
            throw LarkError.invalidArgument("targetService must not contain userinfo")
        }
        var path = (target.targetPrefix ?? "") + apiPath
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains("..") { throw LarkError.invalidArgument("targetPrefix must not contain path traversal") }
        let hostPort = comps.port.map { "\(host):\($0)" } ?? host
        return "https://\(hostPort)\(path)"
    }
}
