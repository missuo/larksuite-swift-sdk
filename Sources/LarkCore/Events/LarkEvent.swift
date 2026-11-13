import Foundation

/// An event or callback delivered by the Open Platform (via webhook or long connection).
public struct LarkEvent: Sendable {
    /// Event type, e.g. `im.message.receive_v1` or `card.action.trigger`.
    public let type: String
    /// `"2.0"` for v2 events, `nil` for v1 events.
    public let schema: String?
    /// v2 `header` object (event_id, event_type, create_time, token, app_id, tenant_key).
    public let header: JSONValue?
    /// v2 `event` object (or the v1 `event` object).
    public let event: JSONValue?
    /// The decrypted request body.
    public let raw: JSONValue
    /// Flattened payload, identical to what the Node SDK passes to handlers:
    /// top-level fields + `header` fields + `event` fields merged into one object.
    public let payload: JSONValue

    public var eventId: String? { header?["event_id"]?.stringValue ?? raw["uuid"]?.stringValue }
    public var tenantKey: String? { header?["tenant_key"]?.stringValue ?? payload["tenant_key"]?.stringValue }
    public var appId: String? { header?["app_id"]?.stringValue ?? payload["app_id"]?.stringValue }
    /// Event creation time in milliseconds (v2) as sent by the server.
    public var createTime: String? { header?["create_time"]?.stringValue ?? raw["ts"]?.stringValue }
    public var token: String? { header?["token"]?.stringValue ?? raw["token"]?.stringValue }

    /// Decodes the flattened payload into a typed model.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try payload.decode(as: T.self)
    }

    /// Decodes only the v2 `event` object into a typed model.
    public func decodeEvent<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try (event ?? .object([:])).decode(as: T.self)
    }

    /// Parses a decrypted body following the Node SDK rules.
    public init(body: JSONValue) {
        raw = body
        var obj = body.objectValue ?? [:]
        obj["encrypt"] = nil
        if obj["schema"] != nil {
            schema = obj["schema"]?.stringValue
            header = obj["header"]
            event = obj["event"]
            type = obj["header"]?["event_type"]?.stringValue ?? ""
            var flat = obj
            flat["header"] = nil
            flat["event"] = nil
            for (k, v) in header?.objectValue ?? [:] { flat[k] = v }
            for (k, v) in event?.objectValue ?? [:] { flat[k] = v }
            payload = .object(flat)
        } else {
            schema = nil
            header = nil
            event = obj["event"]
            type = obj["event"]?["type"]?.stringValue ?? obj["type"]?.stringValue ?? ""
            var flat = obj["event"]?.objectValue ?? [:]
            for (k, v) in obj where k != "event" { flat[k] = v }
            payload = .object(flat)
        }
    }
}

/// A typed key for registering event handlers with a decoded payload type.
///
/// Generated modules expose keys such as `.imMessageReceiveV1`; you can also
/// declare your own: `LarkEventKey<MyPayload>("my.event_v1")`.
public struct LarkEventKey<Payload: Decodable & Sendable>: Sendable, Hashable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

/// Response returned to card action callbacks (`card.action.trigger`).
public struct CardActionResponse: Encodable, Sendable {
    public struct Toast: Encodable, Sendable {
        public enum Kind: String, Encodable, Sendable { case info, success, error, warning }
        public var type: Kind
        public var content: String
        public var i18n: [String: String]?
        public init(type: Kind, content: String, i18n: [String: String]? = nil) {
            self.type = type
            self.content = content
            self.i18n = i18n
        }
    }

    public struct Card: Encodable, Sendable {
        /// `raw` (card JSON) or `template`.
        public var type: String
        public var data: JSONValue
        public init(type: String, data: JSONValue) {
            self.type = type
            self.data = data
        }
        /// A raw card JSON body.
        public static func raw(_ card: JSONValue) -> Card { Card(type: "raw", data: card) }
        /// A card template with variables.
        public static func template(id: String, version: String? = nil, variables: JSONValue? = nil) -> Card {
            var d: [String: JSONValue] = ["template_id": .string(id)]
            if let version { d["template_version_name"] = .string(version) }
            if let variables { d["template_variable"] = variables }
            return Card(type: "template", data: .object(d))
        }
    }

    public var toast: Toast?
    public var card: Card?

    public init(toast: Toast? = nil, card: Card? = nil) {
        self.toast = toast
        self.card = card
    }
}
