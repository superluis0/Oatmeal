import Foundation

/// One real-time assist card: a suggested answer, supporting talking points, and
/// smart follow-up questions to ask next. Ephemeral (not persisted in v1).
struct LiveSuggestion: Identifiable, Sendable {
    let id = UUID()
    var createdAt: Date = .now
    /// The detected question this responds to (nil when manually requested).
    var question: String?
    var answer: String
    var talkingPoints: [String]
    var followUps: [String]

    var isEmpty: Bool { answer.isEmpty && talkingPoints.isEmpty && followUps.isEmpty }
}

/// Generates private, on-device live suggestions during a recording via the local
/// LM Studio server. Prompts are deliberately short so a small/fast model can
/// answer in ~1–3s — fast enough to glance at mid-conversation.
struct LiveAssistService {
    private let client = LMStudioClient()

    func suggest(question: String?, recentTranscript: String, profile: String) async throws -> LiveSuggestion {
        let system = """
        You are a real-time assistant quietly helping ME during a live conversation
        (e.g. an interview or meeting). Be fast, specific, and concise. Respond with
        ONLY a JSON object, no prose:
        {
          "answer": "<a strong 2-4 sentence response I can say, first person>",
          "talking_points": ["<short supporting point>", "..."],
          "follow_ups": ["<a smart question I could ask next>", "..."]
        }
        If the other person asked a question, answer THAT directly, grounded in my
        background. Keep every string short. At most 3 items per list. Omit a list
        (use []) if it doesn't apply.
        """
        let user = """
        MY BACKGROUND:
        \(profile.isEmpty ? "(not provided)" : profile)

        \(question.map { "THEY JUST ASKED:\n\($0)\n" } ?? "")RECENT CONVERSATION:
        \(recentTranscript.isEmpty ? "(nothing yet)" : recentTranscript)
        """

        let content = try await client.chat(
            messages: [.system(system), .user(user)], temperature: 0.4
        )
        return parse(content, question: question)
    }

    // MARK: - Parsing

    private func parse(_ content: String, question: String?) -> LiveSuggestion {
        let obj = jsonObject(from: content)
        let answer = ((obj?["answer"] as? String) ?? fallbackAnswer(content))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let points = stringArray(obj?["talking_points"])
        let follows = stringArray(obj?["follow_ups"] ?? obj?["followups"])
        return LiveSuggestion(question: question, answer: answer, talkingPoints: points, followUps: follows)
    }

    /// If the model ignored the JSON instruction, surface its prose as the answer.
    private func fallbackAnswer(_ content: String) -> String {
        content.contains("{") ? "" : content
    }

    private func stringArray(_ value: Any?) -> [String] {
        guard let arr = value as? [Any] else { return [] }
        return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func jsonObject(from content: String) -> [String: Any]? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end else { return nil }
        let json = String(content[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
