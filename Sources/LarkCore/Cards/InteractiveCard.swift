import Foundation

// Port of node-sdk `typings/card.ts`: typed builders for (legacy, schema 1.0) interactive cards.
// For card JSON 2.0 or anything not modelled here, build a `JSONValue` directly.

/// An interactive (message) card.
public struct InteractiveCard: Codable, Sendable, Hashable {
    public var config: Config?
    public var header: Header?
    /// Card body. Provide `elements` or `i18nElements`.
    public var elements: [InteractiveCardElement]?
    public var i18nElements: [String: [InteractiveCardElement]]?
    public var cardLink: InteractiveCardURL?

    public init(
        config: Config? = nil, header: Header? = nil, elements: [InteractiveCardElement]? = nil,
        i18nElements: [String: [InteractiveCardElement]]? = nil, cardLink: InteractiveCardURL? = nil
    ) {
        self.config = config
        self.header = header
        self.elements = elements
        self.i18nElements = i18nElements
        self.cardLink = cardLink
    }

    enum CodingKeys: String, CodingKey {
        case config, header, elements
        case i18nElements = "i18n_elements"
        case cardLink = "card_link"
    }

    public struct Config: Codable, Sendable, Hashable {
        public var enableForward: Bool?
        public var updateMulti: Bool?
        /// Deprecated by the platform after 2021-03-22.
        public var wideScreenMode: Bool?
        public init(enableForward: Bool? = nil, updateMulti: Bool? = nil, wideScreenMode: Bool? = nil) {
            self.enableForward = enableForward
            self.updateMulti = updateMulti
            self.wideScreenMode = wideScreenMode
        }
        enum CodingKeys: String, CodingKey {
            case enableForward = "enable_forward", updateMulti = "update_multi", wideScreenMode = "wide_screen_mode"
        }
    }

    public struct Header: Codable, Sendable, Hashable {
        public var title: Title
        public var template: Template?
        public init(title: Title, template: Template? = nil) {
            self.title = title
            self.template = template
        }
    }

    /// Header colour.
    public enum Template: String, Codable, Sendable, Hashable, CaseIterable {
        case blue, wathet, turquoise, green, yellow, orange, red, carmine, violet, purple, indigo, grey
    }

    /// Header title (a plain-text item without `lines`, plus optional i18n).
    public struct Title: Codable, Sendable, Hashable {
        public var tag: String = "plain_text"
        public var content: String?
        public var i18n: [String: String]?
        public init(_ content: String?, i18n: [String: String]? = nil) {
            self.content = content
            self.i18n = i18n
        }
    }

    /// The card serialised as JSON text (for a message `content` field).
    public func jsonString() throws -> String { try LarkJSON.string(self) }
}

/// A text item: `plain_text` or `lark_md`.
public struct InteractiveCardText: Codable, Sendable, Hashable {
    public enum Tag: String, Codable, Sendable, Hashable {
        case plainText = "plain_text"
        case larkMd = "lark_md"
    }
    public var tag: Tag
    public var content: String?
    /// Only meaningful for `plain_text`.
    public var lines: Int?

    public init(tag: Tag, content: String?, lines: Int? = nil) {
        self.tag = tag
        self.content = content
        self.lines = lines
    }

    public static func plain(_ content: String, lines: Int? = nil) -> Self { .init(tag: .plainText, content: content, lines: lines) }
    public static func markdown(_ content: String) -> Self { .init(tag: .larkMd, content: content) }
}

/// A multi-platform URL.
public struct InteractiveCardURL: Codable, Sendable, Hashable {
    public var url: String
    public var androidURL: String?
    public var iosURL: String?
    public var pcURL: String?
    public init(url: String, androidURL: String? = nil, iosURL: String? = nil, pcURL: String? = nil) {
        self.url = url
        self.androidURL = androidURL
        self.iosURL = iosURL
        self.pcURL = pcURL
    }
    enum CodingKeys: String, CodingKey {
        case url, androidURL = "android_url", iosURL = "ios_url", pcURL = "pc_url"
    }
}

/// An image item (`img`), used by image and note elements.
public struct InteractiveCardImage: Codable, Sendable, Hashable {
    public var tag: String = "img"
    public var imgKey: String
    public var alt: InteractiveCardText
    public var preview: Bool?
    public init(imgKey: String, alt: InteractiveCardText = .plain(""), preview: Bool? = nil) {
        self.imgKey = imgKey
        self.alt = alt
        self.preview = preview
    }
    enum CodingKeys: String, CodingKey { case tag, imgKey = "img_key", alt, preview }
}

/// Card body elements.
public enum InteractiveCardElement: Codable, Sendable, Hashable {
    case div(Div)
    case markdown(Markdown)
    /// Divider (`hr`).
    case divider
    case image(Image)
    case note(Note)
    case action(Action)
    /// Any element not modelled here.
    case raw(JSONValue)

    public struct Field: Codable, Sendable, Hashable {
        public var isShort: Bool
        public var text: InteractiveCardText
        public init(isShort: Bool, text: InteractiveCardText) {
            self.isShort = isShort
            self.text = text
        }
        enum CodingKeys: String, CodingKey { case isShort = "is_short", text }
    }

    public struct Div: Codable, Sendable, Hashable {
        public var tag: String = "div"
        public var text: InteractiveCardText
        public var fields: [Field]?
        public var extra: JSONValue?
        public init(text: InteractiveCardText, fields: [Field]? = nil, extra: JSONValue? = nil) {
            self.text = text
            self.fields = fields
            self.extra = extra
        }
    }

    public struct Markdown: Codable, Sendable, Hashable {
        public enum Align: String, Codable, Sendable, Hashable { case left, center, right }
        public var tag: String = "markdown"
        public var content: String
        public var textAlign: Align?
        public var href: [String: InteractiveCardURL]?
        public init(_ content: String, textAlign: Align? = nil, href: [String: InteractiveCardURL]? = nil) {
            self.content = content
            self.textAlign = textAlign
            self.href = href
        }
        enum CodingKeys: String, CodingKey { case tag, content, textAlign = "text_align", href }
    }

    public struct Image: Codable, Sendable, Hashable {
        public enum Mode: String, Codable, Sendable, Hashable {
            case cropCenter = "crop_center"
            case fitHorizontal = "fit_horizontal"
        }
        public var tag: String = "img"
        public var imgKey: String
        public var alt: InteractiveCardText
        public var preview: Bool?
        public var title: InteractiveCardText?
        public var customWidth: Int?
        public var compactWidth: Bool?
        public var mode: Mode?
        public init(
            imgKey: String, alt: InteractiveCardText = .plain(""), preview: Bool? = nil, title: InteractiveCardText? = nil,
            customWidth: Int? = nil, compactWidth: Bool? = nil, mode: Mode? = nil
        ) {
            self.imgKey = imgKey
            self.alt = alt
            self.preview = preview
            self.title = title
            self.customWidth = customWidth
            self.compactWidth = compactWidth
            self.mode = mode
        }
        enum CodingKeys: String, CodingKey {
            case tag, imgKey = "img_key", alt, preview, title, customWidth = "custom_width", compactWidth = "compact_width", mode
        }
    }

    public struct Note: Codable, Sendable, Hashable {
        public enum Item: Codable, Sendable, Hashable {
            case text(InteractiveCardText)
            case image(InteractiveCardImage)

            public init(from decoder: any Decoder) throws {
                let tag = try TagProbe(from: decoder).tag
                self = tag == "img" ? .image(try InteractiveCardImage(from: decoder)) : .text(try InteractiveCardText(from: decoder))
            }
            public func encode(to encoder: any Encoder) throws {
                switch self {
                case .text(let t): try t.encode(to: encoder)
                case .image(let i): try i.encode(to: encoder)
                }
            }
        }
        public var tag: String = "note"
        public var elements: [Item]
        public init(_ elements: [Item]) { self.elements = elements }
    }

    public struct Action: Codable, Sendable, Hashable {
        public enum Layout: String, Codable, Sendable, Hashable { case bisected, trisection, flow }
        public var tag: String = "action"
        public var actions: [InteractiveCardActionItem]
        public var layout: Layout?
        public init(_ actions: [InteractiveCardActionItem], layout: Layout? = nil) {
            self.actions = actions
            self.layout = layout
        }
    }

    public init(from decoder: any Decoder) throws {
        switch try TagProbe(from: decoder).tag {
        case "div": self = .div(try Div(from: decoder))
        case "markdown": self = .markdown(try Markdown(from: decoder))
        case "hr": self = .divider
        case "img": self = .image(try Image(from: decoder))
        case "note": self = .note(try Note(from: decoder))
        case "action": self = .action(try Action(from: decoder))
        default: self = .raw(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .div(let v): try v.encode(to: encoder)
        case .markdown(let v): try v.encode(to: encoder)
        case .divider: try (["tag": "hr"] as JSONValue).encode(to: encoder)
        case .image(let v): try v.encode(to: encoder)
        case .note(let v): try v.encode(to: encoder)
        case .action(let v): try v.encode(to: encoder)
        case .raw(let v): try v.encode(to: encoder)
        }
    }
}

/// Interactive components inside an `action` element.
public struct InteractiveCardActionItem: Codable, Sendable, Hashable {
    public enum Tag: String, Codable, Sendable, Hashable {
        case button
        case datePicker = "date_picker"
        case pickerTime = "picker_time"
        case pickerDatetime = "picker_datetime"
        case overflow
        case selectStatic = "select_static"
        case selectPerson = "select_person"
    }
    public enum ButtonType: String, Codable, Sendable, Hashable { case `default`, primary, danger }

    public struct Confirm: Codable, Sendable, Hashable {
        public var title: InteractiveCardText
        public var text: InteractiveCardText
        public init(title: String, text: String) {
            self.title = .plain(title)
            self.text = .plain(text)
        }
    }

    public struct Option: Codable, Sendable, Hashable {
        public var text: InteractiveCardText?
        public var value: String?
        public var url: String?
        /// Field name as spelled by the platform (`multi_utl`).
        public var multiURL: InteractiveCardURL?
        public init(text: String? = nil, value: String? = nil, url: String? = nil, multiURL: InteractiveCardURL? = nil) {
            self.text = text.map { .plain($0) }
            self.value = value
            self.url = url
            self.multiURL = multiURL
        }
        enum CodingKeys: String, CodingKey { case text, value, url, multiURL = "multi_utl" }
    }

    public var tag: Tag
    public var confirm: Confirm?
    public var text: InteractiveCardText?
    public var url: String?
    public var multiURL: InteractiveCardURL?
    public var type: ButtonType?
    public var value: JSONValue?
    public var placeholder: InteractiveCardText?
    public var initialDate: String?
    public var initialTime: String?
    public var initialDatetime: String?
    public var initialOption: String?
    /// Options of `overflow` menus.
    public var options: [Option]?
    /// Options of `select_static` / `select_person` menus (the platform spells this `option`).
    public var option: [Option]?

    public init(
        tag: Tag, confirm: Confirm? = nil, text: InteractiveCardText? = nil, url: String? = nil, multiURL: InteractiveCardURL? = nil,
        type: ButtonType? = nil, value: JSONValue? = nil, placeholder: InteractiveCardText? = nil, initialDate: String? = nil,
        initialTime: String? = nil, initialDatetime: String? = nil, initialOption: String? = nil, options: [Option]? = nil,
        option: [Option]? = nil
    ) {
        self.tag = tag
        self.confirm = confirm
        self.text = text
        self.url = url
        self.multiURL = multiURL
        self.type = type
        self.value = value
        self.placeholder = placeholder
        self.initialDate = initialDate
        self.initialTime = initialTime
        self.initialDatetime = initialDatetime
        self.initialOption = initialOption
        self.options = options
        self.option = option
    }

    enum CodingKeys: String, CodingKey {
        case tag, confirm, text, url, type, value, placeholder, options, option
        case multiURL = "multi_utl", initialDate = "initial_date", initialTime = "initial_time"
        case initialDatetime = "initial_datetime", initialOption = "initial_option"
    }

    /// A button.
    public static func button(
        _ text: String, type: ButtonType? = nil, value: JSONValue? = nil, url: String? = nil, confirm: Confirm? = nil
    ) -> Self {
        .init(tag: .button, confirm: confirm, text: .plain(text), url: url, type: type, value: value)
    }
}

/// Payload of a legacy (HTTP) card action callback (`InteractiveCardActionEvent` in node-sdk).
public struct InteractiveCardActionEvent: Codable, Sendable, Hashable {
    public struct Action: Codable, Sendable, Hashable {
        public var value: JSONValue?
        public var tag: String?
        public var option: String?
        public var timezone: String?
    }
    public var openId: String?
    public var userId: String?
    public var tenantKey: String?
    public var openMessageId: String?
    public var token: String?
    public var action: Action?

    enum CodingKeys: String, CodingKey {
        case openId = "open_id", userId = "user_id", tenantKey = "tenant_key", openMessageId = "open_message_id", token, action
    }
}

/// Helpers mirroring node-sdk `messageCard`.
public enum MessageCard {
    /// A blue-header card with a title and markdown content, serialised as JSON text
    /// (identical to node-sdk `messageCard.defaultCard`).
    public static func defaultCard(title: String, content: String) -> String {
        JSONValue.object([
            "config": ["wide_screen_mode": true],
            "elements": [["tag": "markdown", "content": .string(content)]],
            "header": ["template": "blue", "title": ["content": .string(title), "tag": "plain_text"]],
        ]).jsonString(sortedKeys: true)
    }
}

/// Reads only the `tag` field of an element.
private struct TagProbe: Decodable {
    var tag: String
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        tag = (try? c.decode(String.self, forKey: AnyCodingKey("tag"))) ?? ""
    }
}
