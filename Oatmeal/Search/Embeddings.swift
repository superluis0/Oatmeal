import Foundation
import NaturalLanguage

/// Shared on-device sentence embeddings + cosine similarity (Apple NaturalLanguage).
enum Embeddings {
    private static let sentence = NLEmbedding.sentenceEmbedding(for: .english)

    static var isAvailable: Bool { sentence != nil }

    static func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let e = sentence, let v = e.vector(for: trimmed) else { return nil }
        return v.map { Float($0) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
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
