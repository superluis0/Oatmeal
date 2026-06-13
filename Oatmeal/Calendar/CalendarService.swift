import Foundation
import EventKit

/// An invitee on a calendar event, with the email parsed from EventKit's
/// `mailto:` participant URL when present.
struct EventAttendee: Hashable, Sendable {
    let name: String
    let email: String?
    /// True when EventKit identifies this participant as the local user.
    let isSelf: Bool
}

struct CalendarEventInfo: Sendable {
    let id: String
    let title: String
    let attendees: [EventAttendee]
    var startDate: Date = .now
}

struct UpcomingMeeting: Identifiable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [EventAttendee]
    let joinURL: URL?

    var attendeeNames: [String] { attendees.map(\.name) }
}

/// Thin EventKit wrapper: ask for calendar access and find the event happening
/// around now, so a recording can be auto-titled with real attendees.
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .denied, .restricted: return false
        default:
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
    }

    /// Creates a "Follow-up: …" calendar event. Returns false if not authorized
    /// or the save fails.
    func createFollowUp(title: String, date: Date, notes: String, durationMinutes: Int = 30) -> Bool {
        guard durationMinutes > 0,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let calendar = store.defaultCalendarForNewEvents else { return false }
        let event = EKEvent(eventStore: store)
        event.title = "Follow-up: \(title)"
        event.startDate = date
        event.endDate = date.addingTimeInterval(TimeInterval(durationMinutes * 60))
        event.notes = notes
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }

    /// The event whose time window contains now (± `grace`), preferring one that
    /// is currently in progress over the next upcoming one.
    func currentOrUpcomingEvent(within grace: TimeInterval = 5 * 60) -> CalendarEventInfo? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }

        let now = Date()
        let windowStart = now.addingTimeInterval(-grace)
        let windowEnd = now.addingTimeInterval(grace)
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)

        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        let inProgress = events.first { $0.startDate <= now && $0.endDate >= now }
        guard let event = inProgress ?? events.first else { return nil }

        return CalendarEventInfo(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Meeting",
            attendees: Self.eventAttendees(event),
            startDate: event.startDate
        )
    }

    /// Maps EventKit participants to attendees with names and emails. EventKit
    /// exposes the email only through the participant's `mailto:` URL; a
    /// participant with no display name falls back to the email's local part.
    static func eventAttendees(_ event: EKEvent) -> [EventAttendee] {
        (event.attendees ?? []).compactMap { participant in
            var email: String?
            let url = participant.url
            if url.scheme?.lowercased() == "mailto" {
                // A mailto: URL can carry headers (`?subject=…`) and multiple
                // comma-separated recipients — keep only the first bare address.
                var address = String(url.absoluteString.dropFirst("mailto:".count))
                if let q = address.firstIndex(of: "?") { address = String(address[..<q]) }
                if let comma = address.firstIndex(of: ",") { address = String(address[..<comma]) }
                address = (address.removingPercentEncoding ?? address)
                    .trimmingCharacters(in: .whitespaces)
                if address.contains("@") { email = address.lowercased() }
            }
            var name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Calendar sometimes uses the bare address as the display name; treat
            // that like a missing name so we still derive something readable.
            if name.isEmpty || name.lowercased() == email, let email {
                name = String(email.prefix(while: { $0 != "@" }))
            }
            guard !name.isEmpty else { return nil }
            return EventAttendee(name: name, email: email, isSelf: participant.isCurrentUser)
        }
    }

    /// Upcoming *meetings* only — events with attendees or a video-call link,
    /// excluding all-day events, birthdays, and holidays. Default window: 7 days.
    func upcomingMeetings(within window: TimeInterval = 7 * 86_400, videoOnly: Bool) -> [UpcomingMeeting] {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            NSLog("[Oatmeal] calendar not authorized (status=\(status.rawValue))")
            return []
        }
        // Re-read the persistent store so newly-added events (Calendar.app/sync)
        // are reflected. `reset()` is synchronous and reliable — unlike creating a
        // fresh store, which can intermittently return an empty result before it
        // finishes loading. Kick off a remote refresh for next time too.
        store.reset()
        store.refreshSourcesIfNecessary()

        let now = Date()
        // Start slightly in the past so an in-progress meeting still appears.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-30 * 60),
            end: now.addingTimeInterval(window),
            calendars: nil
        )
        let all = store.events(matching: predicate)
        let meetings = all.filter { isMeeting($0, videoOnly: videoOnly) && $0.endDate > now }
        NSLog("[Oatmeal] calendar: \(all.count) events, \(meetings.count) meetings (videoOnly=\(videoOnly))")
        return meetings
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                UpcomingMeeting(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Meeting",
                    start: event.startDate,
                    end: event.endDate,
                    attendees: Self.eventAttendees(event),
                    joinURL: meetingURL(event)
                )
            }
    }

    /// Looks up a single event by its stable identifier and maps it to an
    /// `UpcomingMeeting`, so a specific meeting (e.g. from a pre-meeting reminder)
    /// can be recorded directly rather than re-picked from overlapping events.
    func upcomingMeeting(withID id: String) -> UpcomingMeeting? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let event = store.event(withIdentifier: id) else { return nil }
        return UpcomingMeeting(
            id: event.eventIdentifier ?? id,
            title: event.title ?? "Meeting",
            start: event.startDate,
            end: event.endDate,
            attendees: Self.eventAttendees(event),
            joinURL: meetingURL(event)
        )
    }

    /// A timed event (not all-day), excluding birthdays/holidays and anything
    /// canceled or declined. When `videoOnly`, also require a recognized
    /// video-conferencing / scheduling link.
    private func isMeeting(_ event: EKEvent, videoOnly: Bool) -> Bool {
        guard !event.isAllDay else { return false }
        if let type = event.calendar?.type, type == .birthday { return false }
        if event.status == .canceled { return false }
        if let me = event.attendees?.first(where: { $0.isCurrentUser }),
           me.participantStatus == .declined { return false }
        if videoOnly { return meetingURL(event) != nil }
        return true
    }

    private func meetingURL(_ event: EKEvent) -> URL? {
        if let url = event.url, isMeetingHost(url) { return url }
        let blob = [event.location, event.notes, event.url?.absoluteString]
            .compactMap { $0 }.joined(separator: " ")
        for token in blob.split(whereSeparator: { " \n\t\r<>()[]\"'".contains($0) }) {
            let s = String(token)
            guard s.contains("."),
                  let url = URL(string: s.hasPrefix("http") ? s : "https://\(s)"),
                  isMeetingHost(url) else { continue }
            return url
        }
        return nil
    }

    /// True only when the URL's parsed HOST is (a subdomain of) a known meeting
    /// provider — never a substring of the whole string. This rejects spoofed
    /// links from untrusted calendar invites, e.g. `https://zoom.us.attacker.com/…`
    /// (host `zoom.us.attacker.com`) which a substring check would have opened.
    private func isMeetingHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return Self.meetingDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let meetingDomains = [
        "zoom.us", "zoom.com",
        "meet.google.com", "g.co",
        "teams.microsoft.com", "teams.live.com",
        "webex.com",
        "calendly.com", "cal.com", "cal.ai",
        "whereby.com", "around.co", "around.com",
        "jit.si",
        "gotomeeting.com", "gotomeet.me",
        "chime.aws",
        "skype.com",
        "bluejeans.com", "ringcentral.com", "8x8.vc",
        "hubspot.com", "savvycal.com"
    ]

    /// Events starting within the next `window` seconds (excluding all-day),
    /// for scheduling pre-meeting reminders.
    func upcomingEvents(within window: TimeInterval) -> [CalendarEventInfo] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(window), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEventInfo(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Meeting",
                    attendees: Self.eventAttendees(event),
                    startDate: event.startDate
                )
            }
    }
}
