---
name: lark-swift-bitable
description: Read and write Feishu/Lark Bitable (Base / 多维表格) from Swift with larksuite-swift-sdk's LarkBitable module. Use when creating apps/tables/fields/views, creating, updating, deleting or batch-writing records, searching records with filters and sorting, paging through records, or attaching files to Bitable records.
---

# Bitable (Base) with larksuite-swift-sdk

Module `LarkBitable` (Node: `client.bitable.v1.*`). For client setup, errors, auth options and
the Node→Swift mapping, see the `lark-swift-sdk` skill.

```swift
// Package.swift target dependencies
.product(name: "LarkCore", package: "larksuite-swift-sdk"),
.product(name: "LarkBitable", package: "larksuite-swift-sdk"),
```

```swift
import LarkCore
import LarkBitable

let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx")
```

- Only one version: `client.bitable.v1.<resource>` (`app`, `appTable`, `appTableField`,
  `appTableRecord`, `appTableView`, `appRole`, `appRoleMember`, `appDashboard`, `appTableForm`,
  `appTableFormField`, `appWorkflow`, ...). `client.bitable.appTableRecord` is an alias of `v1`.
- Models: `Bitable.<Resource><Method>Query/Body/Response` (e.g. `Bitable.AppTableRecordSearchBody`).
- `appToken` is the token in the Base URL (`/base/<appToken>?table=<tableId>`).
  A Base inside a wiki has a wiki node token in its URL: resolve it first with `LarkWiki`
  (`client.wiki.v2.space.getNode(params: .init(token: nodeToken))` → `data?.node?.objToken`).
- The app needs access to the Base: add it as a collaborator (or via an app role) or call with
  `options: .userAccessToken(token)`. Otherwise calls fail with a permission error (HTTP 403).

## Apps, tables, fields, views

```swift
let app = try await client.bitable.v1.app.get(appToken: appToken)
print(app.data?.app?.name ?? "", app.data?.app?.isAdvanced ?? false)

let newApp = try await client.bitable.v1.app.create(body: .init(name: "Tracker", folderToken: folderToken))
let newAppToken = newApp.data?.app?.appToken, defaultTableId = newApp.data?.app?.defaultTableId

for try await page in client.bitable.v1.appTable.listWithIterator(appToken: appToken, params: .init(pageSize: 100)) {
    for t in page.items ?? [] { print(t.tableId ?? "", t.name ?? "") }
}

// Create a table with fields (field `type` codes below)
let table = try await client.bitable.v1.appTable.create(appToken: appToken, body: .init(table: .init(
    name: "Tasks", defaultViewName: "All",
    fields: [
        .init(fieldName: "Title", type: 1),
        .init(fieldName: "Status", type: 3, property: .init(options: [.init(name: "Todo"), .init(name: "Done")])),
        .init(fieldName: "Due", type: 5, property: .init(dateFormatter: "yyyy/MM/dd")),
        .init(fieldName: "Owner", type: 11, property: .init(multiple: false)),
    ])))
let tableId = table.data?.tableId ?? ""

// Fields
for try await page in client.bitable.v1.appTableField.listWithIterator(appToken: appToken, tableId: tableId) {
    for f in page.items ?? [] { print(f.fieldId ?? "", f.fieldName, f.type, f.uiType?.rawValue ?? "") }
}
_ = try await client.bitable.v1.appTableField.create(appToken: appToken, tableId: tableId,
    body: .init(fieldName: "Score", type: 2, property: .init(formatter: "0.0")))

// Views
for try await page in client.bitable.v1.appTableView.listWithIterator(appToken: appToken, tableId: tableId) {
    for v in page.items ?? [] { print(v.viewId ?? "", v.viewName ?? "", v.viewType ?? "") }
}
_ = try await client.bitable.v1.appTableView.create(appToken: appToken, tableId: tableId,
    body: .init(viewName: "Board", viewType: .kanban))
```

Field `type` codes: 1 text, 2 number, 3 single select, 4 multi select, 5 date, 7 checkbox,
11 user, 13 phone, 15 URL, 17 attachment, 18 single link, 19 lookup, 20 formula, 21 duplex link,
22 location, 23 group chat, 1001 created time, 1002 modified time, 1003 created by,
1004 modified by, 1005 auto number. `uiType` (`.currency`, `.progress`, `.rating`, ...)
refines a type. `appTableField.update` is a **full** replace (property is overwritten).

## Record values are `[String: JSONValue]`, keyed by field **name**

| Field | Write | Read back (search/list) |
|---|---|---|
| Text | `"hello"` | `[{"type":"text","text":"hello"}]` (array of segments) or a string |
| Number | `12.5` | `12.5` |
| Single / multi select | `"Todo"` / `["A", "B"]` | same |
| Date | ms timestamp `1_735_689_600_000` | ms timestamp |
| Checkbox | `true` | `true` |
| User / group chat | `[["id": "ou_xxx"]]` / `[["id": "oc_xxx"]]` | `[{"id","name","en_name","email"}]` |
| URL | `["text": "Docs", "link": "https://..."]` | same |
| Attachment | `[["file_token": "xxx"]]` | `[{"file_token","name","size","type","url","tmp_url"}]` |
| Link (single/duplex) | `["recxxx"]` | `{"link_record_ids": [...]}` |

JSON keys inside values are wire names (`file_token`, not `fileToken`). `JSONValue` literals
do not support string interpolation: write `.string("\(x)")`. Set a field to `.null` to clear it.
User ids follow `params: .init(userIdType: .openId)` (`.openId` / `.unionId` / `.userId`).

## Create, update, delete records

```swift
let created = try await client.bitable.v1.appTableRecord.create(
    appToken: appToken, tableId: tableId, params: .init(userIdType: .openId),
    body: .init(fields: [
        "Title": .string(title), "Status": "Todo", "Score": 3,
        "Due": 1_735_689_600_000, "Owner": [["id": .string(openId)]],
        "Link": ["text": "Spec", "link": "https://example.com/spec"],
    ]))
let recordId = created.data?.record?.recordId ?? ""

// Partial update: only the given fields change
_ = try await client.bitable.v1.appTableRecord.update(appToken: appToken, tableId: tableId, recordId: recordId,
    body: .init(fields: ["Status": "Done", "Score": .null]))

_ = try await client.bitable.v1.appTableRecord.delete(appToken: appToken, tableId: tableId, recordId: recordId)
```

## Batch operations

Limits per call (from the API docs): `batchCreate` / `batchUpdate` 1,000 records,
`batchDelete` 500, `batchGet` 100. Chunk larger inputs.

```swift
let rows: [[String: JSONValue]] = [["Title": "A"], ["Title": "B"]]
let batch = try await client.bitable.v1.appTableRecord.batchCreate(
    appToken: appToken, tableId: tableId,
    params: .init(userIdType: .openId, clientToken: UUID().uuidString),   // client_token makes retries idempotent
    body: .init(records: rows.map { .init(fields: $0) }))
let ids = (batch.data?.records ?? []).compactMap(\.recordId)

_ = try await client.bitable.v1.appTableRecord.batchUpdate(appToken: appToken, tableId: tableId,
    body: .init(records: ids.map { .init(fields: ["Status": "Done"], recordId: $0) }))

let got = try await client.bitable.v1.appTableRecord.batchGet(appToken: appToken, tableId: tableId,
    body: .init(recordIds: ids, userIdType: .openId, automaticFields: true))
print(got.data?.absentRecordIds ?? [])

_ = try await client.bitable.v1.appTableRecord.batchDelete(appToken: appToken, tableId: tableId,
    body: .init(records: ids))
```

## Search records (filter + sort + pagination)

`appTableRecord.search` is the recommended query API (`list` / `get` are legacy). The filter is
typed; conditions reference field **names**, values are always strings.

```swift
let body = Bitable.AppTableRecordSearchBody(
    viewId: nil,                                 // optional: restrict to a view's records
    fieldNames: ["Title", "Status", "Owner"],    // omit to return all fields
    sort: [.init(fieldName: "Due", desc: false)],
    filter: .init(conjunction: .and, conditions: [
        .init(fieldName: "Status", operator: .is, value: ["Todo"]),
        .init(fieldName: "Title", operator: .contains, value: ["bug"]),
        .init(fieldName: "Owner", operator: .isNotEmpty, value: []),
        .init(fieldName: "Due", operator: .isLess, value: ["ExactDate", "1735689600000"]),
    ]),
    automaticFields: true)                       // adds created/modified time and user

func text(_ v: JSONValue?) -> String {           // text comes back as segments
    v?.stringValue ?? (v?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
}

for try await page in client.bitable.v1.appTableRecord.searchWithIterator(
    appToken: appToken, tableId: tableId, params: .init(userIdType: .openId, pageSize: 500), body: body)
{
    for r in page.items ?? [] { print(r.recordId ?? "", text(r.fields["Title"]), r.fields["Status"] ?? .null) }
}
// One page: try await client.bitable.v1.appTableRecord.search(appToken:tableId:params:body:) -> data?.total
```

- Operators (`Bitable.FilterConditionOperator`): `.is`, `.isNot`, `.contains`, `.doesNotContain`,
  `.isEmpty`, `.isNotEmpty` (value `[]`), `.isGreater`, `.isGreaterEqual`, `.isLess`, `.isLessEqual`.
- Date values: `["ExactDate", "<ms>"]`, `["Today"]`, `["Tomorrow"]`, `["Yesterday"]`, ...
- Nested logic: `filter: .init(conjunction: .or, children: [.init(conjunction: .and, conditions: [...])])`.
- Max `pageSize` is 500. With advanced permissions the caller needs manage access, otherwise the
  search can succeed with empty results.

## Attachments

Uploading needs `LarkDrive` (`client.drive.v1.media.uploadAll`, `parentType: .bitableFile`
or `.bitableImage`, `parentNode` = the Base's `appToken`); then put the `file_token` into the
attachment field with `LarkBitable`. `uploadAll` takes files up to 20 MB; larger files use
`media.uploadPrepare` / `uploadPart` / `uploadFinish`.

```swift
import LarkDrive
let file = try LarkFile(path: "/tmp/report.pdf")
let up = try await client.drive.v1.media.uploadAll(body: .init(
    fileName: file.fileName, parentType: .bitableFile, parentNode: appToken, size: file.data.count, file: file))
let fileToken = up.data?.fileToken ?? ""
```

```swift
_ = try await client.bitable.v1.appTableRecord.update(appToken: appToken, tableId: tableId, recordId: recordId,
    body: .init(fields: ["Files": [["file_token": .string(fileToken)]]]))
```

Download: `client.drive.v1.media.download(fileToken:)` (`try file.writeFile(path)`), or use the
`tmp_url` / `url` in the record value.

## Gotchas

- Business errors throw `LarkError.api` (`e.code`, `e.msg`, `e.logId`). Writes to the same table
  must not run concurrently: send them one after another (batch instead of parallel calls).
- Tables synced from other data sources are read-only for records.
- Missing an API? Never invent a method; grep `Sources/LarkBitable/BitableService.swift` for the
  path, or call it raw: `client.request(.post, "/open-apis/bitable/v1/...", json: body, as: JSONValue.self)`.
- `LarkBase` (`client.base.v2`) only has advanced-permission roles; data APIs live in `LarkBitable`.
