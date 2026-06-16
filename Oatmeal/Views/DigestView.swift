import SwiftUI
import SwiftData

/// Cross-meeting digest: themes, open decisions, action items, follow-ups —
/// scoped by time / folder / tag / person, with local trend stats.
struct DigestView: View {
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \Folder.createdAt) private var folders: [Folder]
    var onOpenMeeting: (Meeting) -> Void

    enum ScopeKind: String, CaseIterable, Identifiable {
        case thisWeek = "This week"
        case allTime = "All time"
        case folder = "Folder"
        case tag = "Tag"
        case person = "Person"
        var id: String { rawValue }
    }

    @State private var scopeKind: ScopeKind = .thisWeek
    @State private var folderName = ""
    @State private var tagName = ""
    @State private var personName = ""
    @State private var digest: String?
    @State private var generating = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                scopeControls
                statsPanel
                Button {
                    Task { await generate() }
                } label: {
                    if generating {
                        HStack { ProgressView().controlSize(.small); Text("Generating digest…") }
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Generate digest", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(OatPrimaryButton(fullWidth: true))
                .disabled(generating || scoped.isEmpty)

                if let digest {
                    GroupBox {
                        MarkdownView(markdown: MeetingCitations.rewrite(digest, meetings: scoped))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } label: { Label("Digest", systemImage: "doc.text.magnifyingglass") }
                    includedList
                } else if !generating {
                    OatEmptyState(
                        icon: "doc.text.magnifyingglass",
                        title: "Cross-meeting digest",
                        message: "Themes, open decisions, key action items, and follow-ups — synthesized across the meetings you've scoped above."
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
        .navigationTitle("Digest")
        .alert("Couldn't generate digest", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }

    // MARK: - Controls

    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Picker("Scope", selection: $scopeKind) {
                ForEach(ScopeKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: scopeKind) { _, _ in digest = nil }

            switch scopeKind {
            case .folder:
                Picker("Folder", selection: $folderName) {
                    Text("Choose…").tag("")
                    ForEach(folders) { Text($0.name).tag($0.name) }
                }
                .onChange(of: folderName) { _, _ in digest = nil }
            case .tag:
                Picker("Tag", selection: $tagName) {
                    Text("Choose…").tag("")
                    ForEach(allTags, id: \.self) { Text("#\($0)").tag($0) }
                }
                .onChange(of: tagName) { _, _ in digest = nil }
            case .person:
                Picker("Person", selection: $personName) {
                    Text("Choose…").tag("")
                    ForEach(allPeople, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: personName) { _, _ in digest = nil }
            default:
                EmptyView()
            }
        }
    }

    private var statsPanel: some View {
        let open = scoped.reduce(0) { $0 + $1.openActionItemCount }
        let done = scoped.reduce(0) { $0 + $1.doneActionItemCount }
        return HStack(spacing: Theme.Space.sm) {
            stat("\(scoped.count)", "meetings")
            stat("\(open)", "open tasks")
            stat("\(done)", "done")
            stat(completionLabel(open: open, done: done), "complete")
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

    private func completionLabel(open: Int, done: Int) -> String {
        let total = open + done
        guard total > 0 else { return "—" }
        return "\(Int(Double(done) / Double(total) * 100))%"
    }

    private var includedList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Meetings included")
            ForEach(scoped.prefix(15)) { m in
                Button { onOpenMeeting(m) } label: {
                    HStack {
                        Text("[#\(tag(m))]").font(.caption.monospaced()).foregroundStyle(Theme.accent)
                        Text(m.title).lineLimit(1)
                        Spacer()
                        Text(m.date, format: .dateTime.month().day()).foregroundStyle(Theme.textSecondary)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Scope data

    private var allTags: [String] {
        Array(Set(meetings.flatMap { $0.tags })).sorted()
    }
    private var allPeople: [String] {
        Array(Set(meetings.flatMap { $0.attendeeNames })).sorted()
    }

    private var scoped: [Meeting] {
        switch scopeKind {
        case .thisWeek:
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            return meetings.filter { $0.date >= cutoff }
        case .allTime:
            return meetings
        case .folder:
            return folderName.isEmpty ? [] : meetings.filter { $0.folder?.name == folderName }
        case .tag:
            return tagName.isEmpty ? [] : meetings.filter { $0.tags.contains(tagName) }
        case .person:
            return personName.isEmpty ? [] : meetings.filter { $0.attendeeNames.contains(personName) }
        }
    }

    private func tag(_ m: Meeting) -> String { String(m.id.uuidString.prefix(MeetingCitations.tagLength)).lowercased() }

    private var scopeLabel: String {
        switch scopeKind {
        case .thisWeek: return "this week"
        case .allTime: return "all meetings"
        case .folder: return "folder “\(folderName)”"
        case .tag: return "tag #\(tagName)"
        case .person: return "with \(personName)"
        }
    }

    private func generate() async {
        generating = true
        defer { generating = false }
        let inputs = scoped.prefix(15).map { m in
            DigestInput(
                id: tag(m),
                title: m.title,
                date: m.date.formatted(date: .abbreviated, time: .shortened),
                notes: m.enhancedNotes.isEmpty ? (m.liveSummary?.text ?? m.notes) : m.enhancedNotes,
                transcript: m.transcriptText
            )
        }
        do {
            digest = try await DigestService().digest(Array(inputs), scopeLabel: scopeLabel)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
