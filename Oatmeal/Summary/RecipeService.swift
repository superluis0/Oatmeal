import Foundation
import SwiftData

/// A reusable prompt ("recipe") run against a meeting's context.
struct RecipeItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let prompt: String
    var isEmail: Bool = false
}

enum RecipeProvider {
    static let builtins: [RecipeItem] = [
        RecipeItem(
            name: "Follow-up email",
            prompt: "Draft a concise, friendly follow-up email summarizing what was discussed and listing the agreed action items with owners. Put the subject on the first line prefixed exactly with 'Subject: '. Then a blank line, then the email body.",
            isEmail: true
        ),
        RecipeItem(
            name: "Thank-you note",
            prompt: "Draft a brief, warm, professional thank-you note to send after this meeting — well suited to following up after an interview. Reference one or two specific things that were actually discussed so it feels genuine, reaffirm interest and any next steps, and keep it to a few sentences. Put the subject on the first line prefixed exactly with 'Subject: '. Then a blank line, then the note.",
            isEmail: true
        ),
        RecipeItem(
            name: "Key decisions",
            prompt: "List the key decisions made in this meeting as concise bullet points. If none, say so."
        ),
        RecipeItem(
            name: "Action items by owner",
            prompt: "Extract all action items and group them by the person responsible. Use Markdown headings per owner with bullet points."
        )
    ]

    static func all(context: ModelContext) -> [RecipeItem] {
        let descriptor = FetchDescriptor<Recipe>(sortBy: [SortDescriptor(\.createdAt)])
        let customs = (try? context.fetch(descriptor)) ?? []
        return builtins + customs.map { RecipeItem(name: $0.name, prompt: $0.prompt) }
    }
}

/// Runs a recipe prompt against a meeting via the local LM Studio server.
struct RecipeService {
    private let client = LMStudioClient()

    func run(prompt: String, title: String, notes: String, transcript: String) async throws -> String {
        let system = """
        You produce outputs from a single meeting's notes and transcript. Follow the \
        user's instruction precisely and base everything ONLY on the provided context. \
        Output only the requested content, with no preamble.
        """
        let user = """
        INSTRUCTION:
        \(prompt)

        MEETING: \(title)

        NOTES:
        \(notes.isEmpty ? "(none)" : notes)

        TRANSCRIPT (speaker-labeled):
        \(truncateTranscript(transcript))
        """
        return try await client.chat(messages: [.system(system), .user(user)], temperature: 0.4)
    }
}
