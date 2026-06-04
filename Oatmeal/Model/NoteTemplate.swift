import Foundation

/// A note template = a name, a system prompt steering the model, and a Markdown
/// skeleton (headings) the enhanced notes should fill in. Static data, not stored
/// in SwiftData.
struct NoteTemplate: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let systemPrompt: String
    let skeleton: String

    static let builtins: [NoteTemplate] = [general, standup, oneOnOne, salesCall, interview]

    static func named(_ name: String?) -> NoteTemplate {
        builtins.first { $0.name == name } ?? general
    }

    static let general = NoteTemplate(
        name: "General",
        systemPrompt: "Produce clear, well-organized meeting notes for a general business meeting.",
        skeleton: """
        ## Overview
        ## Discussion
        ## Decisions
        ## Action Items
        """
    )

    static let standup = NoteTemplate(
        name: "Standup",
        systemPrompt: "Summarize a daily standup. Group updates per person where possible and surface blockers prominently.",
        skeleton: """
        ## Updates
        ## Blockers
        ## Action Items
        """
    )

    static let oneOnOne = NoteTemplate(
        name: "1:1",
        systemPrompt: "Summarize a 1:1 conversation. Capture topics discussed, feedback exchanged, and agreed next steps.",
        skeleton: """
        ## Topics
        ## Feedback
        ## Follow-ups
        """
    )

    static let salesCall = NoteTemplate(
        name: "Sales Call",
        systemPrompt: "Summarize a sales call. Capture the prospect's needs, objections, and next steps in the deal.",
        skeleton: """
        ## Prospect & Context
        ## Needs / Pain Points
        ## Objections
        ## Next Steps
        """
    )

    static let interview = NoteTemplate(
        name: "Interview",
        systemPrompt: "Summarize a candidate interview. Capture strengths, concerns, and a recommendation, grounded only in what was said.",
        skeleton: """
        ## Candidate
        ## Strengths
        ## Concerns
        ## Recommendation
        """
    )
}
