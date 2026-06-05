import Foundation

/// Grounds AI prompts in WHO is speaking, so the model never confuses the
/// note-taker ("Me") with the other participants, and never invents people's
/// employers or job titles.
///
/// The transcript labels the recorder's own speech "Me" and everyone else
/// "Speaker 1", "Speaker 2", … On its own the model has no idea who "Me" is, so
/// given a calendar attendee list it will guess — and often guess wrong, then
/// fabricate affiliations on top. This supplies the missing facts and hard rules.
enum MeetingIdentity {

    /// A legend describing each speaker, for inclusion in a system prompt.
    /// `knownSpeakers` maps a transcript label (e.g. "Speaker 1") to a name the
    /// user has assigned; "Me" is handled via `userName`.
    static func legend(userName: String, userTagline: String, knownSpeakers: [String: String]) -> String {
        let me = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = userTagline.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []

        if me.isEmpty {
            lines.append("- The speaker labeled \"Me\" is the person who recorded this meeting (the note-taker).")
        } else {
            let suffix = tag.isEmpty ? "" : " (\(tag))"
            lines.append("- The speaker labeled \"Me\" is \(me)\(suffix) — the person who recorded this meeting and is writing these notes.")
        }

        for (label, name) in knownSpeakers.sorted(by: { $0.key < $1.key }) {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label != "Me", !n.isEmpty else { continue }
            lines.append("- \"\(label)\" is \(n).")
        }

        lines.append("- Any other speakers (\"Speaker 1\", \"Speaker 2\", …) are the other participants; their real names and affiliations are NOT known unless explicitly stated in the transcript.")

        return "SPEAKER IDENTITIES:\n" + lines.joined(separator: "\n")
    }

    /// Hard rules that stop identity hallucination. Append to any prompt that
    /// describes people.
    static let rules = """
    IDENTITY RULES (critical):
    - "Me" is the note-taker. Never describe "Me" as the other party, and never swap who said what.
    - Never invent or assign a person's employer, company, team, job title, or role unless it is explicitly stated in the transcript.
    - Never guess which attendee name corresponds to which speaker. The attendee list may include the note-taker and people who never spoke. Attribute statements only to "Me", to a name given in SPEAKER IDENTITIES, or to a name explicitly stated in the transcript — otherwise refer to people neutrally ("the other participant").
    """

    /// Rewrites a speaker-labeled transcript so the recorder's lines read as their
    /// actual name instead of the generic "Me", making attribution unambiguous.
    /// No-ops when the name is unknown.
    static func ground(transcript: String, userName: String) -> String {
        let me = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !me.isEmpty else { return transcript }
        return transcript
            .components(separatedBy: "\n")
            .map { line in line.hasPrefix("Me: ") ? "\(me): " + line.dropFirst(4) : line }
            .joined(separator: "\n")
    }

    /// Convenience: the full identity preamble (legend + rules) for the current
    /// user and a meeting's known speaker names.
    @MainActor
    static func preamble(knownSpeakers: [String: String]) -> String {
        legend(userName: AppSettings.userName,
               userTagline: AppSettings.userTagline,
               knownSpeakers: knownSpeakers) + "\n\n" + rules
    }
}
