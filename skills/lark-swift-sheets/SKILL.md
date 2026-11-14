---
name: lark-swift-sheets
description: Work with Feishu/Lark Sheets (spreadsheets / 电子表格) from Swift with larksuite-swift-sdk's LarkSheets module. Use when creating spreadsheets, listing sheets (tabs), finding/replacing text, managing filters, filter views and float images, or reading/writing/appending cell values (via raw v2 requests, which node-sdk does not generate).
---

# Sheets with larksuite-swift-sdk

Module `LarkSheets` (Node: `client.sheets.v3.*`). For client setup, errors, auth options and
the Node→Swift mapping, see the `lark-swift-sdk` skill.

```swift
// Package.swift target dependencies
.product(name: "LarkCore", package: "larksuite-swift-sdk"),
.product(name: "LarkSheets", package: "larksuite-swift-sdk"),
```

```swift
import LarkCore
import LarkSheets

let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx")
```

- Only `v3` is generated: `client.sheets.v3.<resource>` with `spreadsheet`, `spreadsheetSheet`,
  `spreadsheetSheetFilter`, `spreadsheetSheetFilterView`, `spreadsheetSheetFilterViewCondition`,
  `spreadsheetSheetFloatImage` (also aliased as `client.sheets.spreadsheet`, ...).
- **There is no generated API for cell values** (read/write/append/prepend/batch), nor for adding
  or deleting sheets: node-sdk 1.76.0 has none of the `/open-apis/sheets/v2/...` endpoints. Use
  `client.request(...)` as shown below. Never invent methods such as `values.get`.
- `spreadsheetToken` is the token in the URL (`/sheets/<token>?sheet=<sheetId>`); a sheet inside
  a wiki has a wiki node token: resolve it with `LarkWiki` (`client.wiki.v2.space.getNode`
  → `data?.node?.objToken`).
- The app must have access to the spreadsheet (share it with the app, or create it with the app),
  or call with `options: .userAccessToken(token)`.

## Spreadsheets and sheets (tabs)

```swift
let created = try await client.sheets.v3.spreadsheet.create(body: .init(title: "Report", folderToken: folderToken))
let token = created.data?.spreadsheet?.spreadsheetToken ?? ""
print(created.data?.spreadsheet?.url ?? "")

let info = try await client.sheets.v3.spreadsheet.get(spreadsheetToken: token, params: .init(userIdType: .openId))
print(info.data?.spreadsheet?.title ?? "", info.data?.spreadsheet?.ownerId ?? "")
_ = try await client.sheets.v3.spreadsheet.patch(spreadsheetToken: token, body: .init(title: "Report 2025"))

let sheets = try await client.sheets.v3.spreadsheetSheet.query(spreadsheetToken: token)
for s in sheets.data?.sheets ?? [] {
    print(s.sheetId ?? "", s.title ?? "", s.index ?? 0, s.gridProperties?.rowCount ?? 0, s.resourceType ?? "")
}
let sheetId = sheets.data?.sheets?.first?.sheetId ?? ""
let one = try await client.sheets.v3.spreadsheetSheet.get(spreadsheetToken: token, sheetId: sheetId)
print(one.data?.sheet?.merges?.count ?? 0)
```

`resourceType` is `"sheet"` for normal grid tabs; other values (e.g. an embedded Bitable) are
not grids. Omit `folderToken` to create the spreadsheet in the caller's root folder.

## Ranges

A range is `<sheetId>!<A1 notation>`: `"\(sheetId)!A1:C10"`, whole columns `"\(sheetId)!A:C"`.
Use the `sheetId` (e.g. `0b6377`), not the tab title.

## Find and replace

```swift
let found = try await client.sheets.v3.spreadsheetSheet.find(spreadsheetToken: token, sheetId: sheetId,
    body: .init(findCondition: .init(range: "\(sheetId)!A1:Z1000", matchCase: false, matchEntireCell: false), find: "TODO"))
print(found.data?.findResult?.matchedCells ?? [])          // e.g. ["B3", "C7"]

let replaced = try await client.sheets.v3.spreadsheetSheet.replace(spreadsheetToken: token, sheetId: sheetId,
    body: .init(findCondition: .init(range: "\(sheetId)!A1:Z1000", searchByRegex: false), find: "TODO", replacement: "DONE"))
print(replaced.data?.replaceResult?.rowsCount ?? 0)
```

Other `FindCondition` options: `searchByRegex`, `includeFormulas`.

## Filters and filter views

```swift
// The sheet's single filter: one condition per column
_ = try await client.sheets.v3.spreadsheetSheetFilter.create(spreadsheetToken: token, sheetId: sheetId,
    body: .init(range: "\(sheetId)!A1:E100", col: "C", condition: .init(filterType: "multiValue", expected: ["Done"])))
_ = try await client.sheets.v3.spreadsheetSheetFilter.update(spreadsheetToken: token, sheetId: sheetId,
    body: .init(col: "D", condition: .init(filterType: "number", compareType: "less", expected: ["6"])))
let filter = try await client.sheets.v3.spreadsheetSheetFilter.get(spreadsheetToken: token, sheetId: sheetId)
print(filter.data?.sheetFilterInfo?.filteredOutRows ?? [])
_ = try await client.sheets.v3.spreadsheetSheetFilter.delete(spreadsheetToken: token, sheetId: sheetId)

// Filter views: named views over a range; conditions are keyed by column letter
let view = try await client.sheets.v3.spreadsheetSheetFilterView.create(spreadsheetToken: token, sheetId: sheetId,
    body: .init(filterViewName: "Open items", range: "\(sheetId)!A1:E100"))
let viewId = view.data?.filterView?.filterViewId ?? ""
_ = try await client.sheets.v3.spreadsheetSheetFilterViewCondition.create(spreadsheetToken: token, sheetId: sheetId,
    filterViewId: viewId, body: .init(conditionId: "C", filterType: "text", compareType: "beginsWith", expected: ["Open"]))
let views = try await client.sheets.v3.spreadsheetSheetFilterView.query(spreadsheetToken: token, sheetId: sheetId)
for v in views.data?.items ?? [] { print(v.filterViewId ?? "", v.filterViewName ?? "", v.range ?? "") }
```

`filterType` / `compareType` / `expected` are free strings on the wire (see the official
filter docs for the allowed values); `expected` is always an array of strings.

Float images: `spreadsheetSheetFloatImage.create(spreadsheetToken:sheetId:body:)` with a
`floatImageToken` from a `LarkDrive` media upload (`parentType: .sheetImage`, `parentNode` = token).

## Cell values (raw v2 requests)

The v2 value APIs use **camelCase** JSON (`valueRange`, `valueRenderOption`), unlike v3.
`client.request` returns the `data` object as `JSONValue`; business errors still throw `LarkError.api`.

```swift
// Read one range
let range = "\(sheetId)!A1:C10"
let read = try await client.request(.get,
    "/open-apis/sheets/v2/spreadsheets/\(token)/values/\(LarkURL.escapePathSegment(range))",
    query: ["valueRenderOption": "ToString", "dateTimeRenderOption": "FormattedString"], as: JSONValue.self)
let rows = read.data?["valueRange"]?["values"]?.arrayValue ?? []    // rows of cells; empty cells are null
for row in rows { print((row.arrayValue ?? []).map { $0.stringValue ?? "" }) }

// Read several ranges (comma-separated)
let multi = try await client.request(.get, "/open-apis/sheets/v2/spreadsheets/\(token)/values_batch_get",
    query: ["ranges": "\(sheetId)!A1:B2,\(sheetId)!D1:D5"], as: JSONValue.self)
for vr in multi.data?["valueRanges"]?.arrayValue ?? [] { print(vr["range"]?.stringValue ?? "", vr["values"] ?? .null) }

// Overwrite a range (it should cover exactly the size of `values`)
let write: JSONValue = ["valueRange": [
    "range": .string("\(sheetId)!A1:C2"),
    "values": [["Name", "Score", "Profile"],
               ["Alice", 95, ["type": "url", "text": "Profile", "link": "https://example.com"]]],
]]
let w = try await client.request(.put, "/open-apis/sheets/v2/spreadsheets/\(token)/values", json: write, as: JSONValue.self)
print(w.data?["updatedCells"]?.intValue ?? 0, w.data?["revision"]?.intValue ?? 0)

// Append rows after the last non-empty row of the range
let rowsToAdd: JSONValue = ["valueRange": [
    "range": .string("\(sheetId)!A:C"),
    "values": [["Bob", 88, ["type": "formula", "text": "=B2+1"]]],
]]
_ = try await client.request(.post, "/open-apis/sheets/v2/spreadsheets/\(token)/values_append",
    query: ["insertDataOption": "INSERT_ROWS"], json: rowsToAdd, as: JSONValue.self)

// Write several ranges at once
let batch: JSONValue = ["valueRanges": [
    ["range": .string("\(sheetId)!E1:E1"), "values": [["Total"]]],
    ["range": .string("\(sheetId)!F1:F2"), "values": [[1], [2]]],
]]
_ = try await client.request(.post, "/open-apis/sheets/v2/spreadsheets/\(token)/values_batch_update", json: batch, as: JSONValue.self)

// Add a sheet (tab)
let add: JSONValue = ["requests": [["addSheet": ["properties": ["title": "Data", "index": 0]]]]]
let added = try await client.request(.post, "/open-apis/sheets/v2/spreadsheets/\(token)/sheets_batch_update", json: add, as: JSONValue.self)
print(added.data?["replies"]?[0]?["addSheet"]?["properties"]?["sheetId"]?.stringValue ?? "")
```

- Cells are plain JSON: string, number, bool, or objects such as
  `["type": "url", "text": ..., "link": ...]` and `["type": "formula", "text": "=SUM(A1:A3)"]`.
- `valueRenderOption`: `ToString`, `FormattedValue`, `Formula`, `UnformattedValue`;
  `dateTimeRenderOption: FormattedString` returns dates as text instead of serial numbers.
- `insertDataOption`: `OVERWRITE` (default) or `INSERT_ROWS`. `values_prepend` is the same
  shape and inserts above the range.
- `JSONValue` literals do not support string interpolation: wrap with `.string("...")`.
- Decode into your own `Codable` struct instead of `JSONValue` if you prefer:
  `client.request(.get, path, as: MyValues.self)`.

## Gotchas

- Each tab is addressed by `sheetId`; titles can change and are not accepted in ranges.
- Missing an API? grep `Sources/LarkSheets/SheetsService.swift` for the path first; if it is
  not there (every `/open-apis/sheets/v2/...` endpoint: values, styles, merges, dimensions,
  protected ranges, `sheets_batch_update`, `metainfo`), use `client.request`.
