import SwiftUI
import SwiftData

/// A guided post-meeting "wrap up" ritual: review the summary, confirm/assign
/// action items, then send the recap — turning a finished recording into a
/// closed loop in three quick steps.
struct MeetingTriageView: View {
    @Bindable var meeting: Meeting
    /// Called when the user chooses to email the recap (parent closes this sheet
    /// and runs the email recipe).
    var onEmailRecap: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var step = 0
    @State private var quickAdd = ""
    /// Decided once on appear so confirming names mid-flow doesn't reshuffle steps.
    @State private var includeSpeakers: Bool? = nil
    @State private var player = AudioPlayer()

    enum TriageStep { case speakers, review, tasks, recap }

    /// The Speakers step leads only when auto-naming was unsure; otherwise the
    /// ritual is the original Review → Tasks → Recap.
    private var steps: [TriageStep] {
        var s: [TriageStep] = []
        if includeSpeakers ?? meeting.needsSpeakerConfirmation { s.append(.speakers) }
        s += [.review, .tasks, .recap]
        return s
    }

    var body: some View {
        Group {
            // If the meeting is deleted out from under this sheet, reading its own
            // attributes (e.g. `title` in the header) would trap — render nothing
            // and dismiss, matching MeetingDetailView's guard.
            if meeting.isDeleted || meeting.modelContext == nil {
                Color.clear.onAppear { dismiss() }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Theme.hairline)
                    ScrollView { content.padding(Theme.Space.lg) }
                    Divider().overlay(Theme.hairline)
                    footer
                }
            }
        }
        .frame(width: 580, height: 580)
        .background(Theme.bg)
        .fontDesign(Appearance.shared.fontDesign)
        .onAppear {
            if includeSpeakers == nil { includeSpeakers = meeting.needsSpeakerConfirmation }
            if let path = meeting.audioPath, FileManager.default.fileExists(atPath: path) {
                player.load(path: path)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Wrap up").font(.system(.title3).weight(.bold))
                Text(meeting.title).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Theme.accent : Theme.border)
                        .frame(width: i == step ? 22 : 8, height: 6)
                }
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(Theme.Space.md)
    }

    @ViewBuilder
    private var content: some View {
        switch steps[min(step, steps.count - 1)] {
        case .speakers: speakersStep
        case .review: reviewStep
        case .tasks: tasksStep
        case .recap: recapStep
        }
    }

    // MARK: Step 0 — Confirm speakers (only when auto-naming was unsure)

    /// Every detected non-self voice (named or not), so the user can fix a wrong
    /// auto-name as well as fill in the unnamed ones.
    private var confirmableLabels: [String] {
        Set(meeting.orderedSegments.map(\.speaker).filter { $0.hasPrefix("Speaker ") })
            .sorted { (Int($0.dropFirst(8)) ?? 0) < (Int($1.dropFirst(8)) ?? 0) }
    }

    private var speakersStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label("Who said what?", systemImage: "person.2.wave.2").font(.system(.headline))
            Text("We weren't sure about every voice. Confirm or fix the names — the summary updates as you go.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            ForEach(confirmableLabels, id: \.self) { label in
                VStack(alignment: .leading, spacing: 6) {
                    if let sample = sampleLine(for: label) {
                        HStack(alignment: .top, spacing: 8) {
                            if meeting.audioPath != nil {
                                Button { playSample(sample) } label: {
                                    Image(systemName: "play.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Hear this voice")
                            }
                            Text("“\(sample.text)”")
                                .font(.caption).italic()
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(3)
                        }
                    }
                    SpeakerRenameRow(
                        label: label,
                        currentName: meeting.displayName(for: label),
                        attendees: meeting.liveAttendees.filter { !$0.isSelf }.map(\.name),
                        mergeTargets: confirmableLabels.filter { $0 != label }
                            .map { (label: $0, name: meeting.displayName(for: $0)) },
                        onSetName: { renameSpeaker(label, to: $0) },
                        onMerge: { mergeSpeaker(label, into: $0) }
                    )
                }
                .padding(Theme.Space.sm)
                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }
        }
    }

    /// The most identifying line for a voice: its longest segment, earliest on a tie.
    private func sampleLine(for label: String) -> TranscriptSegment? {
        meeting.orderedSegments
            .filter { $0.speaker == label }
            .max { a, b in
                a.text.count != b.text.count ? a.text.count < b.text.count : a.start > b.start
            }
    }

    private func playSample(_ seg: TranscriptSegment) {
        guard let path = meeting.audioPath, FileManager.default.fileExists(atPath: path) else { return }
        player.load(path: path)
        player.seek(to: seg.start)
        player.play()
    }

    /// Cheap rename + summary sync (see `Meeting.setSpeakerName`), then persist.
    private func renameSpeaker(_ label: String, to newName: String) {
        meeting.setSpeakerName(newName, for: label)
        SafeStore.save(context, "confirm-speaker")
        SemanticIndex(context: context).reindex(meeting)
    }

    /// Structural merge (fixes over-splitting) — leaves the summary stale so the
    /// detail view's "Update summary" surfaces.
    private func mergeSpeaker(_ from: String, into target: String) {
        let fromName = meeting.displayName(for: from)
        let toName = meeting.displayName(for: target)
        for seg in meeting.orderedSegments where seg.speaker == from { seg.speaker = target }
        meeting.speakerNames[from] = nil
        meeting.relabelOwners(from: fromName, to: toName)
        SafeStore.save(context, "confirm-merge")
        SemanticIndex(context: context).reindex(meeting)
    }

    // MARK: Step 1 — Review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label("Does this summary look right?", systemImage: "doc.text")
                .font(.system(.headline))
            if !meeting.isDeleted, meeting.modelContext != nil, let summary = meeting.summary,
               !summary.isDeleted, summary.modelContext != nil, !summary.text.isEmpty {
                MarkdownView(markdown: summary.text)
                if !summary.keyPoints.isEmpty {
                    SectionLabel(text: "Key points")
                    ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, point in
                        Label(point, systemImage: "circle.fill")
                            .labelStyle(BulletLabelStyle())
                            .font(.system(.subheadline))
                    }
                }
            } else {
                Text("No summary was generated for this meeting.").foregroundStyle(Theme.textSecondary)
            }
            Text("You can edit the full notes anytime from the Enhanced tab.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Step 2 — Tasks

    private var tasksStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label("Confirm your action items", systemImage: "checklist")
                .font(.system(.headline))
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                TextField("Add a task…", text: $quickAdd).textFieldStyle(.plain).onSubmit(addTask)
                if !quickAdd.isEmpty { Button("Add", action: addTask).buttonStyle(OatSecondaryButton()) }
            }
            .padding(Theme.Space.sm)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))

            if meeting.liveActionItems.isEmpty {
                Text("No action items — add any above, or move on.").foregroundStyle(Theme.textSecondary)
            } else {
                let sorted = meeting.liveActionItems.sorted { $0.createdAt < $1.createdAt }
                VStack(spacing: 0) {
                    ForEach(sorted) { item in
                        ActionItemRow(item: item)
                        if item.persistentModelID != sorted.last?.persistentModelID {
                            Divider().overlay(Theme.hairline).padding(.leading, 36)
                        }
                    }
                }
                .oatCard(padding: Theme.Space.xs)
                Text("Use the ••• menu on each task to set a due date or assign an owner from attendees.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Step 3 — Recap

    private var recapStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label("Send the recap", systemImage: "paperplane")
                .font(.system(.headline))
            Text("Share a clean summary + action items with attendees, or copy it anywhere.")
                .foregroundStyle(Theme.textSecondary)

            Button {
                onEmailRecap()
            } label: {
                Label("Email recap to attendees", systemImage: "envelope").frame(maxWidth: .infinity)
            }
            .buttonStyle(OatPrimaryButton(fullWidth: true))
            .disabled(meeting.liveAttendees.compactMap(\.email).isEmpty)

            Button {
                MarkdownExporter.copyToPasteboard(meeting)
            } label: {
                Label("Copy as Markdown", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
            }
            .buttonStyle(OatSecondaryButton())

            Button {
                MarkdownExporter.exportToFile(meeting)
            } label: {
                Label("Export to file…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(OatSecondaryButton())

            if meeting.liveAttendees.compactMap(\.email).isEmpty {
                Text("No attendee emails on file — add them on the meeting to enable email recap.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }.buttonStyle(OatGhostButton())
            }
            Spacer()
            if step < steps.count - 1 {
                Button("Next") { withAnimation { step += 1 } }.buttonStyle(OatPrimaryButton())
            } else {
                Button("Done") { dismiss() }.buttonStyle(OatPrimaryButton())
            }
        }
        .padding(Theme.Space.md)
    }

    private func addTask() {
        let text = quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let item = ActionItem(text: text, dueDate: TaskDates.parse(text))
        context.insert(item)
        item.meeting = meeting
        try? context.save()
        quickAdd = ""
    }
}

/// Tiny accent bullet for key-point lists.
struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Theme.accent).padding(.top, 6)
            configuration.title
        }
    }
}
