---
name: lark-swift-task
description: Manage Feishu/Lark Tasks (任务) from Swift with larksuite-swift-sdk's LarkTask module (Task v2). Use when creating tasks with assignees/followers/due dates/reminders, listing a user's tasks, updating or completing tasks, managing tasklists, subtasks, comments and attachments, or handling task events.
---

# Tasks with larksuite-swift-sdk

Module `LarkTask` (Node: `client.task.v1.*` / `client.task.v2.*`). For client setup, errors,
auth options and the Node→Swift mapping, see the `lark-swift-sdk` skill.

```swift
// Package.swift target dependencies
.product(name: "LarkCore", package: "larksuite-swift-sdk"),
.product(name: "LarkTask", package: "larksuite-swift-sdk"),
```

```swift
import LarkCore
import LarkTask

let client = try LarkClient(appId: "cli_xxx", appSecret: "xxx")
```

- **Use `client.task.v2`**: `task`, `taskSubtask`, `tasklist`, `section`, `comment`, `attachment`,
  `customField`, `customFieldOption`, `tasklistActivitySubscription`.
  `client.task.v1` is the legacy API (`task`, `taskComment`, `taskCollaborator`, `taskFollower`,
  `taskReminder`), and the shortcuts `client.task.task` / `client.task.taskComment` point to
  **v1**, not v2.
- Models live in `TaskAPI` (not `Task`, which would clash with Swift concurrency):
  `TaskAPI.TaskCreateBodyV2`, `TaskAPI.Member`, ... v2 types that share a name with v1 get a
  `V2` suffix. Many v2 queries/responses are deduplicated aliases, e.g. `task.create/get/patch`
  return `TaskAPI.TaskAddMembersResponse` (`data?.task`).
- v2 identifies tasks by `guid` (`taskGuid:`); `userIdType` is a plain string
  (`"open_id"` default, `"union_id"`, `"user_id"`).
- Times are **millisecond** timestamps as strings (`due.timestamp`, `completedAt`, ...).
- Identity: with the tenant token the app acts as itself and only sees tasks it created or
  was added to; "my tasks" listing needs `options: .userAccessToken(token)`.

## Create, read, update, complete, delete

```swift
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
```

Members, reminders and tasklists cannot be changed with `patch`; use the dedicated calls:

```swift
let member = TaskAPI.Member(id: openId, type: "user", role: "assignee")   // role: "assignee" | "follower"
_ = try await client.task.v2.task.addMembers(taskGuid: taskGuid, body: .init(members: [member]))
_ = try await client.task.v2.task.removeMembers(taskGuid: taskGuid, body: .init(members: [member]))
_ = try await client.task.v2.task.addReminders(taskGuid: taskGuid, body: .init(reminders: [.init(relativeFireMinute: 60)]))
_ = try await client.task.v2.task.addTasklist(taskGuid: taskGuid, body: .init(tasklistGuid: tasklistGuid))
_ = try await client.task.v2.task.removeTasklist(taskGuid: taskGuid, body: .init(tasklistGuid: tasklistGuid))
```

## List a user's tasks (user access token)

```swift
for try await page in client.task.v2.task.listWithIterator(
    params: .init(pageSize: 50, completed: false, type: "my_tasks", userIdType: "open_id"),
    options: .userAccessToken(userAccessToken))
{
    for t in page.items ?? [] { print(t.guid ?? "", t.summary ?? "", t.due?.timestamp ?? "") }
}
```

Only `type: "my_tasks"` ("assigned to me") is supported by the API.

## Tasklists

```swift
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
```

Sections inside a tasklist: `client.task.v2.section.create/list/tasks(...)` (`section.tasksWithIterator`).

## Subtasks

```swift
let sub = try await client.task.v2.taskSubtask.create(taskGuid: taskGuid, body: .init(
    summary: "Write changelog", members: [.init(id: openId, type: "user", role: "assignee")]))
print(sub.data?.subtask?.guid ?? "")

for try await page in client.task.v2.taskSubtask.listWithIterator(taskGuid: taskGuid) {
    for s in page.items ?? [] { print(s.guid ?? "", s.summary ?? "", s.completedAt ?? "") }
}
```

## Comments

```swift
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
```

## Attachments

```swift
let up = try await client.task.v2.attachment.upload(body: .init(
    resourceType: "task", resourceId: taskGuid, file: try LarkFile(path: "/tmp/spec.pdf")))
print(up.data?.items?.first?.guid ?? "")

for try await page in client.task.v2.attachment.listWithIterator(params: .init(resourceType: "task", resourceId: taskGuid)) {
    for a in page.items ?? [] { print(a.name ?? "", a.size ?? 0, a.url ?? "") }
}
```

- One file per call (the generated body has a single `file`); max 50 MB per file.
- The download `url` is temporary (about 3 minutes, a few downloads); list again for a fresh one.

## Events

Task events are v1 events (subscribe in the developer console). Typed keys:

```swift
let dispatcher = EventDispatcher()
    .register(.taskTaskUpdatedV1) { e, _ in print("task changed:", e.taskId ?? "", e.objType ?? 0); return nil }
    .register(.taskTaskCommentUpdatedV1) { e, _ in print("comment:", e.taskId ?? "", e.commentId ?? ""); return nil }
```

Also `TaskAPI.Events.taskUpdateTenantV1` and `.taskTaskUpdateUserAccessV2`.

## Gotchas

- `patch` uses `updateFields` with **wire names** (`"completed_at"`, `"due"`, `"start"`,
  `"description"`, `"repeat_rule"`, ...). A field listed without a value is cleared.
- Reminders need a `due`; custom fields must belong to a tasklist the task is in.
- Business errors throw `LarkError.api` (`e.code`, `e.msg`, `e.logId`).
- Missing an API? grep `Sources/LarkTask/TaskService.swift` for the path, or call it raw:
  `client.request(.get, "/open-apis/task/v2/...", as: JSONValue.self)`. Never invent methods.
