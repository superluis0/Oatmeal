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
        You quietly help ME in a live conversation by feeding me what to say next.
        Every word you write is going to come straight out of MY mouth, so it has to
        sound like a real person talking, not like an AI or a written essay.

        How to sound:
        - Plain, natural, spoken English. Use contractions (I'm, we've, that's, don't).
        - Sound like me thinking on my feet: warm, direct, confident, a little casual.
        - Short, punchy sentences. Say it the way I'd actually say it out loud.
        - NEVER use an em dash or en dash. Use a comma, a period, or a word like "and"
          or "so" instead.
        - No corporate or AI filler. Don't use words like delve, leverage, robust,
          furthermore, moreover, "it's worth noting", "in today's world", "as an AI".
        - Don't flatter or preface. Skip "Great question" and "That's a good point".
          Just say the thing.

        Respond with ONLY a JSON object, no prose:
        {
          "answer": "<2-4 sentences I can say out loud right now, first person>",
          "talking_points": ["<a short thing I could mention>", "..."],
          "follow_ups": ["<a natural question I could ask next>", "..."]
        }
        If they asked something, answer THAT directly, grounded in my background. Keep
        every string short and speakable. At most 3 items per list. Use [] for a list
        that doesn't apply.
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
        let answer = clean((obj?["answer"] as? String) ?? fallbackAnswer(content))
        let points = stringArray(obj?["talking_points"]).map(clean).filter { !$0.isEmpty }
        let follows = stringArray(obj?["follow_ups"] ?? obj?["followups"]).map(clean).filter { !$0.isEmpty }
        return LiveSuggestion(question: question, answer: answer, talkingPoints: points, followUps: follows)
    }

    /// Make a model string sound spoken. The user never wants em/en dashes (they
    /// read as "written by an AI"), so swap any dash-as-punctuation for a comma and
    /// tidy the spacing it leaves behind. Belt-and-suspenders to the prompt rule.
    private func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for dash in ["—", "–", "―", "‐", "‑", "‒", "−", "--"] {
            t = t.replacingOccurrences(of: " \(dash) ", with: ", ")
            t = t.replacingOccurrences(of: dash, with: ", ")
        }
        // Tidy artifacts the swap can create.
        while t.contains(", ,") { t = t.replacingOccurrences(of: ", ,", with: ", ") }
        t = t.replacingOccurrences(of: " ,", with: ",")
        t = t.replacingOccurrences(of: ",,", with: ",")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix(",") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return t
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
