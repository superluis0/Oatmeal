import Foundation

/// Turns the LLM's raw `[#abcd Title]` / `[#abcd]` citation tokens into clean,
/// tappable Markdown links pointing at the real meeting — so users never see the
/// raw `[#7ba6 Test Meeting]` form, just the meeting's proper title as a link.
enum MeetingCitations {
    /// Custom URL scheme used for in-app meeting links: `oatmeal://meeting/<uuid>`.
    static let scheme = "oatmeal"
    static let host = "meeting"

    /// Number of leading UUID hex chars used as a citation tag. 8 keeps collisions
    /// negligible (vs. ~7% at 4 over a 15-meeting digest).
    static let tagLength = 8

    /// Build a tag → UUID/title map for the given meetings (8-char lowercased id prefix).
    static func tagMap(_ meetings: [Meeting]) -> [String: (id: UUID, title: String)] {
        var map: [String: (id: UUID, title: String)] = [:]
        var collisions: Set<String> = []
        for m in meetings {
            let tag = String(m.id.uuidString.prefix(tagLength)).lowercased()
            if map[tag] != nil { collisions.insert(tag) } else { map[tag] = (m.id, m.title) }
        }
        // Drop ambiguous prefixes so a citation never resolves to the WRONG meeting
        // (it just won't linkify). 4-hex prefixes can collide across many meetings.
        for tag in collisions { map.removeValue(forKey: tag) }
        return map
    }

    /// The link URL for a meeting.
    static func url(for id: UUID) -> URL {
        URL(string: "\(scheme)://\(host)/\(id.uuidString)")!
    }

    /// Parse a meeting UUID back out of an `oatmeal://meeting/<uuid>` URL.
    static func meetingID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let last = url.lastPathComponent
        return UUID(uuidString: last)
    }

    /// Rewrite all `[#abcd …]` citation tokens in `text` into Markdown links
    /// (`[Real Title](oatmeal://meeting/<uuid>)`). The title always comes from the
    /// live meeting record, so a stale or wrong title from the model is corrected.
    /// Unknown tags are softened to their inline title text (brackets dropped).
    static func rewrite(_ text: String, meetings: [Meeting]) -> String {
        let map = tagMap(meetings)
        guard !map.isEmpty else { return text }

        // Matches [#abcd1234] or [#abcd1234 Some Title]  — tag is 4–8 letters/digits.
        let pattern = "\\[#([0-9A-Za-z]{4,8})(?:\\s+([^\\]]*))?\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length

            let tag = ns.substring(with: match.range(at: 1)).lowercased()
            let inlineTitle: String? = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                : nil

            if let entry = map[tag] {
                let title = escape(entry.title)
                result += "[\(title)](\(url(for: entry.id).absoluteString))"
            } else if let inlineTitle, !inlineTitle.isEmpty {
                result += escape(inlineTitle)
            }
            // Unknown bare tag → drop it entirely (no dangling [#abcd]).
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Escape characters that would break a Markdown link label.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "(")
         .replacingOccurrences(of: "]", with: ")")
    }
}
