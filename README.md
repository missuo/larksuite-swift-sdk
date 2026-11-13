# larksuite-swift-sdk

Swift SDK for the Feishu / Lark Open Platform — a faithful port of the official
[`@larksuiteoapi/node-sdk`](https://github.com/larksuite/node-sdk). The whole API surface
(**1,680 APIs in 55 categories, 227 events**) is generated from node-sdk 1.76.0 and every
API is covered by a parity test against the node-sdk definition.

- `async`/`await` APIs with typed `Codable` models: `client.im.v1.message.create(...)`
- Long-connection client (`WSClient`) — receive events and card callbacks without a public URL
- Event dispatcher with typed events and card callbacks; framework-agnostic webhooks
- Managed tenant / app / user tokens, marketplace (ISV) apps, keyless ClientAssertion
- Pagination as `AsyncSequence`, multipart uploads, file downloads
- Swift 6 strict concurrency; a single dependency (`apple/swift-crypto`)

## Requirements

- Swift 6.0+ (Xcode 16+)
- macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+, or Linux

## Installation

### Swift Package Manager

Add the package to `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyBot",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/missuo/larksuite-swift-sdk.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "MyBot",
            dependencies: [
                .product(name: "LarkCore", package: "larksuite-swift-sdk"),  // client, events, WSClient
                .product(name: "LarkIM", package: "larksuite-swift-sdk"),    // + the API categories you use
            ]
        ),
    ]
)
```

Then `import LarkCore` and the API modules you added (`import LarkIM`, ...).

### Xcode

File → Add Package Dependencies… → `https://github.com/missuo/larksuite-swift-sdk.git`,
then pick `LarkCore` plus the API products you need.

### Which products to add

| Product | What you get |
|---|---|
| `LarkCore` | Always needed: `LarkClient`, tokens, `EventDispatcher`, `CardActionHandler`, `WSClient`, webhooks, raw requests |
| `Lark<Category>` | One per API category, e.g. `LarkIM`, `LarkContact`, `LarkDocx`. Adds `client.<category>` and the category's typed events |
| `LarkOtherEvents` | Typed legacy v1 events (`message`, `add_bot`, `app_ticket`, …) and events of categories without APIs |
| `Lark` | Everything (`import Lark` re-exports all modules). Convenient, but compiles all 55 categories |

Prefer adding only the categories you use — each is an independent module, so build times
stay small. The full list is [at the end of this file](#api-categories).

## Quick start: a long-connection bot

In the developer console, enable the bot capability, then under *Events & Callbacks* choose
**Receive events/callbacks through persistent connection** and subscribe to
`im.message.receive_v1` (and `card.action.trigger` for card buttons).

```swift
import LarkCore
import LarkIM

let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx")   // domain: .lark for larksuite.com

let dispatcher = EventDispatcher()
    .register(.imMessageReceiveV1) { event, _ in                   // typed IM.MessageReceiveV1Event
        Task {
            _ = try await client.im.v1.message.reply(
                messageId: event.message.messageId,
                body: .text("echo: \(event.text ?? "")"))
        }
        return nil
    }
    .register(.cardActionTrigger) { event, _ in                    // card button clicked
        CardActionResponse(toast: .init(type: .success, content: "Got it"))
    }

let ws = try WSClient(.init(appId: "cli_xxx", appSecret: "xxx", onReady: { print("connected") }))
await ws.start(eventDispatcher: dispatcher)   // reconnects automatically
await ws.waitUntilClosed()                    // keep the process alive
```

A complete example lives in [`Examples/LongConnectionBot`](Examples/LongConnectionBot/main.swift):

```bash
LARK_APP_ID=cli_xxx LARK_APP_SECRET=xxx swift run lark-bot-example
```

Keep handlers fast: start slow work in a `Task` and return. Only one long connection per app
receives a given event, so don't run two copies of the same bot unintentionally.

## Calling APIs

Every API is `client.<category>.<version>.<resource>.<method>(...)`. Path parameters are
labelled arguments, query parameters go in `params:`, the request body in `body:`. Field names
are the camelCase form of the official snake_case names.

```swift
// Send a message
let sent = try await client.im.v1.message.create(
    params: .init(receiveIdType: .chatId),
    body: .init(receiveId: "oc_xxx", msgType: "text", content: MessageContent.text("hello")))
print(sent.data?.messageId ?? "", sent.logId ?? "")

// Shorthands for common bodies
_ = try await client.im.v1.message.create(params: .init(receiveIdType: .openId), body: .card(to: "ou_xxx", cardJSON))
_ = try await client.im.v1.message.reply(messageId: "om_xxx", body: .text("ok", replyInThread: true))

// Look up a user
let user = try await client.contact.v3.user.get(userId: "ou_xxx", params: .init(userIdType: .openId))
print(user.data?.user?.name ?? "")
```

### Pagination

Every paginated API also has a `…WithIterator` variant that returns an `AsyncSequence` of pages:

```swift
for try await page in client.im.v1.chatMembers.getWithIterator(chatId: "oc_xxx", params: .init(pageSize: 100)) {
    for member in page.items ?? [] { print(member.memberId ?? "") }
}
```

### Uploading and downloading files

```swift
let image = try await client.im.v1.image.create(
    body: .init(imageType: "message", image: try LarkFile(path: "/tmp/photo.png")))
print(image.data?.imageKey ?? "")

let file = try await client.im.v1.messageResource.get(
    messageId: "om_xxx", fileKey: "file_xxx", params: .init(type: "file"))
try file.writeFile("/tmp/download.bin")      // or use file.data / file.fileName / file.contentType
```

### Request options (user tokens, tenants, headers)

The last parameter of every API is `options:` (the equivalent of node-sdk's `withXxx` helpers):

```swift
try await client.docx.v1.document.get(documentId: "doc_xxx", options: .userAccessToken("u-xxx"))
try await client.im.v1.chat.list(options: .tenantKey("tenant_xxx"))          // marketplace apps
try await client.im.v1.chat.list(options: RequestOptions(headers: ["X-Request-Id": "1"], timeout: 10))
```

### Responses and errors

APIs return `LarkResponse<T>` with `code`, `msg`, `data`, `logId`, `headers`, the raw `body`
and `json` (the whole body as untyped JSON). A non-zero business `code` is thrown:

```swift
do {
    _ = try await client.im.v1.message.create(params: .init(receiveIdType: .chatId), body: .text(to: "oc_x", "hi"))
} catch let LarkError.api(error) {
    print(error.code, error.msg, error.logId ?? "")   // business error
} catch {
    print(error)                                     // network, HTTP, decoding, token errors
}
```

### Raw requests

For endpoints or fields that aren't modelled:

```swift
let info = try await client.request(.get, "/open-apis/bot/v3/info", as: JSONValue.self)
let botOpenId = info.json?["bot"]?["open_id"]?.stringValue
```

## Client configuration

```swift
let client = try LarkClient(LarkConfiguration(
    appId: "cli_xxx",
    appSecret: "xxx",                     // or clientAssertionProvider: for keyless auth
    domain: .feishu,                      // .lark, or .custom("https://...")
    appType: .selfBuild,                  // .isv for marketplace apps
    logLevel: .info,
    logger: ConsoleLarkLogger(),          // implement LarkLogger to bridge to swift-log / os.Logger
    cache: DefaultLarkCache.shared,       // implement LarkCache to share tokens (e.g. Redis)
    httpClient: URLSessionHTTPClient()    // implement LarkHTTPClient to use another HTTP stack
))
```

User access tokens: `client.accessToken.retrieve(byAuthorizationCode:)` / `.refresh(_:)`
(OAuth v3), or the cached `client.userAccessToken` helper.

## Events and card callbacks

```swift
let dispatcher = EventDispatcher(encryptKey: "...", verificationToken: "...")  // keys only needed for webhooks
    .register(.contactUserCreatedV3) { event, _ in print(event.object?.name ?? ""); return nil }
    .register(.imMessageReceiveV1) { event, raw in print(raw.eventId ?? ""); return nil }
    .register("any.event_v1") { event in print(event.payload); return nil }   // untyped
```

Each category module exposes its events as typed keys (`.imMessageReceiveV1`,
`.approvalInstanceStatusChangedV4`, …), also listed under `IM.Events`, `Contact.Events`, etc.
The untyped `LarkEvent.payload` is the same flattened object node-sdk passes to handlers.

Card callbacks return a `CardActionResponse` (toast and/or an updated card):

```swift
dispatcher.register(.cardActionTrigger) { event, _ in
    let value = event.action?.value          // the value attached to the clicked component
    return CardActionResponse(toast: .init(type: .info, content: "Saved"), card: .raw(newCardJSON))
}
```

### Webhooks instead of the long connection

The SDK is independent of any HTTP framework; pass the request headers and body in and
write the response out:

```swift
let response = await dispatcher.handleWebhook(WebhookRequest(headers: headers, body: body))
// response.statusCode, response.headers, response.body — URL verification is handled for you.
```

Legacy card callbacks use `CardActionHandler(verificationToken:encryptKey:handler:)` the same way.

## Differences from node-sdk

The wire behaviour is identical. The few intentional API differences (Swift naming, thrown
business errors, typed events, …) are listed in
[AGENTS.md](AGENTS.md#allowed-deviations-from-node-sdk).

## For AI agents

[`skills/lark-swift-sdk/SKILL.md`](skills/lark-swift-sdk/SKILL.md) is an agent skill that
teaches coding agents how to use this SDK.

## Development

```bash
swift build && swift test           # ~1.9k tests

# Regenerate the APIs from a node-sdk checkout
cd Tools/codegen && npm install
node extract.js <path-to-node-sdk> ir.json   # node-sdk → IR
node generate.js ir.json ../..               # IR → Swift modules, parity tests, Package.swift
node status.js ir.json ../..                 # refresh the coverage table in PLAN.md
```

Progress is tracked in [PLAN.md](PLAN.md); contribution rules (parity with node-sdk,
mandatory tests) are in [AGENTS.md](AGENTS.md).

## API categories

| Product | Client property | APIs |
|---|---|---:|
| `LarkACS` | `client.acs` | 14 |
| `LarkAdmin` | `client.admin` | 14 |
| `LarkAily` | `client.aily` | 31 |
| `LarkAPaaS` | `client.apaas` | 49 |
| `LarkApplication` | `client.application` | 32 |
| `LarkApproval` | `client.approval` | 46 |
| `LarkAttendance` | `client.attendance` | 39 |
| `LarkAuth` | `client.auth` | 5 |
| `LarkAuthen` | `client.authen` | 5 |
| `LarkBaike` | `client.baike` | 13 |
| `LarkBase` | `client.base` | 3 |
| `LarkBitable` | `client.bitable` | 49 |
| `LarkBlock` | `client.block` | 3 |
| `LarkBoard` | `client.board` | 7 |
| `LarkBot` | `client.bot` | 1 |
| `LarkCalendar` | `client.calendar` | 44 |
| `LarkCardKit` | `client.cardkit` | 10 |
| `LarkCompensation` | `client.compensation` | 21 |
| `LarkContact` | `client.contact` | 71 |
| `LarkCoreHR` | `client.corehr` | 269 |
| `LarkDirectory` | `client.directory` | 21 |
| `LarkDocs` | `client.docs` | 1 |
| `LarkDocumentAI` | `client.documentAi` | 18 |
| `LarkDocx` | `client.docx` | 19 |
| `LarkDrive` | `client.drive` | 64 |
| `LarkEHR` | `client.ehr` | 2 |
| `LarkEventAPI` | `client.event` | 2 |
| `LarkHelpdesk` | `client.helpdesk` | 50 |
| `LarkHire` | `client.hire` | 182 |
| `LarkHumanAuthentication` | `client.humanAuthentication` | 1 |
| `LarkIM` | `client.im` | 77 |
| `LarkLingo` | `client.lingo` | 14 |
| `LarkMail` | `client.mail` | 107 |
| `LarkMDM` | `client.mdm` | 4 |
| `LarkMinutes` | `client.minutes` | 8 |
| `LarkMoments` | `client.moments` | 1 |
| `LarkOKR` | `client.okr` | 37 |
| `LarkOpticalCharRecognition` | `client.opticalCharRecognition` | 1 |
| `LarkPassport` | `client.passport` | 3 |
| `LarkPayroll` | `client.payroll` | 12 |
| `LarkPerformance` | `client.performance` | 21 |
| `LarkPersonalSettings` | `client.personalSettings` | 6 |
| `LarkReport` | `client.report` | 3 |
| `LarkSearch` | `client.search` | 15 |
| `LarkSecurityAndCompliance` | `client.securityAndCompliance` | 13 |
| `LarkSheets` | `client.sheets` | 27 |
| `LarkSpark` | `client.spark` | 24 |
| `LarkSpeechToText` | `client.speechToText` | 2 |
| `LarkTask` | `client.task` | 80 |
| `LarkTenant` | `client.tenant` | 2 |
| `LarkTranslation` | `client.translation` | 2 |
| `LarkTrustParty` | `client.trustParty` | 5 |
| `LarkVC` | `client.vc` | 113 |
| `LarkVerification` | `client.verification` | 1 |
| `LarkWiki` | `client.wiki` | 16 |

## License

MIT, same as node-sdk.
