import Foundation
import LarkCore
import LarkSheets
import Testing

/// Compile-checks the code shown in skills/lark-swift-sheets/SKILL.md (never executed).
@Suite struct SheetsSkillSnippetTests {
    func clientSnippet() throws {
        let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx")
        _ = client
    }

    func spreadsheetsAndSheets(client: LarkClient, folderToken: String) async throws {
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
    }

    func findAndReplace(client: LarkClient, token: String, sheetId: String) async throws {
        let found = try await client.sheets.v3.spreadsheetSheet.find(spreadsheetToken: token, sheetId: sheetId,
            body: .init(findCondition: .init(range: "\(sheetId)!A1:Z1000", matchCase: false, matchEntireCell: false), find: "TODO"))
        print(found.data?.findResult?.matchedCells ?? [])          // e.g. ["B3", "C7"]

        let replaced = try await client.sheets.v3.spreadsheetSheet.replace(spreadsheetToken: token, sheetId: sheetId,
            body: .init(findCondition: .init(range: "\(sheetId)!A1:Z1000", searchByRegex: false), find: "TODO", replacement: "DONE"))
        print(replaced.data?.replaceResult?.rowsCount ?? 0)
    }

    func filters(client: LarkClient, token: String, sheetId: String) async throws {
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
    }

    /// Prose-only reference in the skill (float images).
    func floatImage(client: LarkClient, token: String, sheetId: String, imageToken: String) async throws {
        _ = try await client.sheets.v3.spreadsheetSheetFloatImage.create(spreadsheetToken: token, sheetId: sheetId,
            body: .init(floatImageToken: imageToken, range: "\(sheetId)!A1:A1", width: 100, height: 100))
    }

    func values(client: LarkClient, token: String, sheetId: String) async throws {
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
    }

    struct MyValues: Decodable, Sendable {}

    /// Prose-only reference in the skill (decoding into a custom type).
    func customDecoding(client: LarkClient, path: String) async throws {
        _ = try await client.request(.get, path, as: MyValues.self)
    }

    @Test func compiles() {}
}
