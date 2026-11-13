import Foundation

/// Payload of the `card.action.trigger` callback (card button / form interactions),
/// flattened like every other event (header + event fields).
///
/// See https://open.feishu.cn/document/uAjLw4CM/ukzMukzMukzM/feishu-cards/card-callback-communication
public struct CardActionTriggerEvent: Codable, Sendable {
    public struct Operator: Codable, Sendable {
        public var tenantKey: String?
        public var userId: String?
        public var openId: String?
        public var unionId: String?
        enum CodingKeys: String, CodingKey {
            case tenantKey = "tenant_key", userId = "user_id", openId = "open_id", unionId = "union_id"
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tenantKey = c.lenient(.tenantKey)
            userId = c.lenient(.userId)
            openId = c.lenient(.openId)
            unionId = c.lenient(.unionId)
        }
    }

    public struct Action: Codable, Sendable {
        /// The `value` / `behaviors[].value` attached to the component.
        public var value: JSONValue?
        public var tag: String?
        /// Selected option (select menus).
        public var option: String?
        /// Selected options (multi-select).
        public var options: [String]?
        public var timezone: String?
        /// Component name (form submit buttons / inputs).
        public var name: String?
        /// Form values keyed by component name.
        public var formValue: JSONValue?
        public var inputValue: String?
        public var checked: Bool?
        enum CodingKeys: String, CodingKey {
            case value, tag, option, options, timezone, name, checked
            case formValue = "form_value", inputValue = "input_value"
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = c.lenient(.value)
            tag = c.lenient(.tag)
            option = c.lenient(.option)
            options = c.lenient(.options)
            timezone = c.lenient(.timezone)
            name = c.lenient(.name)
            formValue = c.lenient(.formValue)
            inputValue = c.lenient(.inputValue)
            checked = c.lenient(.checked)
        }
    }

    public struct Context: Codable, Sendable {
        public var url: String?
        public var previewToken: String?
        public var openMessageId: String?
        public var openChatId: String?
        enum CodingKeys: String, CodingKey {
            case url, previewToken = "preview_token", openMessageId = "open_message_id", openChatId = "open_chat_id"
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = c.lenient(.url)
            previewToken = c.lenient(.previewToken)
            openMessageId = c.lenient(.openMessageId)
            openChatId = c.lenient(.openChatId)
        }
    }

    public var eventId: String?
    public var eventType: String?
    public var createTime: String?
    public var tenantKey: String?
    public var appId: String?
    public var `operator`: Operator?
    /// Token used to update the card later (delayed update API).
    public var token: String?
    public var action: Action?
    public var host: String?
    public var deliveryType: String?
    public var context: Context?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", eventType = "event_type", createTime = "create_time", tenantKey = "tenant_key"
        case appId = "app_id", `operator`, token, action, host, deliveryType = "delivery_type", context
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = c.lenient(.eventId)
        eventType = c.lenient(.eventType)
        createTime = c.lenient(.createTime)
        tenantKey = c.lenient(.tenantKey)
        appId = c.lenient(.appId)
        `operator` = c.lenient(.operator)
        token = c.lenient(.token)
        action = c.lenient(.action)
        host = c.lenient(.host)
        deliveryType = c.lenient(.deliveryType)
        context = c.lenient(.context)
    }
}

extension LarkEventKey where Payload == CardActionTriggerEvent {
    /// `card.action.trigger` — card interaction callback. Return a ``CardActionResponse``.
    public static var cardActionTrigger: Self { .init("card.action.trigger") }
}
