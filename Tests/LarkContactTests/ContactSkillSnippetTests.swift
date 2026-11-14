import Foundation
import LarkContact
import LarkCore
import Testing

/// Compile-checks the code shown in skills/lark-swift-contact/SKILL.md (never executed against a server).
/// The Package.swift dependency lines and the imports are covered by this target's manifest and imports.
@Suite struct ContactSkillSnippetTests {
    func getUser(client: LarkClient, openId: String, otherOpenId: String) async throws {
        let r = try await client.contact.v3.user.get(
            userId: openId, params: .init(userIdType: .openId, departmentIdType: .openDepartmentId))
        if let u = r.data?.user {
            print(u.name ?? "", u.enName ?? "", u.email ?? "", u.mobile ?? "", u.jobTitle ?? "")
            print(u.departmentIds ?? [], u.leaderUserId ?? "", u.avatar?.avatar240 ?? "")
            print("resigned:", u.status?.isResigned == true, "activated:", u.status?.isActivated == true)
        }

        // Up to 50 users per call
        let batch = try await client.contact.v3.user.batch(params: .init(userIds: [openId, otherOpenId], userIdType: .openId))
        for u in batch.data?.items ?? [] { print(u.openId ?? "", u.name) }
    }

    func batchGetId(client: LarkClient) async throws {
        let ids = try await client.contact.v3.user.batchGetId(
            params: .init(userIdType: .openId),
            body: .init(emails: ["alice@example.com"], mobiles: ["+8613800000000"], includeResigned: false))
        for item in ids.data?.userList ?? [] {
            print(item.email ?? item.mobile ?? "", "->", item.userId ?? "not found")   // userId holds the open_id here
        }
    }

    func usersInDepartment(client: LarkClient) async throws {
        // Direct members of a department ("0" = the root department)
        for try await page in client.contact.v3.user.findByDepartmentWithIterator(params: .init(
            userIdType: .openId, departmentIdType: .openDepartmentId, departmentId: "0", pageSize: 50))
        {
            for u in page.items ?? [] { print(u.openId ?? "", u.name, u.email ?? "") }
        }
    }

    func departments(client: LarkClient, openDepartmentId: String) async throws {
        // Children of a department; fetchChild: true returns every descendant, not just direct children
        for try await page in client.contact.v3.department.childrenWithIterator(
            departmentId: "0",
            params: .init(userIdType: .openId, departmentIdType: .openDepartmentId, fetchChild: true, pageSize: 50))
        {
            for d in page.items ?? [] {
                print(d.openDepartmentId ?? "", d.name, d.parentDepartmentId, d.memberCount ?? 0, d.leaderUserId ?? "")
            }
        }

        let dept = try await client.contact.v3.department.get(
            departmentId: openDepartmentId, params: .init(userIdType: .openId, departmentIdType: .openDepartmentId))
        print(dept.data?.department?.name ?? "", dept.data?.department?.chatId ?? "")

        // Ancestors (closest first)
        for try await page in client.contact.v3.department.parentWithIterator(params: .init(
            userIdType: .openId, departmentIdType: .openDepartmentId, departmentId: openDepartmentId))
        {
            for d in page.items ?? [] { print(d.name) }
        }
    }

    func scope(client: LarkClient) async throws {
        for try await page in client.contact.v3.scope.listWithIterator(
            params: .init(userIdType: .openId, departmentIdType: .openDepartmentId))
        {
            print(page.departmentIds ?? [], page.userIds ?? [], page.groupIds ?? [])
        }
    }

    func events() -> EventDispatcher {
        let dispatcher = EventDispatcher()
            .register(.contactUserCreatedV3) { e, raw in            // Contact.UserCreatedV3Event
                // node-sdk marks `name` and `mobile` required: without the mobile permission `e.object` is nil,
                // so fall back to the flattened payload.
                let openId = e.object?.openId ?? raw.payload["object"]?["open_id"]?.stringValue ?? ""
                print("joined:", openId)
                return nil
            }
            .register(.contactUserUpdatedV3) { e, raw in
                // `old_object` only carries the fields that changed, so read it untyped.
                let old = raw.payload["old_object"]
                if let oldDepartments = old?["department_ids"] {
                    let newDepartments = raw.payload["object"]?["department_ids"] ?? .null
                    print(e.object?.openId ?? "", "moved from", oldDepartments, "to", newDepartments)
                }
                return nil
            }
            .register(.contactUserDeletedV3) { e, raw in
                print("left:", raw.payload["object"]?["open_id"]?.stringValue ?? "")
                return nil
            }
            .register(.contactDepartmentCreatedV3) { e, _ in
                print(e.object?.openDepartmentId ?? "", e.object?.name ?? "")
                return nil
            }
        return dispatcher
    }

    func rawFallback(client: LarkClient, q: Contact.UserGetQuery) async throws {
        _ = try await client.request(.get, "/open-apis/contact/v3/...", query: q, as: JSONValue.self)
    }

    /// Pins the behaviour the skill's "strict required fields" gotcha describes.
    @Test func userEventWithoutMobileDecodesObjectAsNil() throws {
        let body: JSONValue = [
            "schema": "2.0",
            "header": ["event_type": "contact.user.updated_v3", "event_id": "ev_1"],
            "event": [
                "object": ["open_id": "ou_1", "name": "A", "department_ids": ["od_1"]],
                "old_object": ["department_ids": ["od_0"]],
            ],
        ]
        let raw = LarkEvent(body: body)
        let e = try raw.decode(Contact.UserUpdatedV3Event.self)
        #expect(e.object == nil)
        #expect(e.oldObject == nil)
        #expect(raw.payload["old_object"]?["department_ids"] == ["od_0"])
        let page = try (["has_more": false, "items": [["open_id": "ou_1", "name": "A"]]] as JSONValue)
            .decode(as: Contact.UserFindByDepartmentResponse.self)
        #expect((page.items ?? []).isEmpty)
    }

    @Test func compiles() {}
}
