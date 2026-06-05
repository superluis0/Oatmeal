import Foundation

struct EnhancementResult: Sendable {
    var markdown: String
    var blocks: [NoteBlock]
}

/// Rewrites the user's sparse raw notes into clean, structured Markdown, using
/// the transcript as ground truth, via the local LM Studio server. Returns both
/// the flat Markdown and provenance-tagged blocks (user vs AI).
struct NoteEnhancementService {
    private let client = LMStudioClient()

    func enhance(rawNotes: String, transcript: String, template: NoteTemplate, identity: String = "") async throws -> EnhancementResult {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return EnhancementResult(markdown: rawNotes, blocks: blocks(fromUserText: rawNotes))
        }

        let identityBlock = identity.isEmpty ? "" : "\n\(identity)\n"
        let system = """
        You are an expert meeting-notes assistant. \(template.systemPrompt)
        You are given the user's own rough notes and the full meeting transcript.
        Rewrite the notes into clean, well-structured GitHub-flavored Markdown.
        \(identityBlock)
        Rules:
        - Preserve the user's intent and any points they emphasized.
        - Use the transcript only to fill in, correct, and add factual detail — never invent facts not supported by the transcript or notes.
        - Be specific and information-dense: capture concrete decisions, figures, dates, named owners, and open questions rather than vague summaries. Attribute points to who said them when it matters.
        - Follow this section structure (omit a section only if there is genuinely nothing for it):
        \(template.skeleton)
        - Use concise bullet points. Output ONLY the Markdown, with no preamble or commentary.
        """

        let user = """
        USER'S RAW NOTES:
        \(rawNotes.isEmpty ? "(none — derive notes from the transcript)" : rawNotes)

        MEETING TRANSCRIPT (speaker-labeled):
        \(truncateTranscript(trimmedTranscript))
        """

        let content = try await client.chat(
            messages: [.system(system), .user(user)],
            temperature: 0.4
        )
        let markdown = stripCodeFence(content.trimmingCharacters(in: .whitespacesAndNewlines))
        return EnhancementResult(markdown: markdown, blocks: blocks(fromAIMarkdown: markdown, rawNotes: rawNotes))
    }

    // MARK: - Provenance

    /// Splits AI Markdown into paragraph blocks; a block that closely matches a
    /// user note line is marked as user-owned, the rest as AI.
    private func blocks(fromAIMarkdown markdown: String, rawNotes: String) -> [NoteBlock] {
        let userLines = rawNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        return markdown
            .components(separatedBy: "\n")
            .map { line -> NoteBlock in
                let normalized = line.trimmingCharacters(in: .whitespaces).lowercased()
                let isUser = !normalized.isEmpty && userLines.contains { normalized.contains($0) || $0.contains(normalized) }
                return NoteBlock(text: line, isAI: !isUser)
            }
    }

    private func blocks(fromUserText text: String) -> [NoteBlock] {
        text.components(separatedBy: "\n").map { NoteBlock(text: $0, isAI: false) }
    }

    /// Some models wrap Markdown in a ```markdown fence; remove it.
    private func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
