import Foundation
import LarkCalendar
import LarkCore
import Testing

/// Compile-checks the code shown in skills/lark-swift-calendar/SKILL.md (never executed).
/// The Package.swift dependency lines and the imports are covered by this target's manifest and imports.
@Suite struct CalendarSkillSnippetTests {
    func calendars(client: LarkClient, userAccessToken: String) async throws {
        // Bot's primary calendar (with a tenant token user_id_type must not be user_id)
        let primary = try await client.calendar.v4.calendar.primary(params: .init(userIdType: .openId))
        let calendarId = primary.data?.calendars?.first?.calendar?.calendarId ?? ""
        print(calendarId)

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
    }

    func createEvent(
        client: LarkClient, calendarId: String, attendeeOpenId: String, chatId: String, roomId: String
    ) async throws {
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
    }

    func timeRange(client: LarkClient, calendarId: String) async throws {
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
    }

    func freebusy(client: LarkClient, attendeeOpenId: String, otherOpenId: String) async throws {
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
    }

    func updateReadDelete(client: LarkClient, calendarId: String, eventId: String, start: Int) async throws {
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
    }

    func events(client: LarkClient, calendarId: String) async throws -> EventDispatcher {
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
        return dispatcher
    }

    func rawFallback(client: LarkClient, q: CalendarAPI.ExchangeBindingGetQuery) async throws {
        _ = try await client.request(.get, "/open-apis/calendar/v4/...", query: q, as: JSONValue.self)
    }

    @Test func compiles() {}
}
