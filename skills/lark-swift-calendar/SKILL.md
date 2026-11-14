---
name: lark-swift-calendar
description: Feishu/Lark Calendar (日历) in Swift with larksuite-swift-sdk's LarkCalendar module. Use when finding a primary calendar, listing calendars, creating/updating/deleting events, inviting attendees or meeting rooms, listing events in a time range, querying free/busy, or handling calendar/event change events.
---

# Calendar with larksuite-swift-sdk

Port of node-sdk's `client.calendar.*`. Read the generic `lark-swift-sdk` skill first for the
client, errors, `RequestOptions` and the event dispatcher; this skill only covers calendar.

```swift
// Package.swift target dependencies
.product(name: "LarkCore", package: "larksuite-swift-sdk"),
.product(name: "LarkCalendar", package: "larksuite-swift-sdk"),
```

```swift
import LarkCore
import LarkCalendar
```

## Layout

- Only `v4` exists: `client.calendar.v4.<resource>.<method>(...)`, also aliased on
  `client.calendar` (`client.calendar.calendarEvent.list(...)`).
- Resources: `calendar`, `calendarEvent`, `calendarEventAttendee`,
  `calendarEventAttendeeChatMember`, `calendarAcl`, `freebusy`, `timeoffEvent`,
  `calendarEventMeetingChat`, `calendarEventMeetingMinute`, `exchangeBinding`, `setting`.
- Models live in the **`CalendarAPI`** namespace (not `Calendar`, which is Foundation's):
  `CalendarAPI.CalendarEventCreateBody`, `CalendarAPI.StartTime`, ...
- Identity decides whose calendar you touch: with the default tenant token you act as the
  **app's bot** (its own primary calendar); pass `options: .userAccessToken(t)` to act as a user.
  The bot capability must be enabled for tenant-token calls.

## Primary calendar and calendar list

```swift
// Bot's primary calendar (with a tenant token user_id_type must not be user_id)
let primary = try await client.calendar.v4.calendar.primary(params: .init(userIdType: .openId))
let calendarId = primary.data?.calendars?.first?.calendar?.calendarId ?? ""

// A user's own primary calendar
let mine = try await client.calendar.v4.calendar.primary(options: .userAccessToken(userAccessToken))
print(mine.data?.calendars?.first?.calendar?.summary ?? "")

// Calendars visible to the identity; no iterator in node-sdk, page manually
var token: String? = nil
repeat {
    let r = try await client.calendar.v4.calendar.list(params: .init(pageSize: 500, pageToken: token))
    for c in r.data?.calendarList ?? [] {
        print(c.calendarId, c.summary ?? "", c.type?.rawValue ?? "", c.role?.rawValue ?? "")
    }
    token = r.data?.hasMore == true ? r.data?.pageToken : nil
} while token != nil
```

## Create an event and invite attendees

Times are `CalendarAPI.StartTime`: `timestamp` = **Unix seconds as a string** plus an IANA
`timezone`, or `date` = `"yyyy-MM-dd"` for all-day events. Attendees are added in a second call.

```swift
let start = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
let event = try await client.calendar.v4.calendarEvent.create(
    calendarId: calendarId,
    params: .init(idempotencyKey: UUID().uuidString, userIdType: .openId),
    body: .init(
        summary: "Design review",
        description: "Agenda: API surface",
        needNotification: true,
        startTime: .init(timestamp: String(start), timezone: "Asia/Shanghai"),
        endTime: .init(timestamp: String(start + 1800), timezone: "Asia/Shanghai"),
        vchat: .init(vcType: .vc),                       // Feishu video meeting
        visibility: .default,
        attendeeAbility: .canSeeOthers,
        freeBusyStatus: .busy,
        location: .init(name: "5F Room A"),
        reminders: [.init(minutes: 10)]))
let eventId = event.data?.event?.eventId ?? ""

_ = try await client.calendar.v4.calendarEventAttendee.create(
    calendarId: calendarId, eventId: eventId,
    params: .init(userIdType: .openId),
    body: .init(attendees: [
        .init(type: .user, isOptional: false, userId: attendeeOpenId),
        .init(type: .chat, chatId: chatId),                      // every member of a group
        .init(type: .resource, roomId: roomId),                  // meeting room (booked asynchronously)
        .init(type: .thirdParty, thirdPartyEmail: "guest@example.com"),
    ], needNotification: true))

for try await page in client.calendar.v4.calendarEventAttendee.listWithIterator(
    calendarId: calendarId, eventId: eventId, params: .init(userIdType: .openId, pageSize: 100))
{
    for a in page.items ?? [] { print(a.displayName ?? "", a.rsvpStatus?.rawValue ?? "") }
}
```

## Events in a time range

```swift
let from = Int(Date().timeIntervalSince1970), to = from + 7 * 86_400   // Unix seconds
let r = try await client.calendar.v4.calendarEvent.list(
    calendarId: calendarId,
    params: .init(pageSize: 500, startTime: String(from), endTime: String(to), userIdType: .openId))
for e in r.data?.items ?? [] where e.status != "cancelled" {
    print(e.eventId, e.summary ?? "", e.startTime.timestamp ?? e.startTime.date ?? "", e.recurrence ?? "")
}

// Recurring events expanded into single occurrences (window of at most 40 days)
let view = try await client.calendar.v4.calendarEvent.instanceView(
    calendarId: calendarId, params: .init(startTime: String(from), endTime: String(to), userIdType: .openId))
for e in view.data?.items ?? [] { print(e.eventId, e.summary ?? "", e.startTime?.timestamp ?? "") }
```

Set `startTime` and `endTime` together. For incremental sync, call `list` without a window and
keep the returned `syncToken`.

## Free/busy

`timeMin`/`timeMax` are **RFC 3339** strings (unlike event times).

```swift
let fmt = ISO8601DateFormatter()                       // "2026-11-20T01:00:00Z"
let timeMin = fmt.string(from: Date()), timeMax = fmt.string(from: Date().addingTimeInterval(86_400))
let fb = try await client.calendar.v4.freebusy.list(
    params: .init(userIdType: .openId), body: .init(timeMin: timeMin, timeMax: timeMax, userId: attendeeOpenId))
for slot in fb.data?.freebusyList ?? [] { print("busy", slot.startTime, "-", slot.endTime) }

// Several users at once (meeting rooms: freebusy.list with roomId:)
let many = try await client.calendar.v4.freebusy.batch(
    params: .init(userIdType: .openId),
    body: .init(timeMin: timeMin, timeMax: timeMax, userIds: [attendeeOpenId, otherOpenId], onlyBusy: true))
for u in many.data?.freebusyLists ?? [] { print(u.userId ?? "", (u.freebusyItems ?? []).count, "busy slots") }
```

## Update, read, delete

```swift
_ = try await client.calendar.v4.calendarEvent.patch(
    calendarId: calendarId, eventId: eventId, params: .init(userIdType: .openId),
    body: .init(summary: "Design review (moved)",
                startTime: .init(timestamp: String(start + 3600), timezone: "Asia/Shanghai"),
                endTime: .init(timestamp: String(start + 5400), timezone: "Asia/Shanghai")))
let got = try await client.calendar.v4.calendarEvent.get(
    calendarId: calendarId, eventId: eventId, params: .init(needAttendee: true, userIdType: .openId))
print(got.data?.event?.summary ?? "", got.data?.event?.appLink ?? "")
_ = try await client.calendar.v4.calendarEvent.delete(
    calendarId: calendarId, eventId: eventId, params: .init(needNotification: "true"))
```

Only fields you set are sent by `patch` (nil fields are omitted). Only the organizer can change
most fields; attendees can change `visibility`, `freeBusyStatus`, `color`, `reminders`.

## Events (change notifications)

Subscribe with the identity that owns/reads the calendar, then register handlers (long
connection or webhook). Typed keys: `.calendarCalendarEventChangedV4`,
`.calendarCalendarChangedV4`, `.calendarCalendarAclCreatedV4`, `.calendarCalendarAclDeletedV4`
(or `CalendarAPI.Events.*`).

```swift
_ = try await client.calendar.v4.calendarEvent.subscription(calendarId: calendarId)  // events of one calendar
_ = try await client.calendar.v4.calendar.subscription()                             // the calendar list

let dispatcher = EventDispatcher()
    .register(.calendarCalendarEventChangedV4) { e, _ in      // CalendarAPI.CalendarEventChangedV4Event
        let who = (e.userIdList ?? []).compactMap(\.openId)
        print(e.calendarId ?? "", e.calendarEventId ?? "", e.changeType ?? "", who)
        return nil                                            // re-fetch with calendarEvent.get
    }
    .register(.calendarCalendarChangedV4) { e, _ in
        print("calendar list changed for", (e.userIdList ?? []).compactMap(\.openId))
        return nil
    }
```

## Gotchas

- **Three time formats**: event `StartTime.timestamp` and `list`/`instanceView` windows are Unix
  **seconds** strings; `freebusy` uses RFC 3339; `date` is `yyyy-MM-dd`.
- **Bot vs user calendar**: tenant-token calls see the bot's calendars. To put an event on a
  user's calendar either use `.userAccessToken(t)` or create it on the bot's calendar and add the
  user as an attendee.
- **Attendees are separate**: `calendarEvent.create` has no attendee field; call
  `calendarEventAttendee.create`. Room bookings are asynchronous (check the attendee's status).
- **IDs**: `userIdType` (`.openId`/`.unionId`/`.userId`) applies to attendee ids and organizer
  fields. The primary calendar endpoint with a tenant token rejects `user_id`.
- **Pagination**: iterators exist only where node-sdk has them (`calendarEventAttendee`,
  `calendarAcl.list`, `calendar.search`, `calendarEvent.search`). Page `calendar.list` and
  `calendarEvent.list` manually with `pageToken`/`hasMore`.
- **Strict required fields**: list items missing a field node-sdk marks required are dropped
  from the decoded array; a missing top-level field throws `LarkError.decoding(message:body:)`.
  When in doubt read `response.json` (the whole body as `JSONValue`).
- **Endpoints node-sdk lacks**: `client.request(.get, "/open-apis/calendar/v4/...", query: q, as: JSONValue.self)`.
  Never guess a generated method name; grep `Sources/LarkCalendar/CalendarService.swift` for the
  HTTP path.
