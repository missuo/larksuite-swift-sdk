import Foundation
import LarkCore
import LarkDrive
import Testing

/// Compile-checks the code shown in skills/lark-swift-drive/SKILL.md (never executed).
/// Also covers the Drive upload step of the image recipe in skills/lark-swift-docx/SKILL.md.
@Suite struct DriveSkillSnippetTests {
    func client() throws {
        let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx", domain: .feishu)
        _ = client
    }

    func listAndCreateFolder(client: LarkClient, folderToken: String?, parentFolderToken: String) async throws {
        // folderToken: nil lists the root of the caller's space
        for try await page in client.drive.v1.file.listWithIterator(
            params: .init(pageSize: 50, folderToken: folderToken, orderBy: .editedTime, direction: "DESC"))
        {
            for f in page.files ?? [] { print(f.type ?? "", f.name ?? "", f.token ?? "", f.url ?? "") }
        }

        let folder = try await client.drive.v1.file.createFolder(body: .init(name: "Reports", folderToken: parentFolderToken))
        let newFolderToken = folder.data?.token ?? ""
        _ = newFolderToken
    }

    func rootFolder(client: LarkClient) async throws {
        let root = try await client.request(.get, "/open-apis/drive/explorer/v2/root_folder/meta", as: JSONValue.self)
        let rootFolderToken = root.data?["token"]?.stringValue ?? ""
        _ = rootFolderToken
    }

    func uploadAll(client: LarkClient, folderToken: String) async throws {
        let file = try LarkFile(path: "/tmp/report.pdf")
        let uploaded = try await client.drive.v1.file.uploadAll(body: .init(
            fileName: "report.pdf", parentType: .explorer, parentNode: folderToken,
            size: file.data.count, file: file))
        let fileToken = uploaded.data?.fileToken ?? ""
        _ = fileToken
    }

    func multipart(client: LarkClient, folderToken: String) async throws {
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
    }

    /// Drive snippet of skills/lark-swift-drive/SKILL.md ("Upload a file", media).
    func mediaUpload(client: LarkClient, imageBlockId: String, documentId: String) async throws {
        let image = try LarkFile(path: "/tmp/chart.png")
        let media = try await client.drive.v1.media.uploadAll(body: .init(
            fileName: "chart.png", parentType: .docxImage, parentNode: imageBlockId,
            size: image.data.count,
            extra: #"{"drive_route_token":"\#(documentId)"}"#,     // routes the upload to the document's storage
            file: image))
        let imageToken = media.data?.fileToken ?? ""
        _ = imageToken
    }

    /// Drive step of the image recipe in skills/lark-swift-docx/SKILL.md.
    func docxImageUpload(client: LarkClient, imageBlockId: String, documentId: String) async throws {
        let file = try LarkFile(path: "/tmp/chart.png")
        let uploaded = try await client.drive.v1.media.uploadAll(body: .init(
            fileName: "chart.png", parentType: .docxImage, parentNode: imageBlockId,
            size: file.data.count,
            extra: #"{"drive_route_token":"\#(documentId)"}"#,     // routes the upload to the document's storage
            file: file))
        let imageToken = uploaded.data?.fileToken ?? ""
        _ = imageToken
    }

    func download(client: LarkClient, fileToken: String, imageToken: String) async throws {
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
    }

    func export(client: LarkClient, documentId: String) async throws {
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
    }

    func importFile(client: LarkClient, folderToken: String) async throws {
        let src = try LarkFile(path: "/tmp/notes.md")
        let source = try await client.drive.v1.file.uploadAll(body: .init(
            fileName: "notes.md", parentType: .explorer, parentNode: folderToken, size: src.data.count, file: src))
        let imported = try await client.drive.v1.importTask.create(body: .init(
            fileExtension: "md", fileToken: source.data?.fileToken ?? "", type: "docx", fileName: "notes",
            point: .init(mountType: 1, mountKey: folderToken)))                   // mountType 1 = cloud-space folder
        let state = try await client.drive.v1.importTask.get(ticket: imported.data?.ticket ?? "")
        print(state.data?.result?.jobStatus ?? -1, state.data?.result?.url ?? "")
    }

    func permissions(client: LarkClient, documentId: String, openId: String, chatId: String, userToken: String) async throws {
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
    }

    func metaMoveCopyDelete(
        client: LarkClient, documentId: String, sheetToken: String, fileToken: String, targetFolderToken: String,
        oldFolderToken: String
    ) async throws {
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
    }

    func comments(client: LarkClient, documentId: String) async throws {
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
    }

    func events(client: LarkClient, documentId: String) async throws {
        _ = try await client.drive.v1.file.subscribe(fileToken: documentId, params: .init(fileType: .docx))
        let dispatcher = EventDispatcher()
            .register(.driveFileEditV1) { e, _ in
                print("edited:", e.fileType ?? "", e.fileToken ?? "", e.operatorIdList?.first?.openId ?? "")
                return nil
            }
            .register(.driveFileTitleUpdatedV1) { e, _ in print("renamed:", e.fileToken ?? ""); return nil }
        _ = dispatcher
    }

    @Test func compiles() {}
}
