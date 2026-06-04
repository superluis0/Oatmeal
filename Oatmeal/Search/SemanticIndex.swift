import Foundation
import SwiftData
import NaturalLanguage

/// On-device semantic search over meeting notes + transcripts using Apple's
/// `NLEmbedding` sentence embeddings (fully offline, no model download).
@MainActor
struct SemanticIndex {
    let context: ModelContext
    private static let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    static var isAvailable: Bool { embedding != nil }

    func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let e = Self.embedding, let v = e.vector(for: trimmed) else { return nil }
        return v.map { Float($0) }
    }

    /// Rebuilds the embedding chunks for one meeting.
    func reindex(_ meeting: Meeting) {
        let id = meeting.id
        let existing = (try? context.fetch(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.meetingID == id }))) ?? []
        for c in existing { context.delete(c) }

        let notes = meeting.enhancedNotes.isEmpty ? meeting.notes : meeting.enhancedNotes
        for chunk in chunks(notes) {
            if let v = vector(for: chunk) {
                context.insert(EmbeddingChunk(meetingID: id, text: chunk, vector: v, kind: "notes"))
            }
        }
        for chunk in chunks(meeting.transcriptText) {
            if let v = vector(for: chunk) {
                context.insert(EmbeddingChunk(meetingID: id, text: chunk, vector: v, kind: "transcript"))
            }
        }
        try? context.save()
    }

    /// Indexes any meetings that have no chunks yet.
    func ensureIndexed(_ meetings: [Meeting]) {
        for m in meetings {
            let id = m.id
            let count = (try? context.fetchCount(FetchDescriptor<EmbeddingChunk>(
                predicate: #Predicate { $0.meetingID == id }))) ?? 0
            if count == 0 && (!m.transcriptText.isEmpty || !m.notes.isEmpty || !m.enhancedNotes.isEmpty) {
                reindex(m)
            }
        }
    }

    /// Meeting IDs ranked by best-matching chunk.
    func search(_ query: String, limit: Int = 30) -> [UUID] {
        guard let q = vector(for: query) else { return [] }
        let chunks = (try? context.fetch(FetchDescriptor<EmbeddingChunk>())) ?? []
        var best: [UUID: Float] = [:]
        for c in chunks {
            let score = cosine(q, c.vector)
            if score > (best[c.meetingID] ?? -1) { best[c.meetingID] = score }
        }
        return best.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    // MARK: - Helpers

    private func chunks(_ text: String, maxChars: Int = 400) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        for line in trimmed.components(separatedBy: "\n") {
            if current.count + line.count > maxChars, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
