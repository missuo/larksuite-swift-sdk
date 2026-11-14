import Foundation
import LarkApproval
import LarkCore
import Testing

/// Compile-checks the code shown in skills/lark-swift-approval/SKILL.md (never executed).
/// The Package.swift dependency lines and the imports are covered by this target's manifest and imports.
@Suite struct ApprovalSkillSnippetTests {
    func definition(client: LarkClient, approvalCode: String) async throws {
        let def = try await client.approval.v4.approval.get(
            approvalCode: approvalCode, params: .init(locale: .zhCN, userIdType: .openId))
        if let d = def.data {
            print(d.approvalName ?? "", d.status?.rawValue ?? "")
            // `form` is a JSON *string*: [{"id": "widget...", "name": "...", "type": "input", ...}]
            let widgets = try JSONValue(jsonString: d.form ?? "[]")
            for w in widgets.arrayValue ?? [] {
                print(w["id"]?.stringValue ?? "", w["type"]?.stringValue ?? "", w["name"]?.stringValue ?? "")
            }
            for n in d.nodeList ?? [] { print(n.nodeId ?? "", n.customNodeId ?? "", n.name ?? "", n.needApprover ?? false) }
        }
    }

    func createInstance(
        client: LarkClient, approvalCode: String, applicantOpenId: String, approverOpenId: String, requestId: String
    ) async throws {
        let form: JSONValue = [
            ["id": "widget_reason", "type": "input", "value": "Team offsite"],
            ["id": "widget_detail", "type": "textarea", "value": "Venue + travel"],
            ["id": "widget_date", "type": "date", "value": "2026-11-20T09:00:00+08:00"],
        ]
        let created = try await client.approval.v4.instance.create(body: .init(
            approvalCode: approvalCode,
            openId: applicantOpenId,               // applicant: userId: or openId: (one is required)
            form: form.jsonString(),               // JSON string, not an object
            nodeApproverOpenIdList: [.init(key: "node_id_or_custom_node_id", value: [approverOpenId])],
            uuid: requestId))                      // idempotency key: same uuid -> same instance
        print(created.data?.instanceCode ?? "", created.data?.instanceLink ?? "")
    }

    func readInstances(client: LarkClient, instanceCode: String, approvalCode: String, applicantOpenId: String) async throws {
        // One instance (the `instanceId` path argument is the instance_code)
        let inst = try await client.approval.v4.instance.get(
            instanceId: instanceCode, params: .init(locale: .enUS, userIdType: .openId))
        if let i = inst.data {
            print(i.approvalName ?? "", i.status?.rawValue ?? "", i.serialNumber ?? "", i.openId ?? "")
            for t in i.taskList ?? [] where t.status == .pending {
                print("pending task", t.id ?? "", t.openId ?? t.userId ?? "", t.nodeName ?? "")
            }
            for c in i.commentList ?? [] { print(c.openId ?? "", c.comment ?? "") }
            let values = try JSONValue(jsonString: i.form ?? "[]")   // submitted form, same widget shape
            print(values)
        }

        // All instance codes of a definition, created in a window (milliseconds since epoch, as strings)
        let now = Int(Date().timeIntervalSince1970 * 1000)
        for try await page in client.approval.v4.instance.listWithIterator(params: .init(
            pageSize: 100, approvalCode: approvalCode, startTime: String(now - 7 * 86_400_000), endTime: String(now)))
        {
            for code in page.instanceCodeList ?? [] { print(code) }
        }

        // Search instances by applicant / status / title
        for try await page in client.approval.v4.instance.queryWithIterator(
            params: .init(pageSize: 50, userIdType: .openId),
            body: .init(userId: applicantOpenId, approvalCode: approvalCode, instanceStatus: "PENDING"))
        {
            for item in page.instanceList ?? [] {
                print(item.instance?.code ?? "", item.instance?.title ?? "", item.instance?.status ?? "")
            }
        }
    }

    func userTasks(client: LarkClient, approverOpenId: String) async throws {
        for try await page in client.approval.v4.task.queryWithIterator(
            params: .init(pageSize: 50, userId: approverOpenId, topic: "1", userIdType: .openId))
        {
            for t in page.tasks ?? [] {
                // processCode = instance code, definitionCode = approval code
                print(t.taskId ?? "", t.title ?? "", t.processCode ?? "", t.definitionCode ?? "", t.status?.rawValue ?? "")
            }
        }
        // Cross-user search: client.approval.v4.task.search(params:body:) with TaskSearchBody filters.
    }

    func taskActions(
        client: LarkClient, approvalCode: String, instanceCode: String, approverOpenId: String, taskId: String,
        delegateOpenId: String, applicantOpenId: String
    ) async throws {
        let p = Approval.TaskApproveQuery(userIdType: .openId)
        _ = try await client.approval.v4.task.approve(params: p, body: .init(
            approvalCode: approvalCode, instanceCode: instanceCode, userId: approverOpenId,
            comment: "LGTM", taskId: taskId))
        _ = try await client.approval.v4.task.reject(params: p, body: .init(
            approvalCode: approvalCode, instanceCode: instanceCode, userId: approverOpenId,
            comment: "Missing receipt", taskId: taskId))
        _ = try await client.approval.v4.task.transfer(params: p, body: .init(
            approvalCode: approvalCode, instanceCode: instanceCode, userId: approverOpenId,
            comment: "On leave", transferUserId: delegateOpenId, taskId: taskId))
        _ = try await client.approval.v4.instance.cancel(params: .init(userIdType: .openId), body: .init(
            approvalCode: approvalCode, instanceCode: instanceCode, userId: applicantOpenId))
    }

    func comments(client: LarkClient, instanceCode: String, commenterOpenId: String) async throws {
        let text: JSONValue = ["text": "Please attach the invoice", "files": []]
        let comment = try await client.approval.v4.instanceComment.create(
            instanceId: instanceCode, params: .init(userIdType: .openId, userId: commenterOpenId),
            body: .init(content: text.jsonString()))
        print(comment.data?.commentId ?? "")
        let list = try await client.approval.v4.instanceComment.list(
            instanceId: instanceCode, params: .init(userIdType: .openId, userId: commenterOpenId, pageSize: 50))
        for c in list.data?.comments ?? [] { print(c.commentator ?? "", c.content ?? "", c.createTime ?? "") }
    }

    func events(client: LarkClient, approvalCode: String) async throws -> EventDispatcher {
        // Per definition (once per app; enables the approval events for that approval_code)
        _ = try await client.approval.v4.approval.subscribe(approvalCode: approvalCode)
        // Scope for the v4 status_changed events
        _ = try await client.approval.v4.instance.subscription(body: .init(subscriptionType: "INVOLVED_APPROVAL"))
        _ = try await client.approval.v4.task.subscription(body: .init(subscriptionType: "INVOLVED_APPROVAL"))

        let dispatcher = EventDispatcher()
            .register(.approvalInstanceStatusChangedV4) { e, _ in   // Approval.InstanceStatusChangedV4Event
                // status: PENDING, APPROVED, REJECTED, CANCELED, DELETED, REVERTED, OVERTIME_CLOSE, OVERTIME_RECOVER
                print(e.approvalCode ?? "", e.instanceCode ?? "", e.status ?? "", e.startUser?.openId ?? "")
                return nil
            }
            .register(.approvalTaskStatusChangedV4) { e, _ in       // Approval.TaskStatusChangedV4Event
                print(e.instanceCode ?? "", e.taskId ?? "", e.assignedUser?.openId ?? "", e.status ?? "")
                return nil
            }
            // Classic (v1) approval events are not typed in node-sdk: register them by name.
            .register("approval_instance") { event in
                print(event.payload["instance_code"]?.stringValue ?? "", event.payload["status"]?.stringValue ?? "")
                return nil
            }
        return dispatcher
    }

    func rawFallback(client: LarkClient, body: JSONValue) async throws {
        _ = try await client.request(.post, "/open-apis/approval/v4/...", json: body, as: JSONValue.self)
    }

    @Test func compiles() {}
}
