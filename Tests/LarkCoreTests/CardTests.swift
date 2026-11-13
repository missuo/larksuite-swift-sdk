import Foundation
import Testing
@testable import LarkCore

@Suite struct CardTests {
    // Produced by node-sdk utils/message-card.ts:
    //   defaultCard({ title: '标题 "q"', content: '**hi**\n<at id=all></at>' })
    let nodeDefaultCard =
        #"{"config":{"wide_screen_mode":true},"elements":[{"tag":"markdown","content":"**hi**\n<at id=all></at>"}],"header":{"template":"blue","title":{"content":"标题 \"q\"","tag":"plain_text"}}}"#

    @Test func defaultCardMatchesNode() throws {
        let swift = MessageCard.defaultCard(title: #"标题 "q""#, content: "**hi**\n<at id=all></at>")
        #expect(try JSONValue(jsonString: swift) == JSONValue(jsonString: nodeDefaultCard))
    }

    @Test func typedCardEncodesWireNames() throws {
        let card = InteractiveCard(
            config: .init(updateMulti: true),
            header: .init(title: .init("Approve?", i18n: ["en_us": "Approve?"]), template: .orange),
            elements: [
                .markdown(.init("**Deploy** v1.2", textAlign: .center)),
                .divider,
                .div(.init(text: .markdown("x"), fields: [.init(isShort: true, text: .plain("a"))])),
                .image(.init(imgKey: "img_v3_x", mode: .fitHorizontal)),
                .note(.init([.text(.plain("n")), .image(.init(imgKey: "img_y"))])),
                .action(.init([
                    .button("OK", type: .primary, value: ["kind": "ok"], confirm: .init(title: "Sure?", text: "Really")),
                    .init(tag: .selectStatic, placeholder: .plain("pick"), option: [.init(text: "A", value: "a")]),
                    .init(tag: .overflow, options: [.init(text: "Docs", url: "https://x", multiURL: .init(url: "https://x", pcURL: "https://pc"))]),
                ], layout: .flow)),
                .raw(["tag": "column_set", "columns": []]),
            ],
            cardLink: .init(url: "https://open", iosURL: "https://ios"))
        let json = try JSONValue(encoding: card)
        #expect(json["config"]?["update_multi"] == .bool(true))
        #expect(json["header"]?["template"]?.stringValue == "orange")
        #expect(json["header"]?["title"]?["tag"]?.stringValue == "plain_text")
        #expect(json["card_link"]?["ios_url"]?.stringValue == "https://ios")
        let els = try #require(json["elements"]?.arrayValue)
        #expect(els.map { $0["tag"]?.stringValue } == ["markdown", "hr", "div", "img", "note", "action", "column_set"])
        #expect(els[0]["text_align"]?.stringValue == "center")
        #expect(els[2]["fields"]?[0]?["is_short"] == .bool(true))
        #expect(els[2]["text"]?["tag"]?.stringValue == "lark_md")
        #expect(els[3]["img_key"]?.stringValue == "img_v3_x")
        #expect(els[3]["mode"]?.stringValue == "fit_horizontal")
        #expect(els[4]["elements"]?[1]?["tag"]?.stringValue == "img")
        let actions = try #require(els[5]["actions"]?.arrayValue)
        #expect(actions[0]["type"]?.stringValue == "primary")
        #expect(actions[0]["confirm"]?["title"]?["content"]?.stringValue == "Sure?")
        #expect(actions[1]["tag"]?.stringValue == "select_static")
        #expect(actions[1]["option"]?[0]?["value"]?.stringValue == "a")
        #expect(actions[2]["options"]?[0]?["multi_utl"]?["pc_url"]?.stringValue == "https://pc")
        #expect(els[5]["layout"]?.stringValue == "flow")

        // Round trip.
        let decoded = try json.decode(as: InteractiveCard.self)
        #expect(decoded == card)
        #expect(try JSONValue(jsonString: try card.jsonString()) == json)
    }

    @Test func legacyCardActionEventDecodes() throws {
        let body = #"{"open_id":"ou_1","user_id":"u1","tenant_key":"tk","open_message_id":"om_1","token":"c-tok","action":{"value":{"k":"v"},"tag":"button","option":"o","timezone":"Asia/Shanghai"}}"#
        let e = try LarkEvent(body: JSONValue(jsonString: body)).decode(InteractiveCardActionEvent.self)
        #expect(e.openId == "ou_1")
        #expect(e.openMessageId == "om_1")
        #expect(e.action?.value?["k"]?.stringValue == "v")
        #expect(e.action?.timezone == "Asia/Shanghai")
    }
}
