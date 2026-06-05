import Foundation

struct MeetingSummary: Sendable {
    var text: String
    var actionItems: [String]
    var keyPoints: [String]
}

/// Summarizes a transcript via the local LM Studio server.
struct SummarizationService {
    private let client = LMStudioClient()

    func summarize(transcript: String, title: String? = nil, attendees: [String] = [], identity: String = "") async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MeetingSummary(text: "No speech was transcribed for this meeting.", actionItems: [], keyPoints: [])
        }

        // Long meetings: map-reduce so the middle of the conversation isn't lost
        // to truncation (the #1 cause of bland, start/end-only summaries).
        if trimmed.count > 14_000 {
            return try await summarizeLong(trimmed, title: title, attendees: attendees, identity: identity)
        }

        let user = "Meeting transcript (speaker-labeled):\n\n\(truncateTranscript(trimmed))"
        let content = try await client.chat(
            messages: [.system(systemPrompt(title: title, attendees: attendees, identity: identity)), .user(user)],
            temperature: 0.45
        )
        return parse(content)
    }

    // MARK: - Prompt

    private func systemPrompt(title: String?, attendees: [String], identity: String) -> String {
        var context = ""
        if let title, !title.isEmpty { context += "Meeting title: \(title)\n" }
        if !attendees.isEmpty {
            context += "Calendar attendees (the expected participants — this list may include the note-taker and people who never spoke; do not map these names to speakers): \(attendees.joined(separator: ", "))\n"
        }
        let identityBlock = identity.isEmpty ? "" : "\n\(identity)\n"
        return """
        You are an expert meeting-notes analyst. Write specific, information-dense notes
        that someone who missed the meeting could fully rely on.
        \(context.isEmpty ? "" : "\n\(context)")\(identityBlock)
        Respond with ONLY a JSON object of the form:
        {"summary": "<a substantive overview: what the meeting was about, the concrete \
        decisions reached, key numbers/dates/names, any disagreements, and what is still \
        open. Several specific sentences — never generic filler.>",
         "keyPoints": ["<specific takeaways: decisions, facts, figures, named owners — not vague themes>"],
         "actionItems": ["<concrete commitments, including the owner when stated>"]}
        Rules: ground every statement in the transcript; prefer specifics (names, numbers,
        dates, quotes) over generalities; never invent facts not present. Output only the JSON.
        """
    }

    // MARK: - Map-reduce for long transcripts

    private func summarizeLong(_ transcript: String, title: String?, attendees: [String], identity: String) async throws -> MeetingSummary {
        // Cover the WHOLE transcript in ≤8 ordered windows.
        let targetWindows = min(8, max(2, transcript.count / 6_000))
        let windowSize = Int((Double(transcript.count) / Double(targetWindows)).rounded(.up))
        let windows = chunk(transcript, maxChars: max(4_000, windowSize))

        var partials: [String] = []
        for (i, window) in windows.enumerated() {
            let sys = """
            Summarize part \(i + 1) of \(windows.count) of a meeting transcript into 3–6 dense
            bullet points capturing decisions, facts, numbers, named owners, and open questions.
            Be specific. Output ONLY the bullets.
            """
            if let c = try? await client.chat(messages: [.system(sys), .user(window)], temperature: 0.3) {
                partials.append("Part \(i + 1):\n\(c.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        guard !partials.isEmpty else {
            // Couldn't map — fall back to a single bounded pass.
            let user = "Meeting transcript (speaker-labeled):\n\n\(truncateTranscript(transcript))"
            let content = try await client.chat(
                messages: [.system(systemPrompt(title: title, attendees: attendees, identity: identity)), .user(user)],
                temperature: 0.45)
            return parse(content)
        }

        let combined = partials.joined(separator: "\n\n")
        let user = """
        Below are ordered partial notes covering the WHOLE meeting in sequence. Synthesize
        them into the final notes JSON, de-duplicating and keeping every specific detail:

        \(combined)
        """
        let content = try await client.chat(
            messages: [.system(systemPrompt(title: title, attendees: attendees, identity: identity)), .user(user)],
            temperature: 0.45)
        return parse(content)
    }

    /// Splits text into ~maxChars windows on line boundaries (transcript-ordered).
    private func chunk(_ text: String, maxChars: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count > maxChars, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Parsing

    private func parse(_ content: String) -> MeetingSummary {
        if let jsonString = extractJSON(from: content),
           let data = jsonString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let summary = (obj["summary"] as? String) ?? ""
            let actions = (obj["actionItems"] as? [String]) ?? (obj["action_items"] as? [String]) ?? []
            let points = (obj["keyPoints"] as? [String]) ?? (obj["key_points"] as? [String]) ?? []
            if !summary.isEmpty || !actions.isEmpty || !points.isEmpty {
                return MeetingSummary(text: summary, actionItems: actions, keyPoints: points)
            }
        }
        // Fallback: store raw content.
        return MeetingSummary(
            text: content.trimmingCharacters(in: .whitespacesAndNewlines),
            actionItems: [],
            keyPoints: []
        )
    }

    private func extractJSON(from content: String) -> String? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(content[start...end])
    }
}
