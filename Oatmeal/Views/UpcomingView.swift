import SwiftUI
import AppKit
import EventKit

/// Upcoming calendar meetings (real meetings only), with quick Join / Record.
struct UpcomingView: View {
    let coordinator: RecordingCoordinator
    var onOpenMeeting: (Meeting) -> Void = { _ in }
    @Environment(\.modelContext) private var context

    @State private var meetings: [UpcomingMeeting] = []
    @State private var authorized = true
    @State private var loading = true
    @State private var videoOnly = AppSettings.upcomingVideoOnly
    @State private var calendar = CalendarService()
    @State private var briefTarget: UpcomingMeeting?

    var body: some View {
        Group {
            if !authorized {
                accessPrompt
            } else if meetings.isEmpty && loading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if meetings.isEmpty && !loading {
                OatEmptyState(
                    icon: "calendar",
                    title: "No upcoming meetings",
                    message: videoOnly
                        ? "Showing only events with a video-call link (Zoom, Meet, Teams, Calendly…). Use the filter button to show all events."
                        : "No timed events on your calendar in the next 7 days."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        ForEach(grouped, id: \.0) { day, items in
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                SectionLabel(text: day)
                                VStack(spacing: Theme.Space.sm) {
                                    ForEach(items) { meeting in
                                        row(meeting)
                                    }
                                }
                            }
                        }
                    }
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Theme.bg)
        .navigationTitle("Upcoming")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $videoOnly) {
                        Text("Video meetings only").tag(true)
                        Text("All events").tag(false)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: videoOnly ? "video.fill" : "calendar")
                }
                .onChange(of: videoOnly) { _, new in
                    AppSettings.upcomingVideoOnly = new
                    Task { await load() }
                }
            }
            ToolbarItem {
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await load() }
        }
        .sheet(item: $briefTarget) { target in
            PreMeetingBriefView(
                upcoming: target,
                onJoinAndRecord: { joinAndRecord(target) },
                onOpenMeeting: onOpenMeeting
            )
        }
    }

    // MARK: - Rows

    private func row(_ meeting: UpcomingMeeting) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            VStack(spacing: 1) {
                Text(meeting.start, format: .dateTime.hour().minute())
                    .font(.system(.callout).weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text(durationText(meeting))
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(.headline))
                    .foregroundStyle(Theme.textPrimary)
                if !meeting.attendees.isEmpty {
                    Label(meeting.attendeeNames.prefix(4).joined(separator: ", "),
                          systemImage: "person.2")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if isLive(meeting) {
                    OatPill(text: "Happening now", systemImage: "dot.radiowaves.left.and.right", tint: Theme.danger)
                }
            }
            Spacer()

            VStack(spacing: 6) {
                Button("Prep") { briefTarget = meeting }
                    .buttonStyle(OatGhostButton())
                if meeting.joinURL != nil {
                    Button("Join & Record") { joinAndRecord(meeting) }
                        .buttonStyle(OatPrimaryButton())
                        .disabled(coordinator.isBusy || coordinator.isRecording)
                } else {
                    Button("Record") {
                        NSApp.activate(ignoringOtherApps: true)
                        Task { await coordinator.start(context: context, event: meeting) }
                    }
                    .buttonStyle(OatPrimaryButton())
                    .disabled(coordinator.isBusy || coordinator.isRecording)
                }
            }
        }
        .oatCard()
    }

    private func joinAndRecord(_ meeting: UpcomingMeeting) {
        if let url = meeting.joinURL { NSWorkspace.shared.open(url) }
        NSApp.activate(ignoringOtherApps: true)
        Task { await coordinator.start(context: context, event: meeting) }
    }

    private var accessPrompt: some View {
        VStack(spacing: Theme.Space.md) {
            IconBadge(systemName: "calendar", size: 64)
            Text("Calendar access needed")
                .font(.system(.title2).weight(.semibold))
            Text("Allow calendar access to see your upcoming meetings here.")
                .font(.system(.body))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Grant Access") { Task { await load(forcePrompt: true) } }
                .buttonStyle(OatPrimaryButton())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }

    // MARK: - Data

    private func load(forcePrompt: Bool = false) async {
        loading = true
        defer { loading = false }
        authorized = await calendar.requestAccess()
        meetings = authorized ? calendar.upcomingMeetings(videoOnly: videoOnly) : []
    }

    private var grouped: [(String, [UpcomingMeeting])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: meetings) { cal.startOfDay(for: $0.start) }
        return groups.keys.sorted().map { (dayLabel($0), (groups[$0] ?? []).sorted { $0.start < $1.start }) }
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).month().day())
    }

    private func durationText(_ m: UpcomingMeeting) -> String {
        let mins = Int(m.end.timeIntervalSince(m.start) / 60)
        if mins <= 0 { return "" }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, r = mins % 60
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    private func isLive(_ m: UpcomingMeeting) -> Bool {
        let now = Date()
        return m.start <= now && m.end >= now
    }
}
