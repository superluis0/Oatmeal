import Foundation

/// Answers questions about a finished meeting, grounded in its transcript and
/// enhanced notes, via the local LM Studio server.
struct ChatService {
    private let client = LMStudioClient()

    func answer(
        question: String,
        transcript: String,
        enhancedNotes: String,
        history: [(role: String, text: String)]
    ) async throws -> String {
        let system = """
        You are a helpful assistant answering questions about one specific meeting.
        Base your answers ONLY on the meeting context below. If the answer isn't in
        the context, say so plainly. Be concise and direct.

        ENHANCED NOTES:
        \(enhancedNotes.isEmpty ? "(none)" : enhancedNotes)

        TRANSCRIPT (speaker-labeled):
        \(truncateTranscript(transcript))
        """

        var messages: [LMStudioMessage] = [.system(system)]
        for turn in history {
            messages.append(.init(role: turn.role, content: turn.text))
        }
        messages.append(.user(question))

        return try await client.chat(messages: messages, temperature: 0.3)
    }

    /// Answers about one meeting using a pre-assembled, retrieval-grounded context
    /// (see `MeetingContextBuilder`) instead of a head/tail-truncated transcript.
    func answerGrounded(
        question: String,
        groundedContext: String,
        history: [(role: String, text: String)]
    ) async throws -> String {
        let messages = groundedMessages(question: question, groundedContext: groundedContext, history: history)
        return try await client.chat(messages: messages, temperature: 0.3)
    }

    /// Streaming variant of `answerGrounded`: delivers the reply token-by-token via
    /// `onToken` (on the main actor) so it feels instant, and falls back to a single
    /// blocking request on servers that don't support streaming — so chat works either
    /// way, and the fallback only fires when nothing was streamed (no double output).
    func answerGroundedStreaming(
        question: String,
        groundedContext: String,
        history: [(role: String, text: String)],
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let messages = groundedMessages(question: question, groundedContext: groundedContext, history: history)
        do {
            return try await client.chatStreaming(messages: messages, temperature: 0.3, onToken: onToken)
        } catch {
            let full = try await client.chat(messages: messages, temperature: 0.3)
            await onToken(full)
            return full
        }
    }

    private func groundedMessages(
        question: String,
        groundedContext: String,
        history: [(role: String, text: String)]
    ) -> [LMStudioMessage] {
        let system = """
        You are answering questions about ONE specific meeting. All of that
        meeting's material — its notes, key points, and transcript — is provided
        below. Read ALL of it carefully and thoroughly before answering.

        The transcript often describes a topic in different words than the
        question uses: a question about "travel requirements" may show up as
        talk of visas, flights, hotels, dates, or who's going; "budget" may be
        discussed as costs, pricing, or spend. Look for the underlying topic and
        synonyms, not just exact word matches, and reason over the whole
        transcript before concluding anything.

        Answer using this meeting's material and reasonable inferences drawn from
        it, quoting the speakers when useful. Only say a topic isn't covered if,
        after reading the entire transcript, it genuinely was not discussed —
        don't refuse just because the exact phrase is absent. Stay within THIS
        meeting: don't pull in other meetings or unrelated outside facts. Be
        concise and direct.

        MEETING CONTEXT:
        \(groundedContext)
        """

        var messages: [LMStudioMessage] = [.system(system)]
        for turn in history {
            messages.append(.init(role: turn.role, content: turn.text))
        }
        messages.append(.user(question))
        return messages
    }

    /// Answers across multiple meetings. `context` is a pre-assembled block where
    /// each meeting is tagged like `[#abcd Title]` so the model can cite sources.
    func answerAcrossMeetings(
        question: String,
        context: String,
        history: [(role: String, text: String)]
    ) async throws -> String {
        let system = """
        You answer questions across a user's meetings. Use ONLY the provided meeting
        context below. Each meeting is tagged like [#abcd Title]. When you use
        information from a meeting, cite it inline with its tag, e.g. [#abcd]. If the
        answer isn't in the context, say so plainly. Be concise.

        MEETINGS:
        \(context)
        """

        var messages: [LMStudioMessage] = [.system(system)]
        for turn in history {
            messages.append(.init(role: turn.role, content: turn.text))
        }
        messages.append(.user(question))

        return try await client.chat(messages: messages, temperature: 0.3)
    }
}
