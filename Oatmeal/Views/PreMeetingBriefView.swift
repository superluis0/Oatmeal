import SwiftUI
import SwiftData

/// A pre-meeting brief: before you walk into a meeting, surface what you already
/// know — the last time this meeting happened, open commitments, and your prior
/// history with the attendees. Assembled entirely from past meetings on-device.
struct PreMeetingBriefView: View {
    let upcoming: UpcomingMeeting
    var onJoinAndRecord: () -> Void
    var onOpenMeeting: (Meeting) -> Void
    @Query(sort: \Meeting.date, order: .reverse) private var pastMeetings: [Meeting]
    @Environment(\.dismiss) private var dismiss

    private func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var priorOccurrences: [Meeting] {
        let t = norm(upcoming.title)
        return pastMeetings.filter { $0.date < .now && norm($0.title) == t }
    }

    private var attendeeNames: Set<String> { Set(upcoming.attendees.map(norm)) }

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
                    if let prior = priorOccurrences.first { lastTimeSection(prior) }
                    if !openItems.isEmpty { openItemsSection }
                    if !relatedByPeople.isEmpty { historySection }
                    if priorOccurrences.isEmpty && openItems.isEmpty && relatedByPeople.isEmpty {
                        Text("No prior history with this meeting or these people yet — Oatmeal will build it as you record.")
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, Theme.Space.md)
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 580)
        .background(Theme.bg)
        .fontDesign(Appearance.shared.fontDesign)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(upcoming.title).font(.system(.title3).weight(.bold)).lineLimit(2)
                    Text(upcoming.start.formatted(date: .complete, time: .shortened))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if !upcoming.attendees.isEmpty {
                Label(upcoming.attendees.joined(separator: ", "), systemImage: "person.2")
                    .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Button {
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

    private func lastTimeSection(_ prior: Meeting) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Last time (\(prior.date.formatted(date: .abbreviated, time: .omitted)))")
            if let summary = prior.liveSummary, !summary.text.isEmpty {
                MarkdownView(markdown: String(summary.text.prefix(600)))
            } else {
                Text("No summary recorded.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Button { dismiss(); onOpenMeeting(prior) } label: {
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
                Button { dismiss(); onOpenMeeting(m) } label: {
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
