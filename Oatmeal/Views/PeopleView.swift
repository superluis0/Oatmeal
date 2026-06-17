import SwiftUI
import SwiftData

/// People directory → tap a person for their aggregated page: history, open
/// commitments, and a one-tap "ask about them" across every meeting.
struct PeopleView: View {
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    var onOpenMeeting: (Meeting) -> Void
    var onAsk: (String) -> Void = { _ in }

    struct Person: Identifiable, Hashable {
        let id: String
        let name: String
        let email: String?
        var meetingIDs: [PersistentIdentifier]
        var lastMet: Date?
        static func == (l: Person, r: Person) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    private var people: [Person] {
        var map: [String: Person] = [:]
        // `meetings` is sorted newest-first, so the first time we see a person is
        // their most recent meeting — capture it as `lastMet`.
        for m in meetings {
            for a in m.liveAttendees {
                let key = a.name.lowercased()
                if map[key] == nil {
                    map[key] = Person(id: key, name: a.name, email: a.email, meetingIDs: [], lastMet: m.date)
                }
                map[key]?.meetingIDs.append(m.persistentModelID)
            }
        }
        return map.values.sorted {
            $0.meetingIDs.count != $1.meetingIDs.count
                ? $0.meetingIDs.count > $1.meetingIDs.count
                : $0.name < $1.name
        }
    }

    var body: some View {
        // Build the directory once per render (it was computed twice — isEmpty + List).
        let directory = people
        return NavigationStack {
            Group {
                if directory.isEmpty {
                    OatEmptyState(
                        icon: "person.2",
                        title: "No people yet",
                        message: "Attendees from your calendar meetings will appear here."
                    )
                } else {
                    List(directory) { person in
                        NavigationLink(value: person) {
                            HStack(spacing: Theme.Space.sm) {
                                IconBadge(systemName: "person.fill", size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.name).font(.system(.headline))
                                    if let email = person.email {
                                        Text(email).font(.caption).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("\(person.meetingIDs.count) \(person.meetingIDs.count == 1 ? "meeting" : "meetings")")
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                    if let last = person.lastMet {
                                        Text("last \(last.formatted(.dateTime.month().day()))")
                                            .font(.caption2).foregroundStyle(Theme.textTertiary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg)
            .navigationTitle("People")
            .navigationDestination(for: Person.self) { person in
                PersonPage(person: person, onOpenMeeting: onOpenMeeting, onAsk: onAsk)
            }
        }
    }
}

/// One person's aggregated page.
struct PersonPage: View {
    let person: PeopleView.Person
    var onOpenMeeting: (Meeting) -> Void
    var onAsk: (String) -> Void
    @Query(sort: \Meeting.date, order: .reverse) private var allMeetings: [Meeting]

    private var meetings: [Meeting] {
        let ids = Set(person.meetingIDs)
        return allMeetings.filter { ids.contains($0.persistentModelID) }
    }

    private var commitments: [ActionItem] {
        let name = person.name.lowercased()
        var items = meetings.flatMap { $0.liveActionItems }.filter { !$0.isDone }
        items += allMeetings.flatMap { $0.liveActionItems }
            .filter { !$0.isDone && ($0.owner?.lowercased() == name) }
        var seen = Set<PersistentIdentifier>()
        return items.filter { seen.insert($0.persistentModelID).inserted }
    }

    var body: some View {
        // Compute the O(N×M) aggregates once per render, then thread them through the
        // sub-views — instead of recomputing inside each section's body.
        let meetings = meetings
        let commitments = commitments
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header(meetings, commitments)
                topicsSection(meetings)
                if !commitments.isEmpty { commitmentsSection(commitments) }
                meetingsSection(meetings)
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .navigationTitle(person.name)
    }

    private func header(_ meetings: [Meeting], _ commitments: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                stat("\(meetings.count)", "meetings")
                stat("\(commitments.count)", "open items")
                if let last = meetings.first {
                    stat(last.date.formatted(.dateTime.month().day()), "last met")
                }
            }
            Button {
                onAsk("Summarize everything I know about \(person.name): our shared history, key decisions, and any open commitments.")
            } label: {
                Label("Ask about \(person.name)", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(OatPrimaryButton(fullWidth: true))
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title2).weight(.bold)).foregroundStyle(Theme.accent)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .oatCard(padding: Theme.Space.sm)
    }

    /// The topics you keep coming back to with this person — the most common tags
    /// across your shared meetings. On-device, no LLM.
    @ViewBuilder
    private func topicsSection(_ meetings: [Meeting]) -> some View {
        let topics = recurringTopics(in: meetings)
        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                SectionLabel(text: "Recurring topics")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(topics, id: \.name) { t in
                            Text("#\(t.name)" + (t.count > 1 ? " ×\(t.count)" : ""))
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.accentSoft, in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private func recurringTopics(in meetings: [Meeting]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for m in meetings { for tag in m.tags { counts[tag, default: 0] += 1 } }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(10)
            .map { (name: $0.key, count: $0.value) }
    }

    private func commitmentsSection(_ commitments: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Open commitments")
            VStack(spacing: 0) {
                ForEach(commitments.prefix(12)) { item in
                    ActionItemRow(item: item, showSource: true, onOpenMeeting: onOpenMeeting)
                    if item.persistentModelID != commitments.prefix(12).last?.persistentModelID {
                        Divider().overlay(Theme.hairline).padding(.leading, 36)
                    }
                }
            }
            .oatCard(padding: Theme.Space.xs)
        }
    }

    private func meetingsSection(_ meetings: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Meetings together")
            ForEach(meetings) { m in
                Button { onOpenMeeting(m) } label: {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(Theme.accent)
                        Text(m.title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        Text(m.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
    }
}
