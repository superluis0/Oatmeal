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

    private let steps = ["Review", "Tasks", "Recap"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView { content.padding(Theme.Space.lg) }
            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 580, height: 580)
        .background(Theme.bg)
        .fontDesign(Appearance.shared.fontDesign)
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
        switch step {
        case 0: reviewStep
        case 1: tasksStep
        default: recapStep
        }
    }

    // MARK: Step 1 — Review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label("Does this summary look right?", systemImage: "doc.text")
                .font(.system(.headline))
            if meeting.modelContext != nil, let summary = meeting.summary,
               summary.modelContext != nil, !summary.text.isEmpty {
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

            if meeting.actionItems.isEmpty {
                Text("No action items — add any above, or move on.").foregroundStyle(Theme.textSecondary)
            } else {
                let sorted = meeting.actionItems.sorted { $0.createdAt < $1.createdAt }
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
            .disabled(meeting.attendees.compactMap(\.email).isEmpty)

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

            if meeting.attendees.compactMap(\.email).isEmpty {
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
