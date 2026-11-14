import Foundation
import LarkCore
import LarkWiki
import Testing

/// Compile-checks the code shown in skills/lark-swift-wiki/SKILL.md (never executed).
@Suite struct WikiSkillSnippetTests {
    func client() throws {
        let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx", domain: .feishu)
        _ = client
    }

    func spaces(client: LarkClient, spaceId: String, userToken: String) async throws {
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
    }

    func resolve(client: LarkClient, wikiToken: String, documentId: String) async throws {
        // https://xxx.feishu.cn/wiki/<wikiToken>
        let resolved = try await client.wiki.v2.space.getNode(params: .init(token: wikiToken))
        if let node = resolved.data?.node, node.objType == .docx {
            let documentId = node.objToken ?? ""          // use with client.docx.v1...
            print(node.spaceId ?? "", node.title ?? "", documentId)
        }

        // Reverse lookup: which node holds this cloud document? Pass the document token and its type.
        let holder = try await client.wiki.v2.space.getNode(params: .init(token: documentId, objType: .docx))
        print(holder.data?.node?.nodeToken ?? "")
    }

    func listChildren(client: LarkClient, spaceId: String, parentToken: String?) async throws {
        // parentNodeToken: nil = top level of the space
        for try await page in client.wiki.v2.spaceNode.listWithIterator(
            spaceId: spaceId, params: .init(pageSize: 50, parentNodeToken: parentToken))
        {
            for n in page.items ?? [] { print(n.nodeToken ?? "", n.objType?.rawValue ?? "", n.title ?? "", n.hasChild ?? false) }
        }
    }

    func walkTree(client: LarkClient, spaceId: String) async throws {
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
    }

    func nodes(
        client: LarkClient, spaceId: String, parentToken: String?, originNodeToken: String, nodeToken: String,
        newParentToken: String, otherSpaceId: String
    ) async throws {
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
    }

    func moveDocs(client: LarkClient, spaceId: String, parentToken: String?, documentId: String) async throws {
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
    }

    func members(client: LarkClient, spaceId: String, chatId: String) async throws {
        // memberType: "openid" / "userid" / "unionid" / "openchat" / "opendepartmentid" / "email"; memberRole: "admin" / "member"
        _ = try await client.wiki.v2.spaceMember.create(
            spaceId: spaceId, params: .init(needNotification: false),
            body: .init(memberType: "openchat", memberId: chatId, memberRole: "member"))
        let members = try await client.wiki.v2.spaceMember.list(spaceId: spaceId, params: .init(pageSize: 50))
        for m in members.data?.members ?? [] { print(m.memberType ?? "", m.memberId ?? "", m.memberRole ?? "") }
        _ = try await client.wiki.v2.spaceMember.delete(
            spaceId: spaceId, memberId: chatId, body: .init(memberType: "openchat", memberRole: "member"))
        _ = try await client.wiki.v2.spaceSetting.update(spaceId: spaceId, body: .init(createSetting: "admin"))
    }

    func search(client: LarkClient, spaceId: String, userToken: String) async throws {
        for try await page in client.wiki.v1.node.searchWithIterator(
            body: .init(query: "roadmap", spaceId: spaceId), options: .userAccessToken(userToken))
        {
            for n in page.items ?? [] { print(n.title ?? "", n.objType ?? 0, n.objToken ?? "", n.url ?? "") }
        }
    }

    @Test func compiles() {}
}
