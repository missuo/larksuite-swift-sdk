import Foundation
import LarkCore
import LarkTask
import Testing

/// Compile-checks the code shown in skills/lark-swift-task/SKILL.md (never executed).
@Suite struct TaskSkillSnippetTests {
    func clientSnippet() throws {
        let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx")
        _ = client
    }

    func crud(client: LarkClient, assigneeOpenId: String, followerOpenId: String, tasklistGuid: String) async throws {
        let due = Int(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
        let created = try await client.task.v2.task.create(params: .init(userIdType: "open_id"), body: .init(
            summary: "Ship the release", description: "Checklist in the doc",
            due: .init(timestamp: String(due), isAllDay: false),
            members: [.init(id: assigneeOpenId, type: "user", role: "assignee"),
                      .init(id: followerOpenId, type: "user", role: "follower")],
            tasklists: [.init(tasklistGuid: tasklistGuid)],      // optional: add to a tasklist
            clientToken: UUID().uuidString,                      // idempotent retries
            reminders: [.init(relativeFireMinute: 30)]))         // 30 min before due (needs a due)
        let taskGuid = created.data?.task?.guid ?? ""
        print(created.data?.task?.url ?? "")

        let got = try await client.task.v2.task.get(taskGuid: taskGuid)
        let t = got.data?.task
        print(t?.summary ?? "", t?.status ?? "", t?.due?.timestamp ?? "", (t?.members ?? []).map { "\($0.role ?? ""):\($0.id ?? "")" })

        // Patch: name every changed field in updateFields (wire names); listed-but-unset fields are cleared
        _ = try await client.task.v2.task.patch(taskGuid: taskGuid, body: .init(
            task: .init(summary: "Ship v2", due: .init(timestamp: String(due), isAllDay: true)),
            updateFields: ["summary", "due"]))

        // Complete = set completed_at; reopen with "0"
        let now = String(Int(Date().timeIntervalSince1970 * 1000))
        _ = try await client.task.v2.task.patch(taskGuid: taskGuid, body: .init(task: .init(completedAt: now), updateFields: ["completed_at"]))
        _ = try await client.task.v2.task.patch(taskGuid: taskGuid, body: .init(task: .init(completedAt: "0"), updateFields: ["completed_at"]))

        _ = try await client.task.v2.task.delete(taskGuid: taskGuid)
    }

    func membersRemindersTasklists(client: LarkClient, taskGuid: String, tasklistGuid: String, openId: String) async throws {
        let member = TaskAPI.Member(id: openId, type: "user", role: "assignee")   // role: "assignee" | "follower"
        _ = try await client.task.v2.task.addMembers(taskGuid: taskGuid, body: .init(members: [member]))
        _ = try await client.task.v2.task.removeMembers(taskGuid: taskGuid, body: .init(members: [member]))
        _ = try await client.task.v2.task.addReminders(taskGuid: taskGuid, body: .init(reminders: [.init(relativeFireMinute: 60)]))
        _ = try await client.task.v2.task.addTasklist(taskGuid: taskGuid, body: .init(tasklistGuid: tasklistGuid))
        _ = try await client.task.v2.task.removeTasklist(taskGuid: taskGuid, body: .init(tasklistGuid: tasklistGuid))
    }

    func listMyTasks(client: LarkClient, userAccessToken: String) async throws {
        for try await page in client.task.v2.task.listWithIterator(
            params: .init(pageSize: 50, completed: false, type: "my_tasks", userIdType: "open_id"),
            options: .userAccessToken(userAccessToken))
        {
            for t in page.items ?? [] { print(t.guid ?? "", t.summary ?? "", t.due?.timestamp ?? "") }
        }
    }

    func tasklists(client: LarkClient, openId: String) async throws {
        let list = try await client.task.v2.tasklist.create(body: .init(
            name: "Release", members: [.init(id: openId, type: "user", role: "editor")]))   // "editor" | "viewer"
        let listGuid = list.data?.tasklist?.guid ?? ""

        for try await page in client.task.v2.tasklist.listWithIterator(params: .init(pageSize: 50)) {
            for l in page.items ?? [] { print(l.guid ?? "", l.name ?? "", l.url ?? "") }
        }

        // Tasks in a tasklist: node-sdk has no iterator for this one, page manually
        var pageToken: String? = nil
        repeat {
            let r = try await client.task.v2.tasklist.tasks(tasklistGuid: listGuid,
                params: .init(pageSize: 100, pageToken: pageToken, completed: false))
            for t in r.data?.items ?? [] { print(t.guid ?? "", t.summary ?? "", t.completedAt ?? "") }
            pageToken = r.data?.hasMore == true ? r.data?.pageToken : nil
        } while pageToken != nil

        _ = try await client.task.v2.tasklist.addMembers(tasklistGuid: listGuid,
            body: .init(members: [.init(id: openId, type: "user", role: "viewer")]))
    }

    /// Prose-only reference in the skill (sections).
    func sections(client: LarkClient, sectionGuid: String) async throws {
        for try await page in client.task.v2.section.tasksWithIterator(sectionGuid: sectionGuid) { _ = page.items }
    }

    func subtasks(client: LarkClient, taskGuid: String, openId: String) async throws {
        let sub = try await client.task.v2.taskSubtask.create(taskGuid: taskGuid, body: .init(
            summary: "Write changelog", members: [.init(id: openId, type: "user", role: "assignee")]))
        print(sub.data?.subtask?.guid ?? "")

        for try await page in client.task.v2.taskSubtask.listWithIterator(taskGuid: taskGuid) {
            for s in page.items ?? [] { print(s.guid ?? "", s.summary ?? "", s.completedAt ?? "") }
        }
    }

    func comments(client: LarkClient, taskGuid: String) async throws {
        let posted = try await client.task.v2.comment.create(body: .init(
            content: "Looks good", resourceType: "task", resourceId: taskGuid))
        let commentId = posted.data?.comment?.id ?? ""
        _ = try await client.task.v2.comment.create(body: .init(
            content: "Thanks", replyToCommentId: commentId, resourceType: "task", resourceId: taskGuid))

        for try await page in client.task.v2.comment.listWithIterator(
            params: .init(resourceType: "task", resourceId: taskGuid, direction: .asc))
        {
            for c in page.items ?? [] { print(c.id ?? "", c.creator?.id ?? "", c.content ?? "") }
        }
        _ = try await client.task.v2.comment.patch(commentId: commentId,
            body: .init(comment: .init(content: "Edited"), updateFields: ["content"]))
        _ = try await client.task.v2.comment.delete(commentId: commentId)
    }

    func attachments(client: LarkClient, taskGuid: String) async throws {
        let up = try await client.task.v2.attachment.upload(body: .init(
            resourceType: "task", resourceId: taskGuid, file: try LarkFile(path: "/tmp/spec.pdf")))
        print(up.data?.items?.first?.guid ?? "")

        for try await page in client.task.v2.attachment.listWithIterator(params: .init(resourceType: "task", resourceId: taskGuid)) {
            for a in page.items ?? [] { print(a.name ?? "", a.size ?? 0, a.url ?? "") }
        }
    }

    func events() {
        let dispatcher = EventDispatcher()
            .register(.taskTaskUpdatedV1) { e, _ in print("task changed:", e.taskId ?? "", e.objType ?? 0); return nil }
            .register(.taskTaskCommentUpdatedV1) { e, _ in print("comment:", e.taskId ?? "", e.commentId ?? ""); return nil }
        _ = dispatcher
        _ = (TaskAPI.Events.taskUpdateTenantV1, LarkEventKey<TaskAPI.TaskUpdateUserAccessV2Event>.taskTaskUpdateUserAccessV2)
    }

    func legacyAliases(client: LarkClient) {
        _ = (client.task.task, client.task.taskComment, client.task.v1.taskCollaborator)
        _ = try? JSONValue(jsonString: "{}")
    }

    @Test func compiles() {}
}
