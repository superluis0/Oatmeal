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

    @Environment(\.modelContext) private var context
    @State private var scope: Scope = .thisWeek
    @State private var saved: SavedReport?
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
                .onChange(of: scope) { _, _ in loadSaved() }

                Button {
                    Task { await generate() }
                } label: {
                    if generating {
                        HStack { ProgressView().controlSize(.small); Text("Finding decisions…") }
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(saved == nil ? "Find decisions" : "Refresh decisions", systemImage: "checkmark.seal")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(OatPrimaryButton(fullWidth: true))
                .disabled(generating || scoped.isEmpty)

                if let saved {
                    reportCard(saved)
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
        .onAppear { loadSaved() }
        .alert("Couldn't extract decisions", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }

    private var currentScopeRaw: String { scope == .thisWeek ? "thisWeek" : "allTime" }

    private func loadSaved() {
        saved = ReportStore.fetch(kind: "decisions", scopeRaw: currentScopeRaw, context: context)
    }

    @ViewBuilder
    private func reportCard(_ report: SavedReport) -> some View {
        let covered = meetings.filter { report.coveredIDs.contains($0.id) }
        let stale = report.coveredIDs != Set(scoped.prefix(15).map(\.id))
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if stale {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Meetings changed since this was generated.")
                    Spacer()
                    Button("Refresh") { Task { await generate() } }.buttonStyle(.borderless)
                }
                .font(.caption).foregroundStyle(Theme.accent)
                .padding(8)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            GroupBox {
                MarkdownView(markdown: MeetingCitations.rewrite(report.markdown, meetings: covered))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } label: {
                HStack {
                    Label("Decisions", systemImage: "checkmark.seal.fill")
                    Spacer()
                    Text("Generated \(report.createdAt.formatted(.relative(presentation: .named))) · \(report.coveredIDs.count) meetings")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func generate() async {
        guard !generating else { return }
        generating = true
        defer { generating = false }
        let scopedMeetings = Array(scoped.prefix(15))
        let inputs = scopedMeetings.map { m in
            DigestInput(
                id: String(m.id.uuidString.prefix(MeetingCitations.tagLength)).lowercased(),
                title: m.title,
                date: m.date.formatted(date: .abbreviated, time: .shortened),
                notes: m.enhancedNotes.isEmpty ? (m.liveSummary?.text ?? m.notes) : m.enhancedNotes,
                transcript: m.transcriptText
            )
        }
        do {
            let markdown = try await DecisionsService().decisions(inputs, scopeLabel: scope.rawValue.lowercased())
            saved = ReportStore.upsert(kind: "decisions", scopeRaw: currentScopeRaw,
                                       markdown: markdown, meetingIDs: scopedMeetings.map(\.id), context: context)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
