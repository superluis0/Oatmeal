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

        let (context, omitted) = DigestInput.buildContext(inputs, transcriptDepth: transcriptDepth)

        let system = """
        You are an analyst summarizing a set of meetings (\(scopeLabel)). Produce a
        short GitHub-flavored Markdown narrative with these sections (omit a section
        only if genuinely empty):
        ## Highlights
        ## Decisions
        ## Follow-ups
        ## Per-meeting
        Do NOT list action items or todos — those are tracked separately. Focus on
        what happened, what was decided, and what to watch next. Under "Per-meeting",
        give one line per meeting prefixed with its tag, e.g.
        "- [#abcd] <one-line takeaway>". Base everything ONLY on the context. Be brief.

        MEETINGS:
        \(context)
        """

        let result = try await client.chat(
            messages: [.system(system), .user("Write the digest.")],
            temperature: 0.3
        )
        return DigestInput.trimNote(result, omitted: omitted)
    }
}

extension DigestInput {
    /// Builds the cross-meeting context, including WHOLE meetings only until a
    /// conservative character budget is hit — so a modest local model doesn't
    /// silently truncate the prompt mid-meeting and quietly drop content. Returns
    /// the joined context and how many meetings were left out. Shared by Digest +
    /// Decisions.
    static func buildContext(_ inputs: [DigestInput], transcriptDepth: Int, budget: Int = 24_000)
        -> (context: String, omitted: Int) {
        var included: [String] = []
        var used = 0
        for (i, m) in inputs.enumerated() {
            var block = "[#\(m.id) \(m.title)] (\(m.date))\nNotes: \(m.notes.prefix(700))"
            if i < transcriptDepth {
                block += "\nTranscript: \(truncateTranscript(m.transcript, maxChars: 2_500))"
            }
            if used + block.count > budget, !included.isEmpty { break }
            included.append(block)
            used += block.count + 2
        }
        return (included.joined(separator: "\n\n"), inputs.count - included.count)
    }

    /// Appends a visible note when meetings were dropped to fit the model's context,
    /// so an incomplete result never looks complete.
    static func trimNote(_ text: String, omitted: Int) -> String {
        guard omitted > 0 else { return text }
        return text + "\n\n---\n\n_\(omitted) older meeting\(omitted == 1 ? "" : "s") were left out to fit your model's context — narrow the scope for a fuller result._"
    }
}
