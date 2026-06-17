import Foundation

/// Splits a recording into topic "chapters" (start time + short title + one-line
/// summary) for jump-to-moment navigation. On-device via the local LLM. The caller
/// passes a transcript whose lines are timestamped `[M:SS]`, captured up front so no
/// live SwiftData objects are read across the await.
struct ChapterService {
    private let client = LMStudioClient()

    func chapters(timestamped transcript: String) async throws -> [ChapterMark] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let system = """
        You split a meeting transcript into chapters by topic, for navigation. Each
        transcript line begins with its timestamp in [M:SS] (or [H:MM:SS]). Find where
        each distinct topic begins and output the chapters IN ORDER, covering the whole
        meeting. Output ONE chapter per line, EXACTLY this format and nothing else:

        [M:SS] Short title :: One concise sentence on what's covered

        Rules: use a timestamp that actually appears in the transcript (the moment the
        topic starts); 3–10 chapters depending on length; titles are 2–5 words; ground
        everything in the transcript; no preamble, no numbering, no blank lines.
        """
        let user = "Transcript:\n\n\(truncateTranscript(trimmed, maxChars: 20_000))"
        let content = try await client.chat(messages: [.system(system), .user(user)], temperature: 0.3)
        return parse(content)
    }

    private func parse(_ content: String) -> [ChapterMark] {
        var marks: [ChapterMark] = []
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let timeStr = String(line[line.index(after: line.startIndex)..<close])
            guard let seconds = Self.parseTimestamp(timeStr) else { continue }
            let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            var title = rest, summary = ""
            if let sep = rest.range(of: "::") {
                title = String(rest[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                summary = String(rest[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            guard !title.isEmpty else { continue }
            marks.append(ChapterMark(start: seconds, title: title, summary: summary))
        }
        return marks.sorted { $0.start < $1.start }
    }

    /// Parse "M:SS" or "H:MM:SS" into seconds.
    static func parseTimestamp(_ s: String) -> Double? {
        let nums = s.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        let v = nums.compactMap { $0 }
        switch v.count {
        case 2: return Double(v[0] * 60 + v[1])
        case 3: return Double(v[0] * 3600 + v[1] * 60 + v[2])
        default: return nil
        }
    }
}
