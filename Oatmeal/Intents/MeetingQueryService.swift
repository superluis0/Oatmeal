import Foundation
import SwiftData

/// Headless read/answer layer over the meeting store, reused by App Intents (and,
/// later, the global quick-ask hotkey and the MCP server). No UI; everything runs
/// on-device — the only network call is to the user's own local LM Studio.
@MainActor
struct MeetingQueryService {
    let context: ModelContext

    private func recentMeetings(limit: Int = 200) -> [Meeting] {
        var d = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d))?.filter(\.isAlive) ?? []
    }

    /// The most recent meeting's summary (or a friendly fallback).
    func latestMeetingSummary() throws -> String {
        guard let m = recentMeetings(limit: 1).first else { throw IntentError.noMeetings }
        let summary = m.liveSummary?.text ?? (m.enhancedNotes.isEmpty ? m.notes : m.enhancedNotes)
        return summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\u{201C}\(m.title)\u{201D} doesn't have a summary yet."
            : "\(m.title):\n\n\(summary)"
    }

    /// Open (not-done) action items across all meetings, optionally filtered by owner.
    func openActionItems(owner: String?) -> String {
        let open = recentMeetings().flatMap { $0.liveActionItems }.filter { !$0.isDone }
        let items: [ActionItem]
        if let owner, !owner.trimmingCharacters(in: .whitespaces).isEmpty {
            items = open.filter { ($0.owner ?? "").localizedCaseInsensitiveContains(owner) }
        } else {
            items = open
        }
        guard !items.isEmpty else {
            return owner.map { "No open action items for \($0)." } ?? "No open action items. \u{1F389}"
        }
        return items.prefix(25).map { item in
            "\u{2022} \(item.text)" + (item.owner.map { " \u{2014} \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    /// Meetings whose title or transcript match a keyword (most recent first).
    func findMeetings(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return "Give me something to search for." }
        let hits = recentMeetings().filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.transcriptText.localizedCaseInsensitiveContains(q)
        }
        guard !hits.isEmpty else { return "No meetings match \u{201C}\(q)\u{201D}." }
        return hits.prefix(15).map {
            "\u{2022} \($0.title) \u{2014} \($0.date.formatted(date: .abbreviated, time: .omitted))"
        }.joined(separator: "\n")
    }

    /// Ask a question across all meetings — on-device hybrid retrieval picks the most
    /// relevant meetings, then the local LLM answers, grounded in them.
    func ask(_ question: String) async throws -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw IntentError.emptyQuestion }
        let all = recentMeetings()
        guard !all.isEmpty else { throw IntentError.noMeetings }

        // Rank by relevance when the on-device index is available; else recent.
        var chosen = Array(all.prefix(8))
        if SemanticIndex.isAvailable {
            let index = SemanticIndex(context: context)
            index.ensureIndexed(all)
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ranked = index.search(q, limit: 12).compactMap { byID[$0] }
            if !ranked.isEmpty { chosen = ranked }
        }

        let block = chosen.map { m -> String in
            let tag = String(m.id.uuidString.prefix(4)).lowercased()
            let notes = m.enhancedNotes.isEmpty ? (m.liveSummary?.text ?? "") : m.enhancedNotes
            return "[#\(tag) \(m.title)] (\(m.date.formatted(date: .abbreviated, time: .shortened)))\nNotes: \(notes.prefix(900))"
        }.joined(separator: "\n\n")

        do {
            let answer = try await ChatService().answerAcrossMeetings(question: q, context: block, history: [])
            // Strip inline [#tag] citations for a clean spoken / Shortcuts result.
            return answer
                .replacingOccurrences(of: #"\s*\[#[a-z0-9]{2,8}\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw IntentError.aiUnreachable
        }
    }
}
