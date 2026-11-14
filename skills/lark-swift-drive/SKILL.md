---
name: lark-swift-drive
description: Work with Feishu/Lark Drive (cloud space) in Swift with larksuite-swift-sdk. Use when writing Swift code that lists folders, creates folders, uploads files (single request or multipart), downloads files or document media, exports docs/sheets to PDF/Word/Excel/CSV, imports files as cloud documents, manages collaborators/permissions, batch-queries file metadata, moves/copies/deletes files, reads or adds comments, or subscribes to file events.
---

# Drive with larksuite-swift-sdk

Product `LarkDrive` (plus `LarkCore`). It is a port of node-sdk's `client.drive.*`. Read the
`lark-swift-sdk` skill first for client setup, errors and the Node→Swift mapping.

```swift
import LarkCore
import LarkDrive

let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx", domain: .feishu)
```

Models are in the `Drive` namespace. Main resources (`client.drive.v1.<resource>`, also aliased
as `client.drive.<resource>`):

| Resource | Methods |
|---|---|
| `file` | `list`/`listWithIterator`, `createFolder`, `uploadAll`, `uploadPrepare`/`uploadPart`/`uploadFinish`, `download`, `move`, `copy`, `delete`, `taskCheck`, `createShortcut`, `subscribe`/`getSubscribe`/`deleteSubscribe` |
| `media` | `uploadAll`, `uploadPrepare`/`uploadPart`/`uploadFinish`, `download`, `batchGetTmpDownloadUrl` |
| `meta` | `batchQuery` |
| `exportTask` / `importTask` | `create`, `get` (+ `exportTask.download`) |
| `permissionMember` | `create`, `batchCreate`, `list`, `update`, `delete`, `transferOwner`, `auth` |
| `permissionPublic` (`v1`, `v2`), `permissionPublicPassword` | link sharing settings |
| `fileComment`, `fileCommentReply` | comments and replies |
| `fileVersion`, `fileStatistics`, `fileViewRecord`, `fileSubscription` | versions, stats, viewers, subscriptions |

`client.drive.v2` has `fileLike.list`, `commentReaction.updateReaction` and `permissionPublic`.

## Key concepts

- Everything is addressed by **token**: folder token, file token, or a document token
  (docx `document_id`, sheet token, ...). Many calls also need the **type** of that token
  (`"docx"`, `"sheet"`, `"file"`, `"folder"`, ...), each method with its own open enum; string
  literals work too (`type: "docx"`).
- **Files** (`file.*`) live in the cloud space folder tree. **Media** (`media.*`) are images
  and attachments that belong to a document (docx images, sheet images, ...) and do not show up
  in the folder tree.
- The app with the tenant token works in its own space and in folders/documents shared with it.
  To act in a user's space, call as the user: `options: .userAccessToken(userToken)`.

## List a folder, create a folder

```swift
// folderToken: nil lists the root of the caller's space
for try await page in client.drive.v1.file.listWithIterator(
    params: .init(pageSize: 50, folderToken: folderToken, orderBy: .editedTime, direction: "DESC"))
{
    for f in page.files ?? [] { print(f.type ?? "", f.name ?? "", f.token ?? "", f.url ?? "") }
}

let folder = try await client.drive.v1.file.createFolder(body: .init(name: "Reports", folderToken: parentFolderToken))
let newFolderToken = folder.data?.token ?? ""
```

Only one level is listed; recurse into entries with `type == "folder"` yourself.
The root folder's token is not exposed by node-sdk; use a raw request:

```swift
let root = try await client.request(.get, "/open-apis/drive/explorer/v2/root_folder/meta", as: JSONValue.self)
let rootFolderToken = root.data?["token"]?.stringValue ?? ""
```

## Upload a file

Single request (`upload_all`, files up to 20 MB). `size` must be the exact byte count.

```swift
let file = try LarkFile(path: "/tmp/report.pdf")
let uploaded = try await client.drive.v1.file.uploadAll(body: .init(
    fileName: "report.pdf", parentType: .explorer, parentNode: folderToken,
    size: file.data.count, file: file))
let fileToken = uploaded.data?.fileToken ?? ""
```

Large files: prepare → upload every block (`seq` from 0, the server fixes the block size,
currently 4 MB) → finish.

```swift
let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/big.zip"))
let prep = try await client.drive.v1.file.uploadPrepare(body: .init(
    fileName: "big.zip", parentType: .explorer, parentNode: folderToken, size: data.count))
guard let uploadId = prep.data?.uploadId, let blockSize = prep.data?.blockSize, let blockNum = prep.data?.blockNum else { return }
for seq in 0..<blockNum {
    let chunk = data.subdata(in: (seq * blockSize)..<min((seq + 1) * blockSize, data.count))
    _ = try await client.drive.v1.file.uploadPart(body: .init(
        uploadId: uploadId, seq: seq, size: chunk.count, file: LarkFile(data: chunk, fileName: "big.zip")))
}
let finished = try await client.drive.v1.file.uploadFinish(body: .init(uploadId: uploadId, blockNum: blockNum))
print(finished.data?.fileToken ?? "")
```

Media use the same pattern (`media.uploadAll` / `media.uploadPrepare` + `uploadPart` +
`uploadFinish`) with `parentType` such as `.docxImage`, `.docxFile`, `.sheetImage`,
`.bitableFile`, and `parentNode` = the owning block/document. Uploading an image into a docx
document (the image block id is the parent; see `lark-swift-docx` for the surrounding steps):

```swift
let image = try LarkFile(path: "/tmp/chart.png")
let media = try await client.drive.v1.media.uploadAll(body: .init(
    fileName: "chart.png", parentType: .docxImage, parentNode: imageBlockId,
    size: image.data.count,
    extra: #"{"drive_route_token":"\#(documentId)"}"#,     // routes the upload to the document's storage
    file: image))
let imageToken = media.data?.fileToken ?? ""
```

## Download

`file.download` downloads binary files (PDF, zip, ...), not online documents (export those).
Downloads return `LarkBinaryResponse` (`data`, `fileName`, `contentType`, `writeFile(_:)`).

```swift
let dl = try await client.drive.v1.file.download(fileToken: fileToken)
try dl.writeFile("/tmp/\(dl.fileName ?? "download.bin")")

// Partial download with a Range header
let head = try await client.drive.v1.file.download(
    fileToken: fileToken, options: RequestOptions(headers: ["Range": "bytes=0-1023"]))
print(head.data.count)

// Document media (e.g. a docx image token)
let img = try await client.drive.v1.media.download(fileToken: imageToken)
try img.writeFile("/tmp/image.png")
let links = try await client.drive.v1.media.batchGetTmpDownloadUrl(params: .init(fileTokens: [imageToken]))
for l in links.data?.tmpDownloadUrls ?? [] { print(l.fileToken ?? "", l.tmpDownloadUrl ?? "") }   // valid for 24 h
```

## Export a document (docx/sheet/bitable → pdf/docx/xlsx/csv)

Asynchronous: create the task, poll with the same identity, then download the result.

```swift
let created = try await client.drive.v1.exportTask.create(body: .init(fileExtension: .pdf, token: documentId, type: .docx))
guard let ticket = created.data?.ticket else { return }
var result: Drive.ExportTaskGetResponseResult?
for _ in 0..<60 {
    let r = try await client.drive.v1.exportTask.get(ticket: ticket, params: .init(token: documentId))
    if let res = r.data?.result, let status = res.jobStatus, status != 1, status != 2 { result = res; break }  // 1/2 = still running
    try await Task.sleep(nanoseconds: 1_000_000_000)
}
guard let done = result, done.jobStatus == 0, let exportToken = done.fileToken else {
    print("export failed:", result?.jobErrorMsg ?? "timeout"); return
}
let exported = try await client.drive.v1.exportTask.download(fileToken: exportToken)
try exported.writeFile("/tmp/\(done.fileName ?? "export").pdf")
```

CSV export of a sheet or bitable needs `subId` (the sheet/table id) in the create body.

## Import a file as a cloud document

Upload the source first (here with `file.uploadAll` into a folder; the official import guide
also allows `media.uploadAll` with `parentType: .ccmImportOpen`), then create an import task
and poll `importTask.get` until `result.jobStatus == 0` (`result.token` / `result.url` is the
new document).

```swift
let src = try LarkFile(path: "/tmp/notes.md")
let source = try await client.drive.v1.file.uploadAll(body: .init(
    fileName: "notes.md", parentType: .explorer, parentNode: folderToken, size: src.data.count, file: src))
let imported = try await client.drive.v1.importTask.create(body: .init(
    fileExtension: "md", fileToken: source.data?.fileToken ?? "", type: "docx", fileName: "notes",
    point: .init(mountType: 1, mountKey: folderToken)))                   // mountType 1 = cloud-space folder
let state = try await client.drive.v1.importTask.get(ticket: imported.data?.ticket ?? "")
print(state.data?.result?.jobStatus ?? -1, state.data?.result?.url ?? "")
```

## Collaborators and permissions

```swift
// Grant a user edit access to a docx (perm: .view / .edit / .fullAccess)
_ = try await client.drive.v1.permissionMember.create(
    token: documentId, params: .init(type: .docx, needNotification: false),
    body: .init(memberType: .openid, memberId: openId, perm: .edit, type: .user))
_ = try await client.drive.v1.permissionMember.batchCreate(
    token: documentId, params: .init(type: .docx),
    body: .init(members: [.init(memberType: .openchat, memberId: chatId, perm: .view, type: .chat)]))

let members = try await client.drive.v1.permissionMember.list(token: documentId, params: .init(type: .docx))
for m in members.data?.items ?? [] { print(m.memberType?.rawValue ?? "", m.memberId ?? "", m.perm?.rawValue ?? "", m.name ?? "") }

let check = try await client.drive.v1.permissionMember.auth(
    token: documentId, params: .init(type: .docx, action: .edit), options: .userAccessToken(userToken))
print(check.data?.authResult ?? false)

_ = try await client.drive.v1.permissionMember.transferOwner(
    token: documentId, params: .init(type: .docx), body: .init(memberType: .openid, memberId: openId))
```

The caller needs permission to add collaborators, and must be able to see the member (for a
group with the tenant token, the bot must be in the group). Apps cannot be added to a folder
as a collaborator directly: add the bot to a group and grant that group access instead.

## Metadata, move, copy, delete

```swift
let metas = try await client.drive.v1.meta.batchQuery(body: .init(requestDocs: [
    .init(docToken: documentId, docType: .docx), .init(docToken: sheetToken, docType: .sheet),
], withUrl: true))
for m in metas.data?.metas ?? [] { print(m.docType ?? "", m.title ?? "", m.ownerId ?? "", m.latestModifyTime ?? "", m.url ?? "") }
for f in metas.data?.failedList ?? [] { print("failed:", f.token ?? "", f.code ?? 0) }

_ = try await client.drive.v1.file.move(fileToken: fileToken, body: .init(type: .file, folderToken: targetFolderToken))
let copied = try await client.drive.v1.file.copy(
    fileToken: documentId, body: .init(name: "Report (copy)", type: .docx, folderToken: targetFolderToken))
print(copied.data?.file?.token ?? "")

// Deleting (or moving) a folder is asynchronous: poll taskCheck with the returned task id
let deleted = try await client.drive.v1.file.delete(fileToken: oldFolderToken, params: .init(type: .folder))
if let taskId = deleted.data?.taskId {
    print(try await client.drive.v1.file.taskCheck(params: .init(taskId: taskId)).data?.status ?? "")
}
```

Deleted files go to the trash.

## Comments

```swift
for try await page in client.drive.v1.fileComment.listWithIterator(
    fileToken: documentId, params: .init(fileType: .docx, isSolved: false, pageSize: 50))
{
    for c in page.items ?? [] {
        let text = c.replyList?.replies?.first?.content?.elements?.compactMap { $0.textRun?.text }.joined() ?? ""
        print(c.commentId ?? "", c.quote ?? "", text)
    }
}
// A whole-document comment
_ = try await client.drive.v1.fileComment.create(
    fileToken: documentId, params: .init(fileType: .docx),
    body: .init(replyList: .init(replies: [.init(content: .init(elements: [.init(type: .textRun, textRun: .init(text: "Looks good"))]))])))
```

## File events

Subscribe to a file, then handle the events with the `EventDispatcher` (see `lark-swift-sdk`).

```swift
_ = try await client.drive.v1.file.subscribe(fileToken: documentId, params: .init(fileType: .docx))
let dispatcher = EventDispatcher()
    .register(.driveFileEditV1) { e, _ in
        print("edited:", e.fileType ?? "", e.fileToken ?? "", e.operatorIdList?.first?.openId ?? "")
        return nil
    }
    .register(.driveFileTitleUpdatedV1) { e, _ in print("renamed:", e.fileToken ?? ""); return nil }
```

## Gotchas

- Open enums take literals or static members: `direction: "ASC"` and `direction: .asc` are the same.
- `permissionMember.list` is not paginated: one call returns every collaborator.
- Endpoint missing (e.g. the root folder meta above)? `client.request(...)` (see
  `lark-swift-sdk`). Never call method names that are not in `Sources/LarkDrive/DriveService.swift`.
