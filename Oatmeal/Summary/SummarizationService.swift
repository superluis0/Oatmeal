import Foundation

struct MeetingSummary: Sendable {
    var text: String
    var actionItems: [String]
    var keyPoints: [String]
}

/// Summarizes a transcript via the local LM Studio server.
struct SummarizationService {
    private let client = LMStudioClient()
    // NB: deliberately NO max_tokens cap on the summary calls. Reasoning models
    // (Qwen3, etc.) spend reasoning tokens against the same completion budget, so a
    // cap that looks generous can be fully consumed by reasoning before any answer
    // is emitted — yielding an empty summary. Let the server default govern length;
    // the detailed prompt is what makes summaries longer.

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
        You are an expert meeting-notes analyst. Write thorough, specific, information-dense
        notes that someone who missed the entire meeting could rely on in place of having
        been there — not a terse blurb.
        \(context.isEmpty ? "" : "\n\(context)")\(identityBlock)
        Format your ENTIRE response EXACTLY like this — the three header lines verbatim, in
        this order, nothing before the first header, no JSON, no code fences:

        ===SUMMARY===
        <A well-structured GitHub-flavored Markdown summary whose depth scales to how much was
        actually discussed. Open with one or two sentences on what the meeting was about and the
        headline outcome. Then, for a substantive meeting, break the body into short thematic
        sections, each with a `## ` heading naming a topic actually discussed — covering what was
        discussed, the reasoning and any disagreement, the specific numbers / dates / names, and
        what was decided or left open. A short or low-content meeting stays short: two or three
        sentences, no headings. Never pad or invent structure that was not there.>

        ===KEY POINTS===
        - <the most important specific takeaways: decisions, facts, figures, named owners — not vague themes>

        ===ACTION ITEMS===
        - <a concrete commitment, including the owner and any due date when stated>

        Write naturally — quotes, apostrophes, and Markdown all belong in the SUMMARY section and
        need no escaping. If a section genuinely has nothing, leave it empty but keep its header.
        Rules: ground every statement in the transcript; prefer specifics (names, numbers, dates,
        short quotes) over generalities; never invent facts; don't repeat the same point across
        sections or restate the key points / action items verbatim inside the summary.
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
            Summarize part \(i + 1) of \(windows.count) of a meeting transcript into 4–8 dense
            bullet points. Capture the topics discussed, decisions, facts, numbers, named owners,
            disagreements, and open questions — keep every concrete detail and be specific.
            Output ONLY the bullets.
            """
            if let c = try? await client.chat(messages: [.system(sys), .user(window)], temperature: 0.3) {
                partials.append("Part \(i + 1):\n\(c.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        guard !partials.isEmpty else {
            // Couldn't map (e.g. the server dropped every window) — fall back to a
            // single bounded pass, and flag it if that truncated a long transcript so
            // the summary doesn't look complete when it isn't.
            let bounded = truncateTranscript(transcript)
            let user = "Meeting transcript (speaker-labeled):\n\n\(bounded)"
            let content = try await client.chat(
                messages: [.system(systemPrompt(title: title, attendees: attendees, identity: identity)), .user(user)],
                temperature: 0.45)
            var summary = parse(content)
            if bounded.count < transcript.count {
                summary.text += "\n\n_(This meeting was too long to summarize in full on the current model — these notes cover the start and end.)_"
            }
            return summary
        }

        let combined = partials.joined(separator: "\n\n")
        let user = """
        Below are ordered partial notes covering the WHOLE meeting in sequence. Synthesize
        them into the final notes using the exact ===SUMMARY=== / ===KEY POINTS=== /
        ===ACTION ITEMS=== format, organizing the summary into thematic sections as
        instructed, de-duplicating, and keeping every specific detail:

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
        let cleaned = stripCodeFence(content.trimmingCharacters(in: .whitespacesAndNewlines))
        // Preferred: the delimited ===SECTION=== format. It needs no escaping, so a
        // Markdown summary full of quotes/newlines round-trips intact — unlike JSON,
        // where one unescaped quote ("force multiplier") breaks the whole parse.
        if let summary = parseDelimited(cleaned) { return summary }
        // Back-compat: a model that still emitted a JSON object (older prompt). Try it
        // as-is, then with control chars inside strings escaped.
        if let raw = extractJSON(from: cleaned) {
            for candidate in [raw, escapeControlCharsInStrings(raw)] {
                if let summary = decode(candidate) { return summary }
            }
        }
        // Last resort: keep the model's prose as the summary rather than dropping it.
        return MeetingSummary(text: cleaned, actionItems: [], keyPoints: [])
    }

    /// Parses the delimited `===SUMMARY=== / ===KEY POINTS=== / ===ACTION ITEMS===`
    /// format. Tolerant of case and surrounding whitespace; returns nil when the
    /// SUMMARY marker is absent (so `parse` can fall through to the JSON path).
    private func parseDelimited(_ text: String) -> MeetingSummary? {
        func marker(_ name: String) -> Range<String.Index>? {
            text.range(of: "===\(name)===", options: .caseInsensitive)
        }
        guard let sumR = marker("SUMMARY") else { return nil }
        let kpR = marker("KEY POINTS")
        let aiR = marker("ACTION ITEMS")

        let afterSum = sumR.upperBound
        let sumEnd = [kpR?.lowerBound, aiR?.lowerBound]
            .compactMap { $0 }.filter { $0 >= afterSum }.min() ?? text.endIndex
        let summary = String(text[afterSum..<sumEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        var keyPoints: [String] = []
        if let kpR, kpR.upperBound >= afterSum {
            let kpEnd = aiR.map(\.lowerBound).flatMap { $0 >= kpR.upperBound ? $0 : nil } ?? text.endIndex
            keyPoints = bulletLines(in: String(text[kpR.upperBound..<kpEnd]))
        }
        var actionItems: [String] = []
        if let aiR {
            actionItems = bulletLines(in: String(text[aiR.upperBound...]))
        }
        guard !summary.isEmpty || !keyPoints.isEmpty || !actionItems.isEmpty else { return nil }
        return MeetingSummary(text: summary, actionItems: actionItems, keyPoints: keyPoints)
    }

    /// Pulls clean bullet strings out of a block, stripping `-`/`*`/`•` and `1.`
    /// markers and dropping blank lines.
    private func bulletLines(in block: String) -> [String] {
        block.components(separatedBy: "\n")
            .map { line -> String in
                var l = line.trimmingCharacters(in: .whitespaces)
                for p in ["- ", "* ", "• ", "– ", "— "] where l.hasPrefix(p) {
                    l = String(l.dropFirst(p.count)); break
                }
                if let r = l.range(of: "^[0-9]+[.)]\\s+", options: .regularExpression) {
                    l = String(l[r.upperBound...])
                }
                return l.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// Parses one JSON-object candidate into a summary, or nil if it isn't valid
    /// JSON or carries none of the expected fields.
    private func decode(_ jsonString: String) -> MeetingSummary? {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let summary = (obj["summary"] as? String) ?? ""
        let actions = (obj["actionItems"] as? [String]) ?? (obj["action_items"] as? [String]) ?? []
        let points = (obj["keyPoints"] as? [String]) ?? (obj["key_points"] as? [String]) ?? []
        guard !summary.isEmpty || !actions.isEmpty || !points.isEmpty else { return nil }
        return MeetingSummary(text: summary, actionItems: actions, keyPoints: points)
    }

    private func extractJSON(from content: String) -> String? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(content[start...end])
    }

    /// Escapes raw newlines / tabs that appear *inside* JSON string values — the
    /// usual reason a local model's otherwise-valid JSON fails to parse once the
    /// summary spans multiple lines. Walks the text tracking string context so
    /// structural whitespace between tokens is left untouched, and never
    /// double-escapes a character that was already escaped.
    private func escapeControlCharsInStrings(_ json: String) -> String {
        var out = ""
        out.reserveCapacity(json.count + 16)
        var inString = false
        var escaped = false
        for ch in json {
            if escaped {
                out.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\":
                out.append(ch)
                escaped = true
            case "\"":
                inString.toggle()
                out.append(ch)
            case "\n" where inString: out += "\\n"
            case "\r" where inString: out += "\\r"
            case "\t" where inString: out += "\\t"
            default:
                out.append(ch)
            }
        }
        return out
    }

    /// Some models wrap their JSON or Markdown in a ``` fence; strip it so the
    /// raw-content fallback doesn't render the fence.
    private func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
