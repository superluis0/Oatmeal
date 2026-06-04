import Foundation

/// LLM-based meeting coaching: sentiment/risk readout and opt-in sales framework
/// scoring (BANT / MEDDIC), via the local LM Studio server.
struct CoachingService {
    private let client = LMStudioClient()

    func coach(transcript: String, notes: String) async throws -> String {
        let system = """
        You are a meeting coach. Analyze the conversation and produce concise
        GitHub-flavored Markdown with these sections:
        ## Sentiment & Engagement
        ## Risks / Red Flags
        ## Coaching Suggestions
        Base everything ONLY on the provided content. 2–4 bullets per section.
        """
        let user = """
        NOTES:
        \(notes.isEmpty ? "(none)" : notes)

        TRANSCRIPT (speaker-labeled):
        \(truncateTranscript(transcript))
        """
        return try await client.chat(messages: [.system(system), .user(user)], temperature: 0.3)
    }

    /// `framework` is "BANT" or "MEDDIC".
    func score(framework: String, transcript: String, notes: String) async throws -> String {
        let components = framework == "MEDDIC"
            ? "Metrics, Economic buyer, Decision criteria, Decision process, Identify pain, Champion"
            : "Budget, Authority, Need, Timeline"
        let system = """
        You are a sales coach scoring a call against the \(framework) framework
        (\(components)). For EACH component output a line: "**<Component>**: <0–5> — <one-line justification grounded in the call>". Then a final "**Overall**: <0–5> — <summary>". Markdown only. Base everything ONLY on the provided content; if a component wasn't covered, score it low and say so.
        """
        let user = """
        NOTES:
        \(notes.isEmpty ? "(none)" : notes)

        TRANSCRIPT (speaker-labeled):
        \(truncateTranscript(transcript))
        """
        return try await client.chat(messages: [.system(system), .user(user)], temperature: 0.2)
    }
}
