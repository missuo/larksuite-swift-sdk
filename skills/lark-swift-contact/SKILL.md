---
name: lark-swift-contact
description: Feishu/Lark Contact (通讯录) in Swift with larksuite-swift-sdk's LarkContact module. Use when looking up users by id, resolving emails/mobiles to user ids, listing users of a department, walking the department tree, checking the app's contact scope, or handling user/department created/updated/deleted events.
---

# Contact with larksuite-swift-sdk

Port of node-sdk's `client.contact.*`. Read the generic `lark-swift-sdk` skill first for the
client, errors, `RequestOptions` and the event dispatcher; this skill only covers contacts.

```swift
// Package.swift target dependencies
.product(name: "LarkCore", package: "larksuite-swift-sdk"),
.product(name: "LarkContact", package: "larksuite-swift-sdk"),
```

```swift
import LarkCore
import LarkContact
```

## Layout

- Only `v3` exists: `client.contact.v3.<resource>.<method>(...)`, also aliased on
  `client.contact` (`client.contact.user.get(...)`).
- Resources: `user`, `department`, `scope`, `group`, `groupMember`, `unit`, `jobLevel`,
  `jobFamily`, `jobTitle`, `workCity`, `employeeTypeEnum`, `functionalRole`,
  `functionalRoleMember`, `customAttr`.
- Models live in the `Contact` namespace: `Contact.UserGetQuery`, `Contact.Department`, ...
- The id-type enums are `Contact.MemberIdType` (`.openId`, `.unionId`, `.userId`) and
  `Contact.DepartmentIdType` (`.openDepartmentId`, `.departmentId`). Many queries are typealiases
  of one shared struct (`UserGetQuery` == `DepartmentGetQuery` == `{ userIdType, departmentIdType }`).

## Get a user

```swift
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
```

`userId:` must be in the id type named by `userIdType` (default `open_id`).

## Email / mobile to user id

```swift
let ids = try await client.contact.v3.user.batchGetId(
    params: .init(userIdType: .openId),
    body: .init(emails: ["alice@example.com"], mobiles: ["+8613800000000"], includeResigned: false))
for item in ids.data?.userList ?? [] {
    print(item.email ?? item.mobile ?? "", "->", item.userId ?? "not found")   // userId holds the open_id here
}
```

At most 50 emails and 50 mobiles per call. Users outside the app's contact scope come back
without `userId`.

## Users in a department

```swift
// Direct members of a department ("0" = the root department)
for try await page in client.contact.v3.user.findByDepartmentWithIterator(params: .init(
    userIdType: .openId, departmentIdType: .openDepartmentId, departmentId: "0", pageSize: 50))
{
    for u in page.items ?? [] { print(u.openId ?? "", u.name, u.email ?? "") }
}
```

There is no recursive flag: walk the department tree (below) and list each department.

## Departments

```swift
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
```

## What the app can see

```swift
for try await page in client.contact.v3.scope.listWithIterator(
    params: .init(userIdType: .openId, departmentIdType: .openDepartmentId))
{
    print(page.departmentIds ?? [], page.userIds ?? [], page.groupIds ?? [])
}
```

## Events

Subscribe in the developer console (Events & Callbacks), then register handlers (long
connection or webhook). Typed keys: `.contactUserCreatedV3`, `.contactUserUpdatedV3`,
`.contactUserDeletedV3`, `.contactDepartmentCreatedV3`, `.contactDepartmentUpdatedV3`,
`.contactDepartmentDeletedV3`, `.contactScopeUpdatedV3`, `.contactEmployeeTypeEnum*V3`,
`.contactCustomAttrEventUpdatedV3` (or `Contact.Events.*`).

```swift
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
```

## Gotchas

- **ID types everywhere**: `userIdType` defaults to `open_id`, `departmentIdType` to
  `open_department_id` (server defaults). Pass ids in the same type you ask for; `user_id` needs
  the extra "user ID" permission. The root department is `"0"` in both department id types.
- **Contact scope**: the app only sees users/departments in its contact permission range
  (`scope.list`); anything outside returns empty results or a permission `LarkError.api`.
- **Field permissions**: `email`, `mobile`, `departmentIds`, ... are only returned when the
  app has the matching field permission; otherwise they are absent (nil).
- **Strict required fields**: node-sdk marks `name` and `mobile` required on
  `user.findByDepartment` / `user.batch` items and on user event objects. A list item missing a
  required field is dropped from `items`; an event object missing one decodes as `nil`. If users
  "disappear", grant the mobile permission or read the raw body (`response.json` /
  `raw.payload`). `user.get` has no required fields.
- **Pagination**: use the `xxxWithIterator` methods (`findByDepartment`, `department.children`,
  `department.parent`, `department.list`, `user.list`, `scope.list`, ...); each element is one
  page's `data`. `user.list` and `department.list` are legacy; prefer `findByDepartment` and
  `children`.
- **Tenant vs user token**: reads work with the tenant token; `.userAccessToken(t)` limits results
  to what that user can see.
- **Endpoints node-sdk lacks**: `client.request(.get, "/open-apis/contact/v3/...", query: q, as: JSONValue.self)`.
  Never guess a generated method name; grep `Sources/LarkContact/ContactService.swift` for the
  HTTP path.
