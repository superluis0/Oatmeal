import Foundation

struct ExtractedAction: Sendable {
    var text: String
    var owner: String?
    var dueDate: Date?
}

/// Extracts structured action items (task + owner + due date) from a meeting,
/// via the local LM Studio server. Due-date phrases are resolved on-device with
/// `NSDataDetector`.
struct ActionItemExtractor {
    private let client = LMStudioClient()

    func extract(transcript: String, notes: String) async -> [ExtractedAction] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let system = """
        You extract action items from a meeting transcript. Respond with ONLY a JSON
        array of objects, no prose:
        [{"task": "<concise imperative action>", "owner": "<person responsible, or empty>", "due": "<due-date phrase or empty, e.g. 'Friday', 'next week', 'June 10'>"}]
        Include only real commitments or tasks. If there are none, return [].
        """
        let user = """
        NOTES:
        \(notes.isEmpty ? "(none)" : notes)

        TRANSCRIPT (speaker-labeled):
        \(truncateTranscript(trimmed))
        """

        guard let content = try? await client.chat(
            messages: [.system(system), .user(user)], temperature: 0.2
        ) else { return [] }
        return parse(content)
    }

    // MARK: - Parsing

    private func parse(_ content: String) -> [ExtractedAction] {
        guard let json = extractArray(from: content),
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return arr.compactMap { obj in
            let task = ((obj["task"] as? String) ?? (obj["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            let owner = (obj["owner"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let duePhrase = (obj["due"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ExtractedAction(text: task, owner: owner, dueDate: duePhrase.flatMap(parseDate))
        }
    }

    private func extractArray(from content: String) -> String? {
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"), start < end else { return nil }
        return String(content[start...end])
    }

    private func parseDate(_ phrase: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(phrase.startIndex..., in: phrase)
        return detector?.firstMatch(in: phrase, options: [], range: range)?.date
    }
}
