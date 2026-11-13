import Foundation

/// Storage for tokens, app tickets and other short-lived values.
///
/// Implement this protocol to share tokens across processes (Redis, etc.).
/// Values are stored as strings; `expiresAt` is an absolute date (nil = never).
public protocol LarkCache: Sendable {
    func get(_ key: String, namespace: String?) async -> String?
    func set(_ key: String, value: String, expiresAt: Date?, namespace: String?) async -> Bool
}

extension LarkCache {
    public func get(_ key: String) async -> String? { await get(key, namespace: nil) }
    @discardableResult
    public func set(_ key: String, value: String, expiresAt: Date? = nil) async -> Bool {
        await set(key, value: value, expiresAt: expiresAt, namespace: nil)
    }
}

/// In-memory cache (the default).
public actor DefaultLarkCache: LarkCache {
    private var values: [String: (value: String, expiresAt: Date?)] = [:]

    public init() {}

    /// Process-wide shared instance, used when no cache is configured.
    public static let shared = DefaultLarkCache()

    private func key(_ k: String, _ ns: String?) -> String {
        if let ns, !ns.isEmpty { return "\(ns)/\(k)" }
        return k
    }

    public func get(_ k: String, namespace: String?) async -> String? {
        let ck = key(k, namespace)
        guard let entry = values[ck] else { return nil }
        if let exp = entry.expiresAt, exp <= Date() {
            values[ck] = nil
            return nil
        }
        return entry.value
    }

    @discardableResult
    public func set(_ k: String, value: String, expiresAt: Date?, namespace: String?) async -> Bool {
        values[key(k, namespace)] = (value, expiresAt)
        return true
    }

    public func remove(_ k: String, namespace: String? = nil) {
        values[key(k, namespace)] = nil
    }
}

/// Well-known cache keys (mirrors the Node SDK symbols).
public enum LarkCacheKey {
    public static let appTicket = "app-ticket"
    public static let tenantAccessToken = "tenant-access-token"
    public static let userAccessToken = "user-access-token"
    public static func marketTenantAccessToken(_ tenantKey: String) -> String { "larkMarketAccessToken\(tenantKey)" }
}
