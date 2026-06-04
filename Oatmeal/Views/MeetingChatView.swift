import SwiftUI
import SwiftData

struct MeetingChatView: View {
    @Bindable var meeting: Meeting
    @Environment(\.modelContext) private var context

    @State private var input = ""
    @State private var isSending = false
    @State private var errorText: String?

    private let suggestions = [
        "Summarize the action items",
        "What did we decide?",
        "What were the main topics?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if meeting.chatMessages.isEmpty {
                            emptyState
                        }
                        ForEach(meeting.orderedChatMessages) { msg in
                            ChatBubble(role: msg.role, text: msg.text)
                                .id(msg.persistentModelID)
                        }
                        if isSending {
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
                .buttonStyle(.bordered)
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

        do {
            let answer = try await ChatService().answerGrounded(
                question: question,
                groundedContext: grounded,
                history: history
            )
            // The meeting may have been deleted during the await.
            guard meeting.modelContext != nil else { return }
            let reply = ChatMessage(role: "assistant", text: answer)
            context.insert(reply)
            reply.meeting = meeting
            SafeStore.save(context, "chat:assistant")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct ChatBubble: View {
    let role: String
    let text: String

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
            Group {
                if isUser {
                    Text(text)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, Theme.Space.sm)
                        .padding(.vertical, Theme.Space.xs)
                        .background(Theme.accentGradient,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                } else {
                    MarkdownView(markdown: text)
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
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 48) }
        }
    }
}
