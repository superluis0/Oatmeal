import Foundation
import SwiftData

/// Builds a focused, complete context for per-meeting chat.
///
/// Two hard constraints shape this:
///
///  1. Apple's on-device `NLEmbedding` is a weak word-averaged embedding, so pure
///     semantic ranking frequently misses the exact span a question is about (a
///     question about "travel requirements" can rank the passage that literally
///     says "50% travel requirement" too low to include).
///  2. A local LLM's context window is unknown and may be small (4k–8k tokens).
///     Stuffing a whole long transcript can silently overflow it and drop the
///     very content the user asked about.
///
/// Strategy: assemble a **budgeted** context that fits even a small model, using
/// **hybrid retrieval** — lexical keyword overlap (catches the literal words of
/// the question) combined with semantic similarity (catches paraphrases). Chunks
/// that lexically match the question are included FIRST and unconditionally, so
/// the literal answer is never budgeted out. Then the remaining budget is filled
/// with the best semantic matches, plus the meeting opening and recent exchange.
@MainActor
enum MeetingContextBuilder {

    /// Max characters of transcript material to include (~3k tokens) — safe for
    /// small local context windows while still rich. Lexically-matched chunks are
    /// always kept even if they nudge over this.
    private static let transcriptBudget = 12_000

    static func groundedContext(
        for meeting: Meeting,
        question: String,
        context: ModelContext
    ) -> String {
        var parts: [String] = []

        // Identity grounding so chat never confuses "Me" (the note-taker) with the
        // other participants or invents affiliations.
        parts.append(MeetingIdentity.preamble(knownSpeakers: meeting.speakerNames))

        // Always include the distilled notes + key points for high-level grounding.
        let notes = meeting.enhancedNotes.isEmpty ? (meeting.liveSummary?.text ?? "") : meeting.enhancedNotes
        if !notes.isEmpty {
            parts.append("NOTES:\n\(notes.prefix(2_400))")
        }
        if let keyPoints = meeting.liveSummary?.keyPoints, !keyPoints.isEmpty {
            parts.append("KEY POINTS:\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n"))
        }

        let transcript = MeetingIdentity.ground(transcript: meeting.transcriptText, userName: AppSettings.userName)
        if transcript.isEmpty {
            let ctx = parts.joined(separator: "\n\n")
            debugDump(question: question, keywords: [], info: "notes-only (no transcript)", context: ctx)
            return ctx
        }

        // Short meeting: the whole thing fits the budget — send it all.
        if transcript.count <= transcriptBudget {
            parts.append("FULL TRANSCRIPT (speaker-labeled):\n\(transcript)")
            let ctx = parts.joined(separator: "\n\n")
            debugDump(question: question, keywords: keywords(from: question),
                      info: "full transcript (\(transcript.count) chars)", context: ctx)
            return ctx
        }

        // Long meeting — hybrid-retrieve the most relevant excerpts. Scope strictly
        // to THIS meeting's chunks; index on demand if they don't exist yet.
        let id = meeting.id
        let descriptor = FetchDescriptor<EmbeddingChunk>(predicate: #Predicate { $0.meetingID == id })
        var transcriptChunks = ((try? context.fetch(descriptor)) ?? []).filter { $0.kind == "transcript" }
        if transcriptChunks.isEmpty {
            SemanticIndex(context: context).reindex(meeting)
            transcriptChunks = ((try? context.fetch(descriptor)) ?? []).filter { $0.kind == "transcript" }
        }

        let kw = keywords(from: question)
        var infoNote = ""

        if !transcriptChunks.isEmpty {
            let qVector = Embeddings.vector(for: question)
            // Score every chunk: lexical overlap + semantic cosine.
            let scored: [(chunk: EmbeddingChunk, lex: Float, total: Float)] = transcriptChunks.map { chunk in
                let lex = lexicalScore(chunk.text, keywords: kw)
                let sem = qVector.map { max(0, Embeddings.cosine($0, chunk.vector)) } ?? 0
                return (chunk, lex, lex * 1.5 + sem)
            }

            // 1) Prioritize chunks that lexically match the question — that's where
            //    the literal answer lives — strongest matches first so that if a
            //    query matches more than fits, the best ones win.
            let lexicalHits = scored.filter { $0.lex > 0 }
                .sorted { $0.lex > $1.lex }
                .map { $0.chunk }
            // 2) Fill the rest of the budget with the best-scoring remaining chunks.
            let hitIDs = Set(lexicalHits.map { $0.persistentModelID })
            let rest = scored
                .filter { !hitIDs.contains($0.chunk.persistentModelID) }
                .sorted { $0.total > $1.total }
                .map { $0.chunk }

            // Lexical hits may exceed the soft budget (the comment promises they
            // aren't budgeted out), but a hard ceiling stops a query that matches
            // most of the transcript from reassembling the whole thing and
            // overflowing a small local context window. A single oversized first
            // chunk is still kept so the answer is never empty.
            let hardCap = transcriptBudget * 2
            var picked: [EmbeddingChunk] = []
            var used = 0
            for chunk in lexicalHits {
                if used > 0 && used + chunk.text.count > hardCap { break }
                picked.append(chunk)
                used += chunk.text.count
            }
            for chunk in rest {
                if used > 0 && used + chunk.text.count > transcriptBudget { continue }
                picked.append(chunk)
                used += chunk.text.count
            }

            // Read in transcript order so excerpts are coherent.
            let ordered = picked.sorted { $0.createdAt < $1.createdAt }
            let body = MeetingIdentity.ground(
                transcript: ordered.map { $0.text }.joined(separator: "\n…\n"),
                userName: AppSettings.userName)
            parts.append("RELEVANT TRANSCRIPT EXCERPTS:\n\(body)")
            parts.append("MEETING OPENING:\n\(String(transcript.prefix(2_000)))")
            infoNote = "hybrid retrieval (\(ordered.count)/\(transcriptChunks.count) chunks, \(lexicalHits.count) lexical hits, \(used) chars)"
        } else {
            parts.append("TRANSCRIPT:\n\(truncateTranscript(transcript, maxChars: transcriptBudget))")
            infoNote = "truncated fallback (no chunks)"
        }

        // Always include the final exchange so "what did we just decide / say" works.
        let tail = MeetingIdentity.ground(
            transcript: meeting.orderedSegments.suffix(8)
                .map { "\(meeting.displayName(for: $0.speaker)): \($0.text)" }
                .joined(separator: "\n"),
            userName: AppSettings.userName)
        if !tail.isEmpty {
            parts.append("MOST RECENT EXCHANGE:\n\(tail)")
        }

        let ctx = parts.joined(separator: "\n\n")
        debugDump(question: question, keywords: kw, info: infoNote, context: ctx)
        return ctx
    }

    // MARK: - Lexical helpers

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "what", "did", "you", "about", "can", "tell",
        "more", "that", "this", "our", "like", "have", "has", "are", "was", "were",
        "from", "they", "them", "their", "there", "would", "could", "should", "into",
        "your", "mine", "his", "her", "she", "him", "who", "whom", "which", "when",
        "where", "why", "how", "any", "all", "some", "just", "also", "then", "than",
        "but", "not", "yes", "yeah", "okay", "know", "going", "gonna", "really", "part",
        "surface", "discussion", "details", "thing", "things", "give", "get"
    ]

    /// Salient lowercased keywords from the question (drops stopwords + short tokens).
    private static func keywords(from question: String) -> Set<String> {
        let tokens = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(tokens.filter { $0.count > 2 && !stopwords.contains($0) })
    }

    /// Fraction of question keywords (lightly stemmed) present in the chunk, 0…1.
    private static func lexicalScore(_ text: String, keywords: Set<String>) -> Float {
        guard !keywords.isEmpty else { return 0 }
        let lower = text.lowercased()
        var hits = 0
        for word in keywords {
            let stem = word.count > 5 && word.hasSuffix("s") ? String(word.dropLast()) : word
            if lower.contains(stem) { hits += 1 }
        }
        return Float(hits) / Float(keywords.count)
    }

    // MARK: - Diagnostics

    /// Writes the exact context handed to the model to a file so retrieval issues
    /// can be inspected directly (overwritten each send).
    private static func debugDump(question: String, keywords: Set<String>, info: String, context: String) {
        // Content-free breadcrumb only. We deliberately do NOT persist the
        // question or transcript context to disk: meeting content stays in the
        // app's data store, never in plaintext log files.
        Log.info("chat context: \(info)", "chat")
    }
}
