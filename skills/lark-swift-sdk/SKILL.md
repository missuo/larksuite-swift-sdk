---
name: lark-swift-sdk
description: Build Feishu/Lark bots and integrations in Swift with larksuite-swift-sdk (port of @larksuiteoapi/node-sdk). Use when writing Swift code that sends/replies/lists IM messages, downloads message files, lists chat members, receives events or card callbacks over the long connection (WSClient) or webhooks, or calls any Open API.
---

# larksuite-swift-sdk

Swift port of the official Node SDK. Same endpoints, same wire format, same event semantics;
Swift naming. If you know the Node SDK, map it like this:

| Node | Swift |
|---|---|
| `new lark.Client({ appId, appSecret, domain })` | `try LarkClient(appId:appSecret:domain:)` |
| `client.im.v1.message.create({ params, data })` | `client.im.v1.message.create(params: .init(...), body: .init(...))` |
| `{ path: { message_id } }` | labelled argument `messageId:` |
| `snake_case` fields | camelCase properties (wire names unchanged) |
| `res.code !== 0` checks | non-zero `code` **throws** `LarkError.api(LarkAPIError)` |
| `xxxWithIterator` + `for await` | `xxxWithIterator(...)` → `for try await page in ...` |
| `res.writeFile(path)` | `try resp.writeFile(path)` / `resp.data` |
| `lark.withUserAccessToken(t)` etc. | `options: .userAccessToken(t)` / `.tenantKey(k)` / `RequestOptions(...)` |
| `new lark.EventDispatcher({}).register({...})` | `EventDispatcher().register(.imMessageReceiveV1) { e, raw in ... }` |
| `new lark.WSClient({...}).start({ eventDispatcher })` | `try WSClient(.init(...))`; `await ws.start(eventDispatcher:)` |

## Install

```swift
// Package.swift
.package(url: "https://github.com/missuo/larksuite-swift-sdk.git", branch: "main"),
// target dependencies — pick only the API modules you use:
.product(name: "LarkCore", package: "larksuite-swift-sdk"),
.product(name: "LarkIM", package: "larksuite-swift-sdk"),
// or everything: .product(name: "Lark", package: "larksuite-swift-sdk")
```

Swift 6 toolchain, macOS 13+/iOS 16+ (Linux via FoundationNetworking). Only dependency: swift-crypto.

## Client

```swift
import LarkCore
import LarkIM

let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx", domain: .feishu, logLevel: .warn)
// .lark for larksuite.com, .custom("https://...") for private deployments.
// Full options: LarkClient(LarkConfiguration(appId:appSecret:clientAssertionProvider:domain:appType:
//   logLevel:logger:cache:disableTokenCache:httpClient:timeout:source:...))
```

The tenant access token is fetched, cached (expires 3 min early) and shared automatically.

## Sending, replying, history, files, members

```swift
// Send to a chat (receiveIdType: .openId / .userId / .unionId / .email / .chatId)
let sent = try await client.im.v1.message.create(
    params: .init(receiveIdType: .chatId),
    body: .text(to: chatId, "hello \(MessageContent.at(openId))"))   // or .card(to:, cardJSON)
let newId = sent.data?.messageId

// Reply (reply_in_thread: true = topic reply)
_ = try await client.im.v1.message.reply(messageId: rootId, body: .text("ok", replyInThread: false))
_ = try await client.im.v1.message.reply(messageId: rootId, body: .card(["schema": "2.0", "body": ["elements": []]]))

// Arbitrary content: body: .init(receiveId:, msgType: "post", content: MessageContent.post(...))

// History, paged
let params = IM.MessageListQuery(containerIdType: "chat", containerId: chatId,
                                 startTime: String(sinceSeconds), sortType: .byCreateTimeAsc, pageSize: 50)
for try await page in client.im.v1.message.listWithIterator(params: params) {
    for m in page.items ?? [] { print(m.messageId ?? "", m.msgType ?? "", m.body?.content ?? "") }
}
// One page only: try await client.im.v1.message.list(params: params)

// Download an image/file attached to a message (type: "image" or "file")
let file = try await client.im.v1.messageResource.get(messageId: id, fileKey: key, params: .init(type: "image"))
try file.writeFile("/tmp/a.png")          // file.data, file.fileName, file.contentType

// Chat members
var ids: [String] = []
for try await page in client.im.v1.chatMembers.getWithIterator(chatId: chatId, params: .init(memberIdType: .openId, pageSize: 100)) {
    ids += (page.items ?? []).compactMap(\.memberId)
}

// Upload an image, then send it
let img = try await client.im.v1.image.create(body: .init(imageType: "message", image: try LarkFile(path: "/tmp/a.png")))
```

Open enums (`.chatId`, `.byCreateTimeAsc`, ...) also accept string literals: `receiveIdType: "chat_id"`.

## Raw requests (endpoints or fields not modelled)

```swift
let info = try await client.request(.get, "/open-apis/bot/v3/info", as: JSONValue.self)
let botOpenId = info.json?["bot"]?["open_id"]?.stringValue   // top-level fields live in `json`
// With query/body: client.request(.post, "/open-apis/...", query: someEncodable, json: someEncodable, as: T.self)
```

`LarkResponse<T>` has `code`, `msg`, `data: T?`, `logId`, `headers`, `body`, `json` (whole body).

## Errors

```swift
do { ... } catch let LarkError.api(e) {
    print(e.code, e.msg, e.logId ?? "")    // business error (code != 0), any HTTP status
} catch {
    print(error)                            // .http, .transport, .decoding, .tokenUnavailable, ...
}
```

## Receiving events and card callbacks over the long connection

Developer console: Events & Callbacks → subscription mode → "Receive events/callbacks through
persistent connection"; subscribe to the events/callbacks you need. Self-built apps only.

```swift
let dispatcher = EventDispatcher()
    .register(.imMessageReceiveV1) { e, _ in            // typed: IM.MessageReceiveV1Event
        let m = e.message                                 // messageId, chatId, chatType, messageType, content, mentions, rootId, parentId
        let sender = e.sender.senderId?.openId
        Task {                                            // keep handlers fast; do slow work in a Task
            do { try await handle(m, sender, e.text) } catch { print("handler failed:", error) }
        }
        return nil
    }
    .register(.imChatMemberBotAddedV1) { e, _ in print("added to", e.chatId ?? ""); return nil }
    .register(.cardActionTrigger) { e, _ in               // CardActionTriggerEvent
        let value = e.action?.value                       // JSONValue from the button's behaviors[].value
        return CardActionResponse(toast: .init(type: .success, content: "Done"),
                                  card: .raw(updatedCardJSON))   // or .template(id:variables:)
    }
    // Untyped (any event name, payload == Node's flattened object):
    .register("some.event_v1") { event in print(event.payload); return nil }

let ws = try WSClient(.init(appId: "cli_xxx", appSecret: "xxx", domain: .feishu,
                            onReady: { print("connected") }, onError: { print("gave up", $0) },
                            onReconnecting: {}, onReconnected: {}))
await ws.start(eventDispatcher: dispatcher)   // returns after the first attempt; reconnects automatically
await ws.waitUntilClosed()                    // keep a CLI process alive; ws.close() to stop
// await ws.connectionStatus -> .idle/.connecting/.connected/.reconnecting/.failed
```

Rules:
- A handler's return value is sent back to the platform (needed for card callbacks; respond
  within ~3 s). Return `nil` for normal events.
- Never run two long connections with the same app in parallel unless intended: the platform
  delivers each event to only one connection.
- Events may be redelivered; dedupe by `event.eventId` / message id.
- Text content: `e.text` (plain text, `@_user_N` placeholders kept; map them via `m.mentions`).

## Webhooks (HTTP) instead of the long connection

```swift
let dispatcher = EventDispatcher(encryptKey: "...", verificationToken: "...")
// In any HTTP framework:
let resp = await dispatcher.handleWebhook(WebhookRequest(headers: reqHeaders, body: reqBody))
// -> resp.statusCode, resp.headers, resp.body (handles url_verification automatically)
```

Legacy card callbacks: `CardActionHandler(verificationToken:encryptKey:) { event in ... }.handleWebhook(...)`.

## Other APIs and events

All 55 node-sdk API categories (1,680 APIs) are available, one module each:
`Lark<Category>` → `client.<category>.<version>.<resource>.<method>(...)`, e.g.
`LarkContact` → `client.contact.v3.user.get(userId:params:)`, `LarkDocx` →
`client.docx.v1.document.get(documentId:)`, `LarkApproval`, `LarkCalendar`, `LarkDrive`,
`LarkBitable`, `LarkSheets`, `LarkTask`, `LarkVC`, ... (full table in the README).

- Models live in a namespace per category: `IM.MessageListQuery`, `Contact.UserGetQuery`, ...
  (`TaskAPI` and `CalendarAPI` avoid clashing with Swift's `Task` / Foundation's `Calendar`;
  the `event` category's module is `LarkEventAPI`).
- Request types are named `<Resource><Method>Query` / `<Resource><Method>Body`, responses
  `<Resource><Method>Response`; every method has doc comments with the official doc link.
- Typed event keys: `.<category><Resource><Event>` (e.g. `.contactUserCreatedV3`,
  `.approvalInstanceStatusChangedV4`) or `<Namespace>.Events.<name>`. Legacy v1 events
  (`message`, `add_bot`, `app_ticket`, ...) are in `LarkOtherEvents`.
- To find a method: grep `Sources/Lark<Category>/<Category>Service.swift` for the HTTP path
  from the official docs (each method's doc comment ends with `` `METHOD /open-apis/...` ``).
