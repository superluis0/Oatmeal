import Foundation
import SwiftData

/// A Sendable snapshot of a transcript segment, safe to pass off the main actor.
struct SegmentRef: Sendable, Identifiable, Hashable {
    let id: PersistentIdentifier
    let speaker: String
    let text: String
    let start: Double
}

/// Grounds an AI note block in the transcript: finds the transcript segments
/// whose meaning best matches the note text, so users can audit AI edits and
/// jump to the supporting moment. Fully on-device via `Embeddings`.
enum NoteSourceMatcher {
    static var isAvailable: Bool { Embeddings.isAvailable }

    /// Top matching segments for a note block, strongest first. Returns [] when
    /// nothing clears the threshold (so headings/templated lines don't get
    /// spurious sources). Safe to call off the main actor.
    static func sources(
        for blockText: String,
        in segments: [SegmentRef],
        limit: Int = 3,
        threshold: Float = 0.45
    ) async -> [SegmentRef] {
        let clean = strippedMarkdown(blockText)
        guard clean.count >= 8, !segments.isEmpty else { return [] }

        // Embedding is synchronous CPU work — run it off the calling actor so a
        // large segment set doesn't jank the UI when called from the main actor.
        return await Task.detached(priority: .userInitiated) {
            guard let query = Embeddings.vector(for: clean) else { return [] }
            let scored: [(ref: SegmentRef, score: Float)] = segments.compactMap { ref in
                guard ref.text.count >= 4, let v = Embeddings.vector(for: ref.text) else { return nil }
                return (ref, Embeddings.cosine(query, v))
            }
            return scored
                .filter { $0.score >= threshold }
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .map { $0.ref }
        }.value
    }

    private static func strippedMarkdown(_ s: String) -> String {
        var t = s
        for token in ["#", "*", "_", "`", ">", "-"] {
            t = t.replacingOccurrences(of: token, with: " ")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
