import SwiftUI
import SwiftData

/// A pre-meeting brief: before you walk into a meeting, prepare it — confirm
/// who is expected to speak (names + emails from the invite, editable), jot
/// talking points — and surface what you already know: the last time this
/// meeting happened, open commitments, and prior history with the attendees.
/// The prepared roster and notes are persisted per calendar event and consumed
/// by `RecordingCoordinator` when the recording starts.
struct PreMeetingBriefView: View {
    let upcoming: UpcomingMeeting
    var onJoinAndRecord: () -> Void
    var onOpenMeeting: (Meeting) -> Void
    @Query(sort: \Meeting.date, order: .reverse) private var pastMeetings: [Meeting]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var prep: MeetingPrep?
    @State private var newPerson = ""

    private func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var priorOccurrences: [Meeting] {
        let t = norm(upcoming.title)
        return pastMeetings.filter { $0.date < .now && norm($0.title) == t }
    }

    private var attendeeNames: Set<String> { Set(upcoming.attendeeNames.map(norm)) }

    private var relatedByPeople: [Meeting] {
        guard !attendeeNames.isEmpty else { return [] }
        let priorIDs = Set(priorOccurrences.map(\.id))
        return pastMeetings.filter { m in
            m.date < .now && !priorIDs.contains(m.id)
                && m.attendeeNames.contains { attendeeNames.contains(norm($0)) }
        }
    }

    private var openItems: [ActionItem] {
        // Open items from prior occurrences of THIS meeting, plus items owned by an
        // attendee but only within meetings that actually involve these people —
        // so an unrelated meeting that happens to share one attendee doesn't flood
        // the brief.
        let relevant = priorOccurrences + relatedByPeople
        var items: [ActionItem] = relevant.flatMap { meeting in
            meeting.liveActionItems.filter { item in
                !item.isDone
                    && (priorOccurrences.contains { $0.id == meeting.id }
                        || (item.owner.map { attendeeNames.contains(norm($0)) } ?? false))
            }
        }
        var seen = Set<PersistentIdentifier>()
        items = items.filter { seen.insert($0.persistentModelID).inserted }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if let prep { speakersSection(prep) }
                    if let prep { notesSection(prep) }
                    if let prior = priorOccurrences.first { lastTimeSection(prior) }
                    if !openItems.isEmpty { openItemsSection }
                    if !relatedByPeople.isEmpty { historySection }
                    if priorOccurrences.isEmpty && openItems.isEmpty && relatedByPeople.isEmpty {
                        Text("No prior history with this meeting or these people yet — Oatmeal will build it as you record.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 640)
        .background(Theme.bg)
        .fontDesign(Appearance.shared.fontDesign)
        .onAppear(perform: loadOrCreatePrep)
        .onDisappear(perform: savePrep)
    }

    // MARK: - Prep persistence

    private func loadOrCreatePrep() {
        guard prep == nil else { return }
        let eventID = upcoming.id
        var descriptor = FetchDescriptor<MeetingPrep>(
            predicate: #Predicate { $0.calendarEventID == eventID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first, existing.isAlive {
            prep = existing
            return
        }
        let fresh = MeetingPrep(
            calendarEventID: upcoming.id,
            title: upcoming.title,
            eventStart: upcoming.start,
            speakers: upcoming.attendees.map {
                PlannedSpeaker(name: $0.name, email: $0.email, isSelf: $0.isSelf)
            }
        )
        context.insert(fresh)
        // Persist immediately so the one-prep-per-event row is durable even if the
        // sheet is torn down without onDisappear (e.g. an app quit while open).
        try? context.save()
        prep = fresh
    }

    private func savePrep() {
        guard let prep, prep.isAlive else { return }
        prep.updatedAt = .now
        try? context.save()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(upcoming.title).font(.system(.title3).weight(.bold)).lineLimit(2)
                    Text(upcoming.start.formatted(date: .complete, time: .shortened))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { savePrep(); dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            Button {
                savePrep()
                dismiss()
                onJoinAndRecord()
            } label: {
                Label(upcoming.joinURL != nil ? "Join & Record" : "Record", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OatPrimaryButton(fullWidth: true))
        }
        .padding(Theme.Space.md)
    }

    // MARK: - Speakers

    private func speakersSection(_ prep: MeetingPrep) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Speakers")
            Text("Confirm who'll be talking. Names are matched to diarized speakers after the recording, and emails feed follow-ups.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            ForEach(prep.speakers) { speaker in
                speakerRow(speaker, in: prep)
            }
            HStack(spacing: Theme.Space.sm) {
                TextField("Add person — name or email", text: $newPerson)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline))
                    .onSubmit { addPerson(to: prep) }
                Button("Add") { addPerson(to: prep) }
                    .buttonStyle(OatGhostButton())
                    .disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 2)
        }
        .oatCard()
    }

    private func speakerRow(_ speaker: PlannedSpeaker, in prep: MeetingPrep) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            Image(systemName: speaker.willSpeak ? "person.wave.2.fill" : "person.fill")
                .foregroundStyle(speaker.willSpeak ? Theme.accent : Theme.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: binding(for: speaker.id, in: prep, keyPath: \.name))
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline).weight(.medium))
                if let email = speaker.email, !email.isEmpty {
                    Text(email).font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if speaker.isSelf {
                OatPill(text: "You", systemImage: "person.crop.circle")
            }
            Toggle("Speaking", isOn: binding(for: speaker.id, in: prep, keyPath: \.willSpeak))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(speaker.willSpeak ? "Expected to speak" : "Attending, but not speaking")
            Button {
                prep.speakers.removeAll { $0.id == speaker.id }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove from this meeting's roster")
        }
        .padding(.vertical, 2)
    }

    /// Writes through to the matching element of `prep.speakers`; reassigning the
    /// array (rather than mutating in place) is what makes SwiftData persist it.
    private func binding<V>(for id: UUID, in prep: MeetingPrep,
                            keyPath: WritableKeyPath<PlannedSpeaker, V>) -> Binding<V> {
        Binding(
            get: {
                guard let s = prep.speakers.first(where: { $0.id == id }) else {
                    return PlannedSpeaker(name: "")[keyPath: keyPath]
                }
                return s[keyPath: keyPath]
            },
            set: { newValue in
                guard prep.isAlive,
                      let i = prep.speakers.firstIndex(where: { $0.id == id }) else { return }
                var copy = prep.speakers
                copy[i][keyPath: keyPath] = newValue
                prep.speakers = copy
            }
        )
    }

    private func addPerson(to prep: MeetingPrep) {
        let entry = newPerson.trimmingCharacters(in: .whitespacesAndNewlines)
        newPerson = ""
        guard !entry.isEmpty else { return }
        var name = entry
        var email: String?
        if entry.contains("@"), !entry.contains(" ") {
            email = entry.lowercased()
            name = String(entry.prefix(while: { $0 != "@" }))
        }
        // Re-adding someone already on the roster just updates their email.
        if let i = prep.speakers.firstIndex(where: { norm($0.name) == norm(name) }) {
            if let email {
                var copy = prep.speakers
                copy[i].email = email
                prep.speakers = copy
            }
            return
        }
        prep.speakers.append(PlannedSpeaker(name: name, email: email))
    }

    // MARK: - Talking points

    private func notesSection(_ prep: MeetingPrep) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Talking points")
            Text("Added to your notes when the recording starts.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            TextEditor(text: Binding(
                get: { prep.isAlive ? prep.prepNotes : "" },
                set: { if prep.isAlive { prep.prepNotes = $0 } }
            ))
            .font(.system(.body))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 70)
        }
        .oatCard()
    }

    // MARK: - Brief sections

    private func lastTimeSection(_ prior: Meeting) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Last time (\(prior.date.formatted(date: .abbreviated, time: .omitted)))")
            if let summary = prior.liveSummary, !summary.text.isEmpty {
                MarkdownView(markdown: String(summary.text.prefix(600)))
            } else {
                Text("No summary recorded.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Button { savePrep(); dismiss(); onOpenMeeting(prior) } label: {
                Label("Open last meeting", systemImage: "arrow.up.right.square").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
        .oatCard()
    }

    private var openItemsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Open commitments (\(openItems.count))")
            ForEach(openItems.prefix(8)) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle").font(.caption).foregroundStyle(Theme.textTertiary).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.text).font(.system(.subheadline))
                        if let owner = item.owner, !owner.isEmpty {
                            Text(owner).font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .oatCard()
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Previously with these people")
            ForEach(relatedByPeople.prefix(5)) { m in
                Button { savePrep(); dismiss(); onOpenMeeting(m) } label: {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.title).font(.system(.subheadline)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text(m.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .oatCard()
    }
}
