import Foundation
import SwiftData

/// A persisted, regenerable cross-meeting report (Digest or Decisions), keyed by
/// (kind, scope). These AI outputs used to live in ephemeral view `@State` and were
/// lost the instant you navigated away — this makes them durable: reopen the view
/// and your last report is right there, with a "regenerate" affordance when the
/// underlying meetings have changed. One record per kind+scope (replaced on
/// regenerate). Regenerable, so it's intentionally not in the backup snapshot.
@Model
final class SavedReport {
    var kind: String = ""        // "digest" | "decisions"
    var scopeRaw: String = ""    // "thisWeek" | "allTime" | "folder:Sales" | "tag:hiring" | "person:Dana"
    var markdown: String = ""
    var createdAt: Date = Date.now
    /// Comma-separated UUIDs of the meetings the report covered — for citation
    /// rewriting and "has anything changed since?" staleness.
    var meetingIDsRaw: String = ""

    init(kind: String, scopeRaw: String, markdown: String, meetingIDsRaw: String) {
        self.kind = kind
        self.scopeRaw = scopeRaw
        self.markdown = markdown
        self.createdAt = .now
        self.meetingIDsRaw = meetingIDsRaw
    }

    var coveredIDs: Set<UUID> {
        Set(meetingIDsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
}

/// Fetch/upsert helper for `SavedReport` (one record per kind+scope).
@MainActor
enum ReportStore {
    static func fetch(kind: String, scopeRaw: String, context: ModelContext) -> SavedReport? {
        let descriptor = FetchDescriptor<SavedReport>(
            predicate: #Predicate { $0.kind == kind && $0.scopeRaw == scopeRaw })
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    static func upsert(kind: String, scopeRaw: String, markdown: String,
                       meetingIDs: [UUID], context: ModelContext) -> SavedReport {
        let ids = meetingIDs.map(\.uuidString).joined(separator: ",")
        if let existing = fetch(kind: kind, scopeRaw: scopeRaw, context: context) {
            existing.markdown = markdown
            existing.createdAt = .now
            existing.meetingIDsRaw = ids
            SafeStore.save(context, "report:\(kind)")
            return existing
        }
        let report = SavedReport(kind: kind, scopeRaw: scopeRaw, markdown: markdown, meetingIDsRaw: ids)
        context.insert(report)
        SafeStore.save(context, "report:\(kind)")
        return report
    }
}
