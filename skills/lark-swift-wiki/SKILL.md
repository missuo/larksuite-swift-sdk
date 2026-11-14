---
name: lark-swift-wiki
description: Work with Feishu/Lark wiki (knowledge base) spaces and nodes in Swift with larksuite-swift-sdk. Use when writing Swift code that lists wiki spaces, resolves a wiki URL/token to the underlying document, walks or lists the node tree, creates/moves/copies/renames nodes, moves cloud docs into a wiki, manages space members, or searches the wiki.
---

# Wiki with larksuite-swift-sdk

Product `LarkWiki` (plus `LarkCore`). It is a port of node-sdk's `client.wiki.*`. Read the
`lark-swift-sdk` skill first for client setup, errors and the Node→Swift mapping.

```swift
import LarkCore
import LarkWiki

let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx", domain: .feishu)
```

Models are in the `Wiki` namespace. Versions and resources:

| Path | Methods |
|---|---|
| `client.wiki.v2.space` | `list` / `listWithIterator`, `get`, `create`, `getNode` |
| `client.wiki.v2.spaceNode` | `list` / `listWithIterator`, `create`, `move`, `copy`, `updateTitle`, `moveDocsToWiki` |
| `client.wiki.v2.spaceMember` | `list`, `create`, `delete` |
| `client.wiki.v2.spaceSetting` | `update` |
| `client.wiki.v2.task` | `get` (results of async moves) |
| `client.wiki.v1.node` | `search` / `searchWithIterator` |

The v2 resources also have aliases without the version (`client.wiki.space`, ...).

## Key concepts

- A **node** (`Wiki.SpaceNode`) is a position in a space's tree. It wraps a document:
  `objType` (`docx`, `sheet`, `bitable`, `mindnote`, `file`, `slides`, `doc`) and `objToken`
  (the document's own token, e.g. the docx `document_id`). The **node token** (`nodeToken`,
  the token in a `/wiki/<token>` URL) is not the document token.
- To read or edit the content, resolve the node and use `objToken` with the matching module
  (`LarkDocx`, `LarkSheets`, `LarkBitable`, ...).
- With the tenant token, the app only sees spaces it is a member of; otherwise lists come back
  empty. Make the app a member (add a group that contains the bot as a space member, or ask a
  space admin), or call as a user with `options: .userAccessToken(userToken)`.
- Paged lists can return an empty page with `hasMore == true` (permission filtering); the
  iterators keep going, so always use them instead of stopping at the first empty page.

## Spaces

```swift
for try await page in client.wiki.v2.space.listWithIterator(params: .init(pageSize: 50)) {
    for s in page.items ?? [] { print(s.spaceId ?? "", s.name ?? "", s.spaceType?.rawValue ?? "") }
}
let space = try await client.wiki.v2.space.get(spaceId: spaceId)
print(space.data?.space?.name ?? "", space.data?.space?.visibility?.rawValue ?? "")

// Creating a space is not supported with the tenant token: call it as a user.
let newSpace = try await client.wiki.v2.space.create(
    body: .init(name: "Team handbook", description: "Created from Swift"),
    options: .userAccessToken(userToken))
print(newSpace.data?.space?.spaceId ?? "")
```

`space.list` never returns the personal "My Library" space.

## Resolve a wiki token (or a document) to a node

```swift
// https://xxx.feishu.cn/wiki/<wikiToken>
let resolved = try await client.wiki.v2.space.getNode(params: .init(token: wikiToken))
if let node = resolved.data?.node, node.objType == .docx {
    let documentId = node.objToken ?? ""          // use with client.docx.v1...
    print(node.spaceId ?? "", node.title ?? "", documentId)
}

// Reverse lookup: which node holds this cloud document? Pass the document token and its type.
let holder = try await client.wiki.v2.space.getNode(params: .init(token: documentId, objType: .docx))
print(holder.data?.node?.nodeToken ?? "")
```

## List and walk the node tree

```swift
// parentNodeToken: nil = top level of the space
for try await page in client.wiki.v2.spaceNode.listWithIterator(
    spaceId: spaceId, params: .init(pageSize: 50, parentNodeToken: parentToken))
{
    for n in page.items ?? [] { print(n.nodeToken ?? "", n.objType?.rawValue ?? "", n.title ?? "", n.hasChild ?? false) }
}
```

```swift
func walk(_ spaceId: String, _ parent: String?, depth: Int = 0) async throws {
    for try await page in client.wiki.v2.spaceNode.listWithIterator(
        spaceId: spaceId, params: .init(pageSize: 50, parentNodeToken: parent))
    {
        for n in page.items ?? [] {
            print(String(repeating: "  ", count: depth) + (n.title ?? ""), n.objType?.rawValue ?? "")
            if n.hasChild == true { try await walk(spaceId, n.nodeToken, depth: depth + 1) }
        }
    }
}
try await walk(spaceId, nil)
```

## Create, rename, move, copy nodes

```swift
let created = try await client.wiki.v2.spaceNode.create(spaceId: spaceId, body: .init(
    objType: .docx, parentNodeToken: parentToken, nodeType: .origin, title: "Design notes"))
let node = created.data?.node
print(node?.nodeToken ?? "", node?.objToken ?? "")   // objToken = the new docx document_id

// A shortcut to an existing node:
_ = try await client.wiki.v2.spaceNode.create(spaceId: spaceId, body: .init(
    objType: .docx, parentNodeToken: parentToken, nodeType: .shortcut, originNodeToken: originNodeToken))

_ = try await client.wiki.v2.spaceNode.updateTitle(spaceId: spaceId, nodeToken: nodeToken, body: .init(title: "New title"))
// Moves the node with its children; targetSpaceId moves across spaces
_ = try await client.wiki.v2.spaceNode.move(spaceId: spaceId, nodeToken: nodeToken, body: .init(targetParentToken: newParentToken))
let copy = try await client.wiki.v2.spaceNode.copy(
    spaceId: spaceId, nodeToken: nodeToken, body: .init(targetSpaceId: otherSpaceId, title: "Design notes (copy)"))
print(copy.data?.node?.nodeToken ?? "")
```

`updateTitle` supports doc, docx and shortcut nodes only. Moving needs edit permission on the
node and on both the source and target parent.

## Move a cloud-space document into a wiki

Asynchronous: the response has either the final `wikiToken` or a `taskId` to poll with
`task.get`.

```swift
let moved = try await client.wiki.v2.spaceNode.moveDocsToWiki(spaceId: spaceId, body: .init(
    parentWikiToken: parentToken, objType: .docx, objToken: documentId, apply: true))
if let token = moved.data?.wikiToken {
    print("in wiki:", token)
} else if let taskId = moved.data?.taskId {
    let task = try await client.wiki.v2.task.get(taskId: taskId, params: .init(taskType: .move))
    for r in task.data?.task?.moveResult ?? [] { print(r.node?.nodeToken ?? "", r.status ?? -1, r.statusMsg ?? "") }
} else if moved.data?.applied == true {
    print("no permission to move; a move request was sent to the document owner")
}
```

The caller needs manage permission on the document, edit permission on its folder and on the
target parent node. Only the task creator can query the task.

## Members and settings

```swift
// memberType: "openid" / "userid" / "unionid" / "openchat" / "opendepartmentid" / "email"; memberRole: "admin" / "member"
_ = try await client.wiki.v2.spaceMember.create(
    spaceId: spaceId, params: .init(needNotification: false),
    body: .init(memberType: "openchat", memberId: chatId, memberRole: "member"))
let members = try await client.wiki.v2.spaceMember.list(spaceId: spaceId, params: .init(pageSize: 50))
for m in members.data?.members ?? [] { print(m.memberType ?? "", m.memberId ?? "", m.memberRole ?? "") }
_ = try await client.wiki.v2.spaceMember.delete(
    spaceId: spaceId, memberId: chatId, body: .init(memberType: "openchat", memberRole: "member"))
```

`spaceMember.list` has no iterator in node-sdk: loop on `pageToken` / `hasMore` yourself.
Space settings: `client.wiki.v2.spaceSetting.update(spaceId:body:)` (`createSetting`,
`securitySetting`, `commentSetting`).

## Search

```swift
for try await page in client.wiki.v1.node.searchWithIterator(
    body: .init(query: "roadmap", spaceId: spaceId), options: .userAccessToken(userToken))
{
    for n in page.items ?? [] { print(n.title ?? "", n.objType ?? 0, n.objToken ?? "", n.url ?? "") }
}
```

Search runs as a user and only returns nodes that user can see. In this response `objType` is
an `Int`, unlike the string enum on `Wiki.SpaceNode`.

## Not in node-sdk

node-sdk 1.76.0 has no wiki methods for deleting a node or moving a node back to the cloud
space (`Wiki.TaskType.moveWikiToDocs` exists only for `task.get`). If the official docs list an
endpoint you need, call it with `client.request(...)` (see `lark-swift-sdk`); never invent
generated method names. Everything generated is in `Sources/LarkWiki/WikiService.swift`.
