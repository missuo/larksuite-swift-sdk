import Foundation
import LarkCore
import LarkDocx
import Testing

/// Compile-checks the code shown in skills/lark-swift-docx/SKILL.md (never executed).
/// The Drive upload step of the image recipe lives in Tests/LarkDriveTests/DriveSkillSnippetTests.swift
/// because this target cannot import LarkDrive.
@Suite struct DocxSkillSnippetTests {
    func client() throws {
        let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx", domain: .feishu)
        _ = client
    }

    func createAndRead(client: LarkClient, folderToken: String?) async throws {
        let created = try await client.docx.v1.document.create(body: .init(folderToken: folderToken, title: "Weekly report"))
        let documentId = created.data?.document?.documentId ?? ""
        // folderToken: nil creates it in the root of the caller's space

        let info = try await client.docx.v1.document.get(documentId: documentId)
        print(info.data?.document?.title ?? "", info.data?.document?.revisionId ?? 0)

        let raw = try await client.docx.v1.document.rawContent(documentId: documentId)
        print(raw.data?.content ?? "")          // the whole document as plain text
    }

    func listBlocks(client: LarkClient, documentId: String, blockId: String) async throws {
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
    }

    func run(_ s: String, bold: Bool = false, link: String? = nil) -> Docx.TextElement {
        .init(textRun: .init(content: s, textElementStyle: .init(
            bold: bold, link: link.map { .init(url: $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) })))
    }

    func insertBlocks(client: LarkClient, documentId: String) async throws {
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
        _ = newBlockIds
    }

    func insertNested(client: LarkClient, documentId: String) async throws {
        let nested = try await client.docx.v1.documentBlockDescendant.create(
            documentId: documentId, blockId: documentId,
            body: .init(childrenId: ["tmp_parent"], descendants: [
                .init(blockId: "tmp_parent", children: ["tmp_child"], blockType: 12, bullet: .init(elements: [run("parent")])),
                .init(blockId: "tmp_child", blockType: 12, bullet: .init(elements: [run("child")])),
            ]))
        for r in nested.data?.blockIdRelations ?? [] { print(r.temporaryBlockId ?? "", "->", r.blockId ?? "") }
    }

    func convertMarkdown(client: LarkClient, documentId: String) async throws {
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
    }

    func updateAndDelete(client: LarkClient, documentId: String, blockId: String, blockA: String, blockB: String) async throws {
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
    }

    func imageBlock(client: LarkClient, documentId: String) async throws {
        let img = try await client.docx.v1.documentBlockChildren.create(
            documentId: documentId, blockId: documentId,
            body: .init(children: [.init(blockType: 27, image: .init())]))
        let imageBlockId = img.data?.children?.first?.blockId ?? ""
        _ = imageBlockId
    }

    func replaceImage(client: LarkClient, documentId: String, imageBlockId: String, imageToken: String) async throws {
        _ = try await client.docx.v1.documentBlock.patch(
            documentId: documentId, blockId: imageBlockId,
            body: .init(replaceImage: .init(token: imageToken)))
    }

    func backoff(client: LarkClient, documentId: String, blockId: String) async throws {
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
    }

    @Test func compiles() {}
}
