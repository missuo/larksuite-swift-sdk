# larksuite-swift-sdk

Swift SDK for the Feishu / Lark Open Platform — a faithful port of the official
[`@larksuiteoapi/node-sdk`](https://github.com/larksuite/node-sdk) (API surface generated from
node-sdk 1.76.0).

- Typed, `Codable` models and `async`/`await` APIs: `client.im.v1.message.create(...)`
- Long-connection bot client (`WSClient`) — no public webhook URL needed
- Event dispatcher with typed events and card callbacks; framework-agnostic webhooks
- Managed tenant / app / user tokens, marketplace apps, keyless ClientAssertion
- Pagination as `AsyncSequence`, multipart uploads, file downloads
- Swift 6 strict concurrency; one dependency (`apple/swift-crypto`)

Coverage per API category is tracked in [PLAN.md](PLAN.md).

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/<owner>/larksuite-swift-sdk.git", branch: "main"),
],
targets: [
    .executableTarget(name: "MyBot", dependencies: [
        .product(name: "LarkCore", package: "larksuite-swift-sdk"),
        .product(name: "LarkIM", package: "larksuite-swift-sdk"),   // only the API modules you use
    ]),
]
```

`import Lark` (product `Lark`) re-exports every module.
Requires Swift 6, macOS 13 / iOS 16 or later, or Linux.

## Quick start: a long-connection bot

```swift
import LarkCore
import LarkIM

let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx")

let dispatcher = EventDispatcher()
    .register(.imMessageReceiveV1) { event, _ in
        Task {
            _ = try await client.im.v1.message.reply(
                messageId: event.message.messageId, body: .text("echo: \(event.text ?? "")"))
        }
        return nil
    }
    .register(.cardActionTrigger) { event, _ in
        CardActionResponse(toast: .init(type: .success, content: "Got it"))
    }

let ws = try WSClient(.init(appId: "cli_xxx", appSecret: "xxx", onReady: { print("connected") }))
await ws.start(eventDispatcher: dispatcher)
await ws.waitUntilClosed()
```

Run the full example with `LARK_APP_ID=... LARK_APP_SECRET=... swift run lark-bot-example`.

## Calling APIs

```swift
let resp = try await client.im.v1.message.create(
    params: .init(receiveIdType: .chatId),
    body: .init(receiveId: "oc_xxx", msgType: "text", content: MessageContent.text("hello")))
print(resp.data?.messageId ?? "", resp.logId ?? "")

for try await page in client.im.v1.chatMembers.getWithIterator(chatId: "oc_xxx") {
    print(page.items?.compactMap(\.memberId) ?? [])
}

let file = try await client.im.v1.messageResource.get(messageId: "om_xxx", fileKey: "img_xxx", params: .init(type: "image"))
try file.writeFile("/tmp/image.png")

// Any endpoint, untyped
let info = try await client.request(.get, "/open-apis/bot/v3/info", as: JSONValue.self)
```

Per-request options replace node-sdk's `withXxx` helpers:
`options: .userAccessToken("u-...")`, `.tenantKey("...")`, `.tenantAccessToken("t-...")`,
`.helpDeskCredential`, or `RequestOptions(headers:query:timeout:...)`.

A non-zero business `code` throws `LarkError.api(LarkAPIError)` (with `code`, `msg`, `logId`).

## Webhooks

```swift
let dispatcher = EventDispatcher(encryptKey: "...", verificationToken: "...")
let response = await dispatcher.handleWebhook(WebhookRequest(headers: headers, body: body))
// Write response.statusCode / response.headers / response.body with your HTTP framework.
```

## Differences from node-sdk

The wire behaviour is identical; the few intentional API differences (Swift naming, thrown
business errors, typed events, ...) are listed in [AGENTS.md](AGENTS.md#allowed-deviations-from-node-sdk).

## For agents

`skills/lark-swift-sdk/SKILL.md` is an agent skill describing how to use this SDK.

## Development

```bash
swift build && swift test
cd Tools/codegen && npm install
node extract.js /path/to/node-sdk ir.json   # node-sdk → IR
node generate.js ir.json ../.. im           # IR → Swift modules, parity tests, Package.swift
node status.js ir.json ../..                # refresh the coverage table in PLAN.md
```

Contribution rules (parity with node-sdk, mandatory tests) are in [AGENTS.md](AGENTS.md).

## License

MIT (same as node-sdk).
