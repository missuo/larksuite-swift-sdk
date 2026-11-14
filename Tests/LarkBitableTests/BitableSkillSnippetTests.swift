import Foundation
import LarkBitable
import LarkCore
import Testing

/// Compile-checks the code shown in skills/lark-swift-bitable/SKILL.md (never executed).
/// The LarkDrive upload snippet is compile-checked in Tests/LarkDriveTests/BitableAttachmentSnippetTests.swift.
@Suite struct BitableSkillSnippetTests {
    func clientSnippet() throws {
        let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx")
        _ = client
    }

    func appsTablesFieldsViews(client: LarkClient, appToken: String, folderToken: String) async throws {
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

        _ = (newAppToken, defaultTableId)
    }

    func createUpdateDelete(client: LarkClient, appToken: String, tableId: String, title: String, openId: String) async throws {
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
    }

    func batch(client: LarkClient, appToken: String, tableId: String) async throws {
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
    }

    func search(client: LarkClient, appToken: String, tableId: String) async throws {
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
    }

    /// Prose-only references in the skill (nested filter, one-page search).
    func searchVariants(client: LarkClient, appToken: String, tableId: String) async throws {
        let nested = Bitable.Filter(conjunction: .or, children: [.init(conjunction: .and, conditions: [])])
        let page = try await client.bitable.v1.appTableRecord.search(
            appToken: appToken, tableId: tableId, params: .init(), body: .init(filter: nested))
        _ = page.data?.total
        _ = try await client.request(.post, "/open-apis/bitable/v1/x", json: ["a": 1] as JSONValue, as: JSONValue.self)
    }

    func attachToRecord(client: LarkClient, appToken: String, tableId: String, recordId: String, fileToken: String) async throws {
        _ = try await client.bitable.v1.appTableRecord.update(appToken: appToken, tableId: tableId, recordId: recordId,
            body: .init(fields: ["Files": [["file_token": .string(fileToken)]]]))
    }

    @Test func compiles() {}
}
