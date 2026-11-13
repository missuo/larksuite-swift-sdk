import Foundation

/// Incremental app config pre-filled into the confirm page shown after the user scans the
/// QR code of ``registerApp(_:)`` (node-sdk `AppAddons`). Field names align with the app manifest.
///
/// Only these public manifest fields may travel on the URL. Sensitive config
/// (`events.subscription_type` / `request_url` / `security.*` / encrypt keys) must go through
/// the "update application config" OpenAPI instead.
///
/// Semantics:
/// - Additive only: items are merged on top of the platform base template; base permissions
///   can never be removed.
/// - Item names are not validated by the SDK; names unknown to the platform catalog are
///   silently dropped by the confirm page.
/// - Requires the platform gray-scale for extra config to be enabled, otherwise the whole
///   param is ignored and the default flow is used.
public struct AppAddons: Sendable, Hashable {
    /// Template base selector, carried as the top-level `preset` field of the encoded payload.
    /// - `true` / `nil`: keep the platform default template and layer the declared scopes /
    ///   events / callbacks on top.
    /// - `false`: drop the default template, use the minimal base (bot capability only, no
    ///   business scopes) and show only the explicitly declared items. With `preset: false` an
    ///   otherwise-empty addons is valid; without it at least one item is required.
    public var preset: Bool?
    /// Permission scopes.
    public var scopes: Scopes?
    /// Event subscriptions.
    public var events: Events?
    /// Callbacks.
    public var callbacks: Callbacks?

    public init(preset: Bool? = nil, scopes: Scopes? = nil, events: Events? = nil, callbacks: Callbacks? = nil) {
        self.preset = preset
        self.scopes = scopes
        self.events = events
        self.callbacks = callbacks
    }

    public struct Scopes: Sendable, Hashable {
        /// App-identity (tenant) scopes, e.g. `"im:message:send_as_bot"`.
        public var tenant: [String]?
        /// User-identity scopes, e.g. `"calendar:calendar:read"`.
        public var user: [String]?
        public init(tenant: [String]? = nil, user: [String]? = nil) {
            self.tenant = tenant
            self.user = user
        }
    }

    public struct Events: Sendable, Hashable {
        public var items: Items?
        public init(items: Items? = nil) { self.items = items }

        public struct Items: Sendable, Hashable {
            /// App-identity events, e.g. `"im.message.receive_v1"`.
            public var tenant: [String]?
            /// User-identity events, e.g. `"calendar.calendar.event.changed_v4"`.
            public var user: [String]?
            public init(tenant: [String]? = nil, user: [String]? = nil) {
                self.tenant = tenant
                self.user = user
            }
        }
    }

    public struct Callbacks: Sendable, Hashable {
        /// Callbacks, e.g. `"card.action.trigger"`.
        public var items: [String]?
        public init(items: [String]? = nil) { self.items = items }
    }

    /// The untyped shape node-sdk validates (`nil` fields are absent, i.e. `undefined`).
    var jsonValue: JSONValue {
        func list(_ v: [String]?) -> JSONValue? { v.map { .array($0.map(JSONValue.string)) } }
        func object(_ pairs: [(String, JSONValue?)]) -> JSONValue {
            var o: [String: JSONValue] = [:]
            for (k, v) in pairs { if let v { o[k] = v } }
            return .object(o)
        }
        return object([
            ("preset", preset.map(JSONValue.bool)),
            ("scopes", scopes.map { object([("tenant", list($0.tenant)), ("user", list($0.user))]) }),
            ("events", events.map { e in
                object([("items", e.items.map { object([("tenant", list($0.tenant)), ("user", list($0.user))]) })])
            }),
            ("callbacks", callbacks.map { object([("items", list($0.items))]) }),
        ])
    }
}

/// Port of node-sdk `scene/registration/addons.ts`.
enum AddonsEncoder {
    /// Validates `addons` and encodes it into the URL-safe `addons` query value.
    ///
    /// Pipeline (fixed by the platform):
    /// `JSON.stringify → gzip → base64 → URL-safe ('+' → '-', '/' → '_') → strip '=' padding`.
    static func encode(_ addons: AppAddons) throws -> String {
        try encode(addons.jsonValue)
    }

    /// Same as `encode(_: AppAddons)` for an untyped payload (e.g. read from a
    /// manifest), with node-sdk's full shape validation.
    static func encode(_ addons: JSONValue) throws -> String {
        let json = try normalizedJSON(addons)
        return Data(Gzip.compress(Array(json.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingTrailing("=")
    }

    /// `JSON.stringify(normalizeAddons(addons))`, byte-for-byte.
    ///
    /// Throws ``LarkError/invalidArgument(_:)`` with node-sdk's exact messages. When an object
    /// has several unknown keys, the first one in sorted order is reported (JavaScript reports
    /// the first in insertion order, which `JSONValue` does not preserve).
    static func normalizedJSON(_ addons: JSONValue) throws -> String {
        let top = try plainObject(addons, "addons")
        try assertAllowedKeys(top, ["preset", "scopes", "events", "callbacks"], "addons")

        var itemCount = 0
        func pick(_ value: JSONValue?, _ path: String) throws -> [String]? {
            let items = try validateStringArray(value, path)
            itemCount += items?.count ?? 0
            return items
        }

        // Ordered (key, serialized value) pairs, mirroring JS property insertion order.
        var out: [(String, String)] = []

        // `preset` is validated before the empty-payload check below.
        if let preset = top["preset"] {
            guard case .bool(let b) = preset else { throw LarkError.invalidArgument("addons.preset must be a boolean") }
            out.append(("preset", b ? "true" : "false"))
        }

        if let scopesValue = top["scopes"] {
            let scopes = try plainObject(scopesValue, "addons.scopes")
            try assertAllowedKeys(scopes, ["tenant", "user"], "addons.scopes")
            let tenant = try pick(scopes["tenant"], "addons.scopes.tenant")
            let user = try pick(scopes["user"], "addons.scopes.user")
            out.append(("scopes", object([("tenant", tenant.map(array)), ("user", user.map(array))])))
        }

        if let eventsValue = top["events"] {
            let events = try plainObject(eventsValue, "addons.events")
            try assertAllowedKeys(events, ["items"], "addons.events")
            if let itemsValue = events["items"] {
                let items = try plainObject(itemsValue, "addons.events.items")
                try assertAllowedKeys(items, ["tenant", "user"], "addons.events.items")
                let tenant = try pick(items["tenant"], "addons.events.items.tenant")
                let user = try pick(items["user"], "addons.events.items.user")
                let inner = object([("tenant", tenant.map(array)), ("user", user.map(array))])
                out.append(("events", object([("items", inner)])))
            }
        }

        if let callbacksValue = top["callbacks"] {
            let callbacks = try plainObject(callbacksValue, "addons.callbacks")
            try assertAllowedKeys(callbacks, ["items"], "addons.callbacks")
            let items = try pick(callbacks["items"], "addons.callbacks.items")
            out.append(("callbacks", object([("items", items.map(array))])))
        }

        // An all-empty addons is a caller bug, except with `preset: false` (minimal base).
        if itemCount == 0 && top["preset"] != .bool(false) {
            throw LarkError.invalidArgument("addons must contain at least one scope, event or callback")
        }

        return object(out)
    }

    // MARK: - Validation (messages copied from node-sdk)

    private static func plainObject(_ value: JSONValue, _ path: String) throws -> [String: JSONValue] {
        guard case .object(let o) = value else { throw LarkError.invalidArgument("\(path) must be an object") }
        return o
    }

    private static func assertAllowedKeys(_ obj: [String: JSONValue], _ allowed: [String], _ path: String) throws {
        for key in obj.keys.sorted() where !allowed.contains(key) {
            throw LarkError.invalidArgument("\(path).\(key) is not allowed; allowed keys: \(allowed.joined(separator: ", "))")
        }
    }

    private static func validateStringArray(_ value: JSONValue?, _ path: String) throws -> [String]? {
        guard let value else { return nil }
        guard case .array(let arr) = value else { throw LarkError.invalidArgument("\(path) must be an array of strings") }
        return try arr.enumerated().map { idx, item in
            guard case .string(let s) = item, !s.isEmpty else {
                throw LarkError.invalidArgument("\(path)[\(idx)] must be a non-empty string")
            }
            return s
        }
    }

    // MARK: - JSON.stringify

    /// Serialises an object, skipping `nil` (undefined) members like `JSON.stringify`.
    private static func object(_ pairs: [(String, String?)]) -> String {
        "{" + pairs.compactMap { k, v in v.map { "\(jsString(k)):\($0)" } }.joined(separator: ",") + "}"
    }

    private static func array(_ items: [String]) -> String {
        "[" + items.map(jsString).joined(separator: ",") + "]"
    }

    /// `JSON.stringify` of a string: escapes `"`, `\` and C0 controls only (lower-case `\u00xx`).
    static func jsString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{00}"..."\u{1F}":
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension String {
    fileprivate func trimmingTrailing(_ c: Character) -> String {
        var s = self
        while s.last == c { s.removeLast() }
        return s
    }
}
