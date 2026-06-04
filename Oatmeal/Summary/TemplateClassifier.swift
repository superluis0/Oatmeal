import Foundation

/// Picks the best-fitting note template for a meeting via the local LLM.
struct TemplateClassifier {
    private let client = LMStudioClient()

    func pick(from names: [String], transcript: String) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, names.count > 1 else { return nil }

        let system = """
        You categorize meetings. Choose the single best-fitting note template name \
        for this meeting from the provided list. Reply with ONLY the exact template \
        name, nothing else.
        """
        let user = """
        Templates: \(names.joined(separator: ", "))

        Meeting transcript (excerpt):
        \(truncateTranscript(trimmed, maxChars: 4_000))
        """

        guard let raw = try? await client.chat(
            messages: [.system(system), .user(user)],
            temperature: 0
        ) else { return nil }

        let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.first { answer.localizedCaseInsensitiveContains($0) }
    }
}
