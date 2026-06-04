import SwiftUI
import SwiftData

/// A cross-meeting Decisions Log — extracts the concrete decisions made across a
/// scope, with jump-to-meeting links.
struct DecisionsView: View {
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    var onOpenMeeting: (Meeting) -> Void

    enum Scope: String, CaseIterable, Identifiable {
        case thisWeek = "This week"
        case allTime = "All time"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .thisWeek
    @State private var decisions: String?
    @State private var generating = false
    @State private var error: String?

    private var scoped: [Meeting] {
        switch scope {
        case .thisWeek:
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            return meetings.filter { $0.date >= cutoff }
        case .allTime:
            return meetings
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: scope) { _, _ in decisions = nil }

                Button {
                    Task { await generate() }
                } label: {
                    if generating {
                        HStack { ProgressView().controlSize(.small); Text("Finding decisions…") }
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Find decisions", systemImage: "checkmark.seal").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(OatPrimaryButton(fullWidth: true))
                .disabled(generating || scoped.isEmpty)

                if let decisions {
                    GroupBox {
                        MarkdownView(markdown: MeetingCitations.rewrite(decisions, meetings: scoped))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } label: { Label("Decisions", systemImage: "checkmark.seal.fill") }
                } else if !generating {
                    OatEmptyState(
                        icon: "checkmark.seal",
                        title: "Decisions log",
                        message: "Pull the concrete decisions made across your meetings into one linked list."
                    )
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .environment(\.openURL, OpenURLAction { url in
            if let id = MeetingCitations.meetingID(from: url),
               let m = meetings.first(where: { $0.id == id }) {
                onOpenMeeting(m)
                return .handled
            }
            return .systemAction
        })
        .navigationTitle("Decisions")
        .alert("Couldn't extract decisions", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }

    private func generate() async {
        generating = true
        defer { generating = false }
        let inputs = scoped.prefix(15).map { m in
            DigestInput(
                id: String(m.id.uuidString.prefix(MeetingCitations.tagLength)).lowercased(),
                title: m.title,
                date: m.date.formatted(date: .abbreviated, time: .shortened),
                notes: m.enhancedNotes.isEmpty ? (m.summary?.text ?? m.notes) : m.enhancedNotes,
                transcript: m.transcriptText
            )
        }
        do {
            decisions = try await DecisionsService().decisions(Array(inputs), scopeLabel: scope.rawValue.lowercased())
        } catch {
            self.error = error.localizedDescription
        }
    }
}
