import Foundation
import LarkCore
import LarkDrive
import Testing

/// Compile-checks the LarkDrive upload snippet shown in skills/lark-swift-bitable/SKILL.md (never executed).
@Suite struct BitableAttachmentSnippetTests {
    func upload(client: LarkClient, appToken: String) async throws {
        let file = try LarkFile(path: "/tmp/report.pdf")
        let up = try await client.drive.v1.media.uploadAll(body: .init(
            fileName: file.fileName, parentType: .bitableFile, parentNode: appToken, size: file.data.count, file: file))
        let fileToken = up.data?.fileToken ?? ""
        _ = fileToken
        _ = try await client.drive.v1.media.download(fileToken: fileToken)
    }

    @Test func compiles() {}
}
