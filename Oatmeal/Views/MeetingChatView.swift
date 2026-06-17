import SwiftUI
import SwiftData

struct MeetingChatView: View {
    @Bindable var meeting: Meeting
    @Environment(\.modelContext) private var context

    @State private var input = ""
    @State private var isSending = false
    @State private var errorText: String?
    /// The in-flight assistant reply being streamed in (nil when not streaming),
    /// shown as a live bubble until it's persisted as a ChatMessage.
    @State private var streamingReply: String?
    @State private var showClearConfirm = false

    private let suggestions = [
        "Summarize the action items",
        "What did we decide?",
        "What were the main topics?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            if !meeting.chatMessages.isEmpty { chatHeader }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let msgs = meeting.orderedChatMessages
                        if msgs.isEmpty {
                            emptyState
                        }
                        ForEach(Array(msgs.enumerated()), id: \.element.persistentModelID) { idx, msg in
                            if idx == 0 || !Calendar.current.isDate(msg.createdAt, inSameDayAs: msgs[idx - 1].createdAt) {
                                ChatDateSeparator(date: msg.createdAt)
                            }
                            ChatBubble(role: msg.role, text: msg.text, timestamp: msg.createdAt)
                                .id(msg.persistentModelID)
                        }
                        if let streamingReply, !streamingReply.isEmpty {
                            ChatBubble(role: "assistant", text: streamingReply, streaming: true)
                                .id("streaming")
                        }
                        if isSending, (streamingReply?.isEmpty ?? true) {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: meeting.chatMessages.count) { _, _ in
                    if let last = meeting.orderedChatMessages.last {
                        withAnimation { proxy.scrollTo(last.persistentModelID, anchor: .bottom) }
                    }
                }
                .onChange(of: streamingReply) { _, reply in
                    if reply != nil { proxy.scrollTo("streaming", anchor: .bottom) }
                }
            }
            Divider()
            inputBar
        }
        .frame(minHeight: 420)
        .alert("Chat failed", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .confirmationDialog("Clear this conversation?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear chat", role: .destructive) { clearChat() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the chat history saved with this meeting. The meeting, transcript, and summary aren't affected.")
        }
    }

    /// A slim banner that appears once a conversation exists — it both signals the
    /// chat is saved with the meeting and carries the Clear control (parity with
    /// the global "Ask Oatmeal" chat).
    private var chatHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
            Text("Saved with this meeting")
            Spacer()
            Button("Clear") { showClearConfirm = true }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func clearChat() {
        guard meeting.modelContext != nil else { return }
        for m in meeting.chatMessages { context.delete(m) }
        SafeStore.save(context, "chat:clear")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask anything about this meeting.")
                .foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { s in
                Button {
                    input = s
                    Task { await send() }
                } label: {
                    Label(s, systemImage: "sparkle")
                }
                .buttonStyle(OatGhostButton())
                .disabled(meeting.segments.isEmpty)
            }
        }
        .padding(.bottom, 8)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about this meeting…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { Task { await send() } }
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isSending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    private func send() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        // Bail if this meeting was deleted out from under the chat — saving a
        // message linked to a missing row would otherwise raise an uncatchable
        // CoreData exception.
        guard meeting.modelContext != nil else {
            Log.warn("chat send aborted: meeting no longer in store", "chat")
            return
        }
        // The reply can take minutes on a slow local model. Capture the stable id so
        // we can re-fetch a fresh meeting after the await instead of mutating the
        // captured handle, which may have faulted out by then — saving a relationship
        // against a stale/faulted object traps uncatchably inside CoreData inverse-
        // relationship maintenance (see SafeStore's limitation note).
        let meetingID = meeting.id
        input = ""
        isSending = true
        defer { isSending = false }

        let history = meeting.orderedChatMessages.map { (role: $0.role, text: $0.text) }

        let userMsg = ChatMessage(role: "user", text: question)
        context.insert(userMsg)
        userMsg.meeting = meeting
        SafeStore.save(context, "chat:user")

        // Retrieve a question-relevant context (notes + best-matching transcript
        // excerpts + recent exchange) instead of a middle-dropping truncation.
        let grounded = MeetingContextBuilder.groundedContext(
            for: meeting, question: question, context: context)

        streamingReply = ""
        defer { streamingReply = nil }
        do {
            let answer = try await ChatService().answerGroundedStreaming(
                question: question,
                groundedContext: grounded,
                history: history,
                onToken: { piece in streamingReply = (streamingReply ?? "") + piece }
            )
            // Re-fetch the meeting fresh after the await rather than trusting the
            // captured handle; a nil result (deleted / unavailable) drops the reply
            // cleanly instead of crashing on a stale object.
            var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
            descriptor.fetchLimit = 1
            guard let liveMeeting = try? context.fetch(descriptor).first,
                  !liveMeeting.isDeleted, liveMeeting.modelContext != nil else {
                Log.warn("chat reply dropped: meeting unavailable after reply", "chat")
                return
            }
            let reply = ChatMessage(role: "assistant", text: answer)
            context.insert(reply)
            reply.meeting = liveMeeting
            SafeStore.save(context, "chat:assistant")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct ChatBubble: View {
    let role: String
    let text: String
    var streaming: Bool = false
    /// When set (and not streaming), a subtle time is shown under the bubble so a
    /// persisted conversation reads as dated history rather than a live scratchpad.
    var timestamp: Date? = nil

    private var isUser: Bool { role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            if isUser { Spacer(minLength: 48) }
            if !isUser {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accentSoft, in: Circle())
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                Group {
                    if isUser {
                        Text(text)
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, Theme.Space.sm)
                            .padding(.vertical, Theme.Space.xs)
                            .background(Theme.accentGradient,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                    } else {
                        Group {
                            if streaming {
                                // Plain text while streaming keeps it cheap — markdown
                                // re-parses the whole string on every token; the persisted
                                // message renders full markdown.
                                Text(text)
                            } else {
                                MarkdownView(markdown: text)
                            }
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.Space.sm)
                        .padding(.vertical, Theme.Space.xs)
                        .background(Theme.surface,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                    }
                }
                .font(.system(size: 13 * Appearance.shared.fontScale))
                .textSelection(.enabled)
                if let timestamp, !streaming {
                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 48) }
        }
    }
}

/// A centered date pill ("Today" / "Yesterday" / "Mon, Jun 10") inserted between
/// chat messages when the calendar day changes — the visual cue that a thread is
/// persisted, dated history rather than a single live session.
struct ChatDateSeparator: View {
    let date: Date

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month().day())
    }
}
