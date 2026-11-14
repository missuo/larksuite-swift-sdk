// A minimal long-connection bot: replies to text messages and handles a card button.
//
//   LARK_APP_ID=cli_xxx LARK_APP_SECRET=xxx swift run lark-bot-example
//
// Enable "Receive events/callbacks through persistent connection" in the developer
// console and subscribe to `im.message.receive_v1` and `card.action.trigger`.
import Foundation
import LarkCore
import LarkIM

let env = ProcessInfo.processInfo.environment
guard let appId = env["LARK_APP_ID"], let appSecret = env["LARK_APP_SECRET"] else {
    print("Set LARK_APP_ID and LARK_APP_SECRET")
    exit(1)
}
let domain: LarkDomain = env["LARK_DOMAIN"] == "lark" ? .lark : .feishu

let client = try LarkClient(appId: appId, appSecret: appSecret, domain: domain, logLevel: .warn)

@Sendable func choiceCard(chosen: String?) -> JSONValue {
    var elements: [JSONValue] = [["tag": "markdown", "content": "Pick one"]]
    if let chosen {
        elements.append(["tag": "markdown", "content": .string("Chosen: **\(chosen)**")])
    } else {
        for option in ["A", "B"] {
            elements.append([
                "tag": "button", "text": ["tag": "plain_text", "content": .string(option)],
                "behaviors": [["type": "callback", "value": ["option": .string(option)]]],
            ])
        }
    }
    return ["schema": "2.0", "body": ["elements": .array(elements)]]
}

let dispatcher = EventDispatcher(logLevel: .info)
    .register(.imMessageReceiveV1) { event, _ in
        // Do slow work outside the handler so the ack is sent promptly.
        guard let messageId = event.message?.messageId else { return nil }
        Task {
            do {
                let text = event.text ?? "[\(event.message?.messageType ?? "unknown")]"
                if text.contains("card") {
                    _ = try await client.im.v1.message.reply(messageId: messageId, body: .card(choiceCard(chosen: nil)))
                } else {
                    _ = try await client.im.v1.message.reply(messageId: messageId, body: .text("echo: \(text)"))
                }
            } catch {
                print("reply failed: \(error)")
            }
        }
        return nil
    }
    .register(.cardActionTrigger) { event, _ in
        let option = event.action?.value?["option"]?.stringValue ?? "?"
        return CardActionResponse(toast: .init(type: .success, content: "You chose \(option)"), card: .raw(choiceCard(chosen: option)))
    }

let ws = try WSClient(
    WSClientOptions(
        appId: appId, appSecret: appSecret, domain: domain,
        onReady: { print("connected") },
        onError: { print("gave up: \($0)") },
        onReconnecting: { print("reconnecting...") },
        onReconnected: { print("reconnected") }))
await ws.start(eventDispatcher: dispatcher)
await ws.waitUntilClosed()
