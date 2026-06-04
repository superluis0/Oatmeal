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
        static func == (l: Person, r: Person) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    private var people: [Person] {
        var map: [String: Person] = [:]
        for m in meetings {
            for a in m.attendees {
                let key = a.name.lowercased()
                if map[key] == nil {
                    map[key] = Person(id: key, name: a.name, email: a.email, meetingIDs: [])
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
        NavigationStack {
            Group {
                if people.isEmpty {
                    OatEmptyState(
                        icon: "person.2",
                        title: "No people yet",
                        message: "Attendees from your calendar meetings will appear here."
                    )
                } else {
                    List(people) { person in
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
                                Text("\(person.meetingIDs.count)").font(.caption).foregroundStyle(Theme.textSecondary)
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
        var items = meetings.flatMap { $0.actionItems }.filter { !$0.isDone }
        items += allMeetings.flatMap { $0.actionItems }
            .filter { !$0.isDone && ($0.owner?.lowercased() == name) }
        var seen = Set<PersistentIdentifier>()
        return items.filter { seen.insert($0.persistentModelID).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header
                if !commitments.isEmpty { commitmentsSection }
                meetingsSection
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .navigationTitle(person.name)
    }

    private var header: some View {
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

    private var commitmentsSection: some View {
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

    private var meetingsSection: some View {
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
