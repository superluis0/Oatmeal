import Foundation

/// A Sendable snapshot of one meeting for cross-meeting synthesis.
struct DigestInput: Sendable {
    let id: String
    let title: String
    let date: String
    let notes: String
    let transcript: String
}

/// Synthesizes a digest across multiple meetings via the local LM Studio server.
struct DigestService {
    private let client = LMStudioClient()

    func digest(_ inputs: [DigestInput], scopeLabel: String, transcriptDepth: Int = 8) async throws -> String {
        guard !inputs.isEmpty else { return "No meetings in this scope yet." }

        var blocks: [String] = []
        for (i, m) in inputs.enumerated() {
            var block = "[#\(m.id) \(m.title)] (\(m.date))\nNotes: \(m.notes.prefix(700))"
            if i < transcriptDepth {
                block += "\nTranscript: \(truncateTranscript(m.transcript, maxChars: 2_500))"
            }
            blocks.append(block)
        }
        let context = blocks.joined(separator: "\n\n")

        let system = """
        You are an analyst summarizing a set of meetings (\(scopeLabel)). Produce a
        concise GitHub-flavored Markdown digest with these sections (omit a section
        only if genuinely empty):
        ## Themes
        ## Open Decisions
        ## Open Action Items
        ## Follow-ups
        ## Per-meeting
        Under "Per-meeting", give one line per meeting prefixed with its tag, e.g.
        "- [#abcd] <one-line takeaway>". Base everything ONLY on the context. Be brief.

        MEETINGS:
        \(context)
        """

        return try await client.chat(
            messages: [.system(system), .user("Write the digest.")],
            temperature: 0.3
        )
    }
}
