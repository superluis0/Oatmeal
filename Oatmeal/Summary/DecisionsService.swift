import Foundation

/// Extracts the concrete decisions made across a set of meetings — the highest-
/// value, most-easily-lost meeting artifact — each tagged with its source meeting
/// so it can link back. Reuses `DigestInput`.
struct DecisionsService {
    private let client = LMStudioClient()

    func decisions(_ inputs: [DigestInput], scopeLabel: String, transcriptDepth: Int = 8) async throws -> String {
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
        You extract DECISIONS from a set of meetings (\(scopeLabel)) — concrete
        conclusions, choices, commitments, and agreements that were actually reached
        (not open questions or todos). Respond with GitHub-flavored Markdown: a single
        bulleted list, most consequential first. Each bullet states the decision
        specifically (who/what/when when known) and ends with its source tag, e.g.
        "- We will ship the beta on June 20 to the design team first. [#abcd]"
        If a meeting recorded no real decisions, omit it. If there are none at all,
        say "No decisions recorded in this scope." Base everything ONLY on the context.

        MEETINGS:
        \(context)
        """

        return try await client.chat(
            messages: [.system(system), .user("List the decisions.")],
            temperature: 0.3
        )
    }
}
