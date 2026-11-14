---
name: lark-swift-approval
description: Feishu/Lark Approval (审批) in Swift with larksuite-swift-sdk's LarkApproval module. Use when reading approval definitions, creating approval instances with form data, listing/querying instances or a user's tasks, approving/rejecting/transferring tasks, cancelling instances, adding comments, or handling approval instance/task status events.
---

# Approval with larksuite-swift-sdk

Port of node-sdk's `client.approval.*`. Read the generic `lark-swift-sdk` skill first for the
client, errors, `RequestOptions` and the event dispatcher; this skill only covers approval.

```swift
// Package.swift target dependencies
.product(name: "LarkCore", package: "larksuite-swift-sdk"),
.product(name: "LarkApproval", package: "larksuite-swift-sdk"),
```

```swift
import LarkCore
import LarkApproval
```

## Layout

- Only `v4` exists: `client.approval.v4.<resource>.<method>(...)`; the resources are also
  aliased on `client.approval` (`client.approval.instance.get(...)` == `client.approval.v4.instance.get(...)`).
- Resources: `approval` (definitions + event subscription), `instance`, `task`,
  `instanceComment`, `externalApproval` / `externalInstance` / `externalTask` (third-party
  approvals synced into Feishu), `district`.
- Models live in the `Approval` namespace: `Approval.InstanceCreateBody`,
  `Approval.TaskApproveQuery`, ... `Approval.Approval` is the *model* of an approval definition
  summary inside query results (not the namespace). If your own code declares an `Approval`
  type, spell models as `LarkApproval.Approval.InstanceCreateBody`.
- Many params are typealiases of a shared struct (`TaskApproveQuery`, `TaskRejectQuery`,
  `InstanceCancelQuery` are all `{ userIdType }`); `.init(...)` works the same.
- Open enums accept string literals and expose the known values as static members
  (`.pending`, `.approved`): `instanceStatus: "PENDING"` and `t.status == .pending` both work.

## Approval definition (form + nodes)

```swift
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
```

## Create an instance

`form` is a **string containing a JSON array** of `{id, type, value}` widget values (ids and types
from the definition's `form`). Dates are RFC 3339 strings (`"2026-11-20T09:00:00+08:00"`).

```swift
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
```

`nodeApprover*List` is only needed for nodes whose approver is "chosen by the applicant"
(`needApprover == true` in the definition).

## Read instances

```swift
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
```

## A user's tasks (to-do list)

`topic`: `"1"` to-do, `"2"` done, `"3"` initiated, `"17"` unread CC, `"18"` read CC.

```swift
for try await page in client.approval.v4.task.queryWithIterator(
    params: .init(pageSize: 50, userId: approverOpenId, topic: "1", userIdType: .openId))
{
    for t in page.tasks ?? [] {
        // processCode = instance code, definitionCode = approval code
        print(t.taskId ?? "", t.title ?? "", t.processCode ?? "", t.definitionCode ?? "", t.status?.rawValue ?? "")
    }
}
// Cross-user search: client.approval.v4.task.search(params:body:) with TaskSearchBody filters.
```

## Approve, reject, transfer, cancel

`userId` is the user acting (the task's approver, or the applicant for `cancel`), in the id type
given by `params.userIdType`.

```swift
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
```

Others with the same shape: `task.rollback`, `task.addSign`, `task.resubmit`, `instance.cc`,
`instance.remind`, `instance.specifiedRollback`. Cancel only works when the definition allows
revoking (admin setting); otherwise it throws `LarkError.api`.

## Comments

`content` is a JSON string: `{"text": "...", "files": [...]}`.

```swift
let text: JSONValue = ["text": "Please attach the invoice", "files": []]
let comment = try await client.approval.v4.instanceComment.create(
    instanceId: instanceCode, params: .init(userIdType: .openId, userId: commenterOpenId),
    body: .init(content: text.jsonString()))
print(comment.data?.commentId ?? "")
let list = try await client.approval.v4.instanceComment.list(
    instanceId: instanceCode, params: .init(userIdType: .openId, userId: commenterOpenId, pageSize: 50))
for c in list.data?.comments ?? [] { print(c.commentator ?? "", c.content ?? "", c.createTime ?? "") }
```

## Events

Subscribe the app once, then register handlers (long connection or webhook, see the generic
skill). node-sdk types three v4 events; keys are `.approvalInstanceStatusChangedV4`,
`.approvalTaskStatusChangedV4`, `.approvalApprovalUpdatedV4` (or `Approval.Events.*`).

```swift
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
```

Events can arrive more than once and out of order: dedupe by `raw.eventId` and re-read the
instance with `instance.get` before acting on a status.

## Gotchas

- **Form is a string.** `InstanceCreateBody.form`, `ApprovalGetResponse.form` and
  `InstanceGetResponse.form` are JSON strings; build them with `JSONValue(...).jsonString()`
  and parse with `JSONValue(jsonString:)`. Widget ids must match the definition.
- **Timestamps are milliseconds as strings** (`startTime`, `endTime`, `createTime`,
  `instanceStartTimeFrom/To`); date widget values are RFC 3339.
- **ID types**: `params.userIdType` decides how every `userId:` / `transferUserId:` value is read.
  Set it explicitly (`params: .init(userIdType: .openId)`) and pass ids of that type; `user_id`
  needs the extra "user ID" permission.
- **Tenant vs user token**: everything works with the app's tenant token (the acting user is
  the `userId` field); `instance.initiated` and a few others need `options: .userAccessToken(t)`.
- **Business errors throw** `LarkError.api(e)`; `e.code`/`e.msg` explain permission or
  state problems (e.g. a task that is no longer pending).
- **Iterators**: `xxxWithIterator` exists only where node-sdk has one.
  `instanceComment.listWithIterator` yields a single page (the response has no page token), so
  use `list`.
- **Strict required fields**: a response missing a field node-sdk marks required throws
  `LarkError.decoding(message:body:)`; the raw `body` is attached, parse it with `JSONValue(data:)`.
- **Endpoints node-sdk lacks**: `client.request(.post, "/open-apis/approval/v4/...", json: body, as: JSONValue.self)`.
  Never guess a generated method name; grep `Sources/LarkApproval/ApprovalService.swift` for
  the HTTP path.
