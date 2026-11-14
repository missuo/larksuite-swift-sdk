---
name: lark-swift-docx
description: Create, read and edit Feishu/Lark docx documents (new-version cloud docs) in Swift with larksuite-swift-sdk. Use when writing Swift code that creates a document, reads its plain text or blocks, inserts text/headings/lists/nested blocks, converts Markdown/HTML into blocks, updates or deletes blocks, or puts images into a docx document.
---

# Docx with larksuite-swift-sdk

Product `LarkDocx` (plus `LarkCore`). It is a port of node-sdk's `client.docx.v1.*`. Read
the `lark-swift-sdk` skill first for client setup, errors and the Node→Swift mapping.

```swift
import LarkCore
import LarkDocx

let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx", domain: .feishu)
```

Only `v1` exists: `client.docx.v1.<resource>` (the same resources are also available as aliases
without the version, e.g. `client.docx.document`). Models are in the `Docx` namespace.

| Resource | Methods |
|---|---|
| `document` | `create`, `get`, `rawContent`, `convert` (Markdown/HTML → blocks) |
| `documentBlock` | `list` / `listWithIterator`, `get`, `patch`, `batchUpdate` |
| `documentBlockChildren` | `create`, `get` / `getWithIterator`, `batchDelete` |
| `documentBlockDescendant` | `create` (nested blocks in one call) |
| `chatAnnouncement`, `chatAnnouncementBlock*` | similar block operations on a group chat announcement (`chatId:` instead of `documentId:`) |

## Key concepts

- A document is a tree of blocks. The root is the **page block, whose `block_id` equals the
  `document_id`**: pass `blockId: documentId` to add top-level content.
- `blockType` is an `Int`. Common values: 1 page, 2 text, 3–11 heading1–heading9, 12 bullet,
  13 ordered, 14 code, 15 quote, 17 todo, 19 callout, 22 divider, 27 image, 31 table,
  32 table cell. The matching payload property (`text`, `heading1`, `bullet`, `image`, ...)
  must be set.
- Text lives in `elements: [TextElement]`; each element is usually a `textRun`
  (`content` + optional `textElementStyle`).
- A document id from a wiki node is the node's `objToken` (when `objType == "docx"`), not
  the wiki token; see the `lark-swift-wiki` skill.
- Access: the caller (the app with the tenant token, or a user with
  `options: .userAccessToken(...)`) needs read/edit permission on the document, otherwise
  the server returns 403/400. Documents the app created itself are fine; share others with
  the app or call as the user (collaborators: Drive `permissionMember`, see `lark-swift-drive`).

## Create, read metadata, read plain text

```swift
let created = try await client.docx.v1.document.create(body: .init(folderToken: folderToken, title: "Weekly report"))
let documentId = created.data?.document?.documentId ?? ""
// folderToken: nil creates it in the root of the caller's space

let info = try await client.docx.v1.document.get(documentId: documentId)
print(info.data?.document?.title ?? "", info.data?.document?.revisionId ?? 0)

let raw = try await client.docx.v1.document.rawContent(documentId: documentId)
print(raw.data?.content ?? "")          // the whole document as plain text
```

## List blocks (paged)

```swift
for try await page in client.docx.v1.documentBlock.listWithIterator(documentId: documentId, params: .init(pageSize: 500)) {
    for block in page.items ?? [] {
        let body = block.text ?? block.heading1 ?? block.bullet
        let text = body?.elements?.compactMap { $0.textRun?.content }.joined() ?? ""
        print(block.blockId ?? "", block.blockType ?? 0, block.parentId ?? "", text)
    }
}

// Children of one block (withDescendants: the whole subtree), or a single block:
for try await page in client.docx.v1.documentBlockChildren.getWithIterator(
    documentId: documentId, blockId: blockId, params: .init(pageSize: 500, withDescendants: true))
{
    print(page.items?.count ?? 0)
}
let one = try await client.docx.v1.documentBlock.get(documentId: documentId, blockId: blockId)
print(one.data?.block?.blockType ?? 0)
```

## Insert blocks

A small helper for text runs (link URLs must be URL-encoded):

```swift
func run(_ s: String, bold: Bool = false, link: String? = nil) -> Docx.TextElement {
    .init(textRun: .init(content: s, textElementStyle: .init(
        bold: bold, link: link.map { .init(url: $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) })))
}
```

```swift
let added = try await client.docx.v1.documentBlockChildren.create(
    documentId: documentId, blockId: documentId,          // root page block: append to the document
    params: .init(clientToken: UUID().uuidString),         // idempotency key
    body: .init(children: [
        .init(blockType: 3, heading1: .init(elements: [run("Summary")])),
        .init(blockType: 2, text: .init(elements: [run("Status: "), run("green", bold: true)])),
        .init(blockType: 12, bullet: .init(elements: [run("see "), run("the spec", link: "https://example.com/spec")])),
        .init(blockType: 22, divider: [:]),
    ]))                                                    // index: n inserts at a position; omitted = append
let newBlockIds = added.data?.children?.compactMap(\.blockId) ?? []
```

Nested structures (lists with sub-items, tables, callouts) in one call: give each block a
temporary `blockId`, reference children by those ids, and list the top-level ids in `childrenId`.

```swift
let nested = try await client.docx.v1.documentBlockDescendant.create(
    documentId: documentId, blockId: documentId,
    body: .init(childrenId: ["tmp_parent"], descendants: [
        .init(blockId: "tmp_parent", children: ["tmp_child"], blockType: 12, bullet: .init(elements: [run("parent")])),
        .init(blockId: "tmp_child", blockType: 12, bullet: .init(elements: [run("child")])),
    ]))
for r in nested.data?.blockIdRelations ?? [] { print(r.temporaryBlockId ?? "", "->", r.blockId ?? "") }
```

GridColumn, TableCell and Callout blocks need at least one child (use an empty text block).
At most 1000 blocks per `documentBlockDescendant.create` call.

## Markdown / HTML → blocks

`document.convert` only converts; insert the result with `documentBlockDescendant.create`.
The convert output (`Docx.Block`) and the insert input (`Docx.Descendant`) have the same wire
shape but are different Swift types, so re-decode. Table `merge_info` is read-only and must
be removed before inserting.

```swift
let converted = try await client.docx.v1.document.convert(
    body: .init(contentType: .markdown, content: "# Title\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |"))
let blocks = converted.data?.blocks ?? []
var descendants = try JSONDecoder().decode([Docx.Descendant].self, from: JSONEncoder().encode(blocks))
for i in descendants.indices { descendants[i].table?.property?.mergeInfo = nil }
_ = try await client.docx.v1.documentBlockDescendant.create(
    documentId: documentId, blockId: documentId,
    body: .init(childrenId: converted.data?.firstLevelBlockIds ?? [], descendants: descendants))
// Images in the source come back as empty image blocks; converted.data?.blockIdToImageUrls lists
// (blockId, imageUrl) pairs: download each image and upload it as shown below.
```

## Update and delete blocks

```swift
// One block: replace its text elements
_ = try await client.docx.v1.documentBlock.patch(
    documentId: documentId, blockId: blockId,
    body: .init(updateTextElements: .init(elements: [run("replaced text")])))

// Many blocks in one request (note: batchUpdate uses Docx.PageElement, not Docx.TextElement)
_ = try await client.docx.v1.documentBlock.batchUpdate(documentId: documentId, body: .init(requests: [
    .init(updateTextElements: .init(elements: [.init(textRun: .init(content: "first"))]), blockId: blockA),
    .init(updateTextElements: .init(elements: [.init(textRun: .init(content: "second"))]), blockId: blockB),
]))

// Delete children [startIndex, endIndex) of a parent block (here: the first two top-level blocks)
_ = try await client.docx.v1.documentBlockChildren.batchDelete(
    documentId: documentId, blockId: documentId, body: .init(startIndex: 0, endIndex: 2))
```

Other `patch` / `batchUpdate` operations: `updateTextStyle`, `updateText`, `replaceImage`,
`replaceFile`, `insertTableRow`, `insertTableColumn`, `deleteTableRows`, `deleteTableColumns`,
`mergeTableCells`, `unmergeTableCells`, `updateTableProperty`, `updateGridColumnWidthRatio`,
`updateTask`.

## Images in a document (three steps, needs `LarkDrive` too)

1. Create an empty image block (`blockType: 27`).
2. Upload the image with Drive `media.uploadAll`, `parentType: .docxImage`, `parentNode:` the
   image block id.
3. Point the block at the uploaded file with `replaceImage`.

```swift
let img = try await client.docx.v1.documentBlockChildren.create(
    documentId: documentId, blockId: documentId,
    body: .init(children: [.init(blockType: 27, image: .init())]))
let imageBlockId = img.data?.children?.first?.blockId ?? ""
```

```swift
import LarkDrive

let file = try LarkFile(path: "/tmp/chart.png")
let uploaded = try await client.drive.v1.media.uploadAll(body: .init(
    fileName: "chart.png", parentType: .docxImage, parentNode: imageBlockId,
    size: file.data.count,
    extra: #"{"drive_route_token":"\#(documentId)"}"#,     // routes the upload to the document's storage
    file: file))
let imageToken = uploaded.data?.fileToken ?? ""
```

```swift
_ = try await client.docx.v1.documentBlock.patch(
    documentId: documentId, blockId: imageBlockId,
    body: .init(replaceImage: .init(token: imageToken)))
```

Files work the same way with `blockType: 23`, `parentType: .docxFile` and `replaceFile`.

## Rate limits and retries

From the API docs: editing (create/descendant/patch/batchUpdate/batchDelete) is limited to 3
requests/s per app (HTTP 400, code `99991400`) and 3 concurrent edits/s per document (HTTP 429);
reads are 5/s per app. Serialize edits to one document and back off:

```swift
func withBackoff<T>(_ op: () async throws -> T) async throws -> T {
    var delay: UInt64 = 500_000_000
    for _ in 0..<5 {
        do { return try await op() }
        catch let LarkError.api(e) where e.code == 99991400 || e.httpStatus == 429 {}
        catch LarkError.http(let status, _, _) where status == 429 {}
        try await Task.sleep(nanoseconds: delay)
        delay *= 2
    }
    return try await op()
}
let patched = try await withBackoff {
    try await client.docx.v1.documentBlock.patch(documentId: documentId, blockId: blockId,
        body: .init(updateTextElements: .init(elements: [run("v2")])))
}
print(patched.data?.documentRevisionId ?? 0)
```

## Gotchas

- Calling as a user: `options: .userAccessToken(userToken)` on any method.
- Response block types differ per endpoint (`Docx.Block`, `Docx.ChatAnnouncementBlockChildren`),
  but the property names are the same (`blockId`, `blockType`, `text`, `heading1`, ...).
- `params: .init(documentRevisionId:)` targets a revision; omitted means the latest.
- Old-version documents (`doc`), sheets and bitables are not docx; they have their own modules.
- Endpoint not generated? `client.request(.get, "/open-apis/docx/v1/...", as: JSONValue.self)`
  (see `lark-swift-sdk`). Never call method names that are not in `Sources/LarkDocx/DocxService.swift`.
