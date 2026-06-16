import SwiftUI
import SwiftData

/// Chat across all meetings or a folder, with tappable source citations.
struct GlobalChatView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \Folder.createdAt) private var folders: [Folder]

    /// Called when the user taps a cited source.
    var onOpenMeeting: (Meeting) -> Void
    /// Optional question to prefill and auto-send on appear (e.g. from a Person page).
    var initialQuestion: String? = nil

    @State private var consumedInitial = false
    @State private var scope: Scope = .all
    @State private var session: ChatSession?
    @State private var input = ""
    @State private var isSending = false
    @State private var errorText: String?

    enum Scope: Hashable {
        case all
        case folder(String)

        var raw: String {
            switch self {
            case .all: return "all"
            case .folder(let n): return "folder:\(n)"
            }
        }
    }

    private let recentTranscriptCount = 20
    private let suggestions = ["What are my open action items?", "Summarize this week", "What did we decide about pricing?"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            inputBar
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
        .navigationTitle("Ask Oatmeal")
        .onAppear {
            loadSession()
            if let q = initialQuestion, !consumedInitial {
                consumedInitial = true
                input = q
                Task { await send() }
            }
        }
        .onChange(of: scope) { _, _ in loadSession() }
        .alert("Chat failed", isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private var header: some View {
        HStack {
            Picker("Scope", selection: $scope) {
                Text("All meetings").tag(Scope.all)
                ForEach(folders) { f in
                    Text(f.name).tag(Scope.folder(f.name))
                }
            }
            .frame(maxWidth: 240)
            Spacer()
            if let session, !session.messages.isEmpty {
                Button("Clear") { clearSession(session) }
            }
        }
        .padding()
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if (session?.messages.isEmpty ?? true) {
                        emptyState
                    }
                    ForEach(session?.orderedMessages ?? []) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            ChatBubble(role: msg.role,
                                       text: msg.role == "assistant"
                                            ? MeetingCitations.rewrite(msg.text, meetings: scopedMeetings())
                                            : msg.text)
                            if msg.role == "assistant" {
                                sourceChips(for: msg.text)
                            }
                        }
                        .id(msg.persistentModelID)
                    }
                    if isSending {
                        HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session?.messages.count) { _, _ in
                if let last = session?.orderedMessages.last {
                    withAnimation { proxy.scrollTo(last.persistentModelID, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask across \(scopeLabel).").foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { s in
                Button { input = s; Task { await send() } } label: {
                    Label(s, systemImage: "sparkle")
                }
                .buttonStyle(OatGhostButton())
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask across your meetings…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { Task { await send() } }
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.plain)
            .disabled(isSending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    // MARK: - Citations

    @ViewBuilder
    private func sourceChips(for text: String) -> some View {
        let map = currentTagMap()
        let tags = citedTags(in: text).filter { map[$0] != nil }
        if !tags.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                ForEach(tags, id: \.self) { tag in
                    if let m = map[tag] {
                        Button(m.title) { onOpenMeeting(m) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func citedTags(in text: String) -> [String] {
        var found: [String] = []
        var scan = Substring(text)
        while let hashIdx = scan.firstIndex(of: "#") {
            let after = scan[scan.index(after: hashIdx)...]
            // Grab the alphanumeric run after '#', capped at the tag length.
            let run = String(after.prefix { $0.isLetter || $0.isNumber }.prefix(MeetingCitations.tagLength))
            if run.count >= 4, !found.contains(run) {
                found.append(run)
            }
            scan = after
        }
        return found
    }

    // MARK: - Scope / context

    private var scopeLabel: String {
        switch scope {
        case .all: return "all meetings"
        case .folder(let n): return "“\(n)”"
        }
    }

    private func scopedMeetings() -> [Meeting] {
        switch scope {
        case .all: return meetings
        case .folder(let n): return meetings.filter { $0.folder?.name == n }
        }
    }

    private func currentTagMap() -> [String: Meeting] {
        var map: [String: Meeting] = [:]
        for m in scopedMeetings() { map[String(m.id.uuidString.prefix(MeetingCitations.tagLength)).lowercased()] = m }
        return map
    }

    private func buildContext() -> String {
        let sorted = scopedMeetings()
        var parts: [String] = []
        for (i, m) in sorted.enumerated() {
            let tag = String(m.id.uuidString.prefix(MeetingCitations.tagLength)).lowercased()
            let notes = m.enhancedNotes.isEmpty ? (m.liveSummary?.text ?? "") : m.enhancedNotes
            var block = "[#\(tag) \(m.title)] (\(m.date.formatted(date: .abbreviated, time: .shortened)))\nNotes: \(notes.prefix(800))"
            if i < recentTranscriptCount {
                block += "\nTranscript: \(truncateTranscript(m.transcriptText, maxChars: 3_000))"
            }
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Session

    private func loadSession() {
        let raw = scope.raw
        let descriptor = FetchDescriptor<ChatSession>(predicate: #Predicate { $0.scopeRaw == raw })
        if let existing = try? context.fetch(descriptor).first {
            session = existing
        } else {
            let s = ChatSession(scopeRaw: raw, title: scopeLabel)
            context.insert(s)
            try? context.save()
            session = s
        }
    }

    private func clearSession(_ s: ChatSession) {
        for m in s.messages { context.delete(m) }
        try? context.save()
    }

    private func send() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        if session == nil { loadSession() }
        guard let session else { return }
        input = ""
        isSending = true
        defer { isSending = false }

        guard session.modelContext != nil else { return }
        let history = session.orderedMessages.map { (role: $0.role, text: $0.text) }
        let userMsg = ChatMessage(role: "user", text: question)
        context.insert(userMsg)
        userMsg.session = session
        SafeStore.save(context, "globalchat:user")

        do {
            let answer = try await ChatService().answerAcrossMeetings(
                question: question,
                context: buildContext(),
                history: history
            )
            guard session.modelContext != nil else { return }
            let reply = ChatMessage(role: "assistant", text: answer)
            context.insert(reply)
            reply.session = session
            SafeStore.save(context, "globalchat:assistant")
        } catch {
            errorText = error.localizedDescription
        }
    }
}
