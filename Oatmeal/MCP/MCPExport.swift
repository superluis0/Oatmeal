import Foundation
import SwiftData

/// Writes a read-only JSON mirror of meetings to Application Support so the
/// standalone `oatmeal-mcp` server can expose them to agents (Claude, etc.)
/// without touching the live SwiftData store.
@MainActor
enum MCPExport {
    static func mirrorURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Oatmeal/mcp-meetings.json")
    }

    static func sync(context: ModelContext) {
        let descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        let meetings = (try? context.fetch(descriptor)) ?? []
        write(meetings)
        lastSyncAt = .now
    }

    private static var lastSyncAt: Date?

    /// Coalesced sync for frequent triggers (launch, app-switch) so the agent mirror
    /// stays current with in-app edits without re-serializing on every rapid app
    /// switch. The explicit `sync` (post-recording / post-write) bypasses the throttle.
    static func syncIfNeeded(context: ModelContext, minInterval: TimeInterval = 3) {
        if let last = lastSyncAt, Date.now.timeIntervalSince(last) < minInterval { return }
        sync(context: context)
    }

    private static func write(_ meetings: [Meeting]) {
        guard let url = mirrorURL() else { return }
        let iso = ISO8601DateFormatter()
        let payload: [[String: Any]] = meetings.map { m in
            var dict: [String: Any] = [:]
            dict["id"] = m.id.uuidString
            dict["title"] = m.title
            dict["date"] = iso.string(from: m.date)
            dict["durationSeconds"] = m.duration
            dict["attendees"] = m.attendees.map(\.name)
            dict["tags"] = m.tags
            dict["folder"] = m.folder?.name ?? ""
            dict["summary"] = m.summary?.text ?? ""
            dict["keyPoints"] = m.summary?.keyPoints ?? []
            dict["actionItems"] = m.summary?.actionItems ?? []
            // Structured tasks (text + owner + done) for the agent tools — distinct
            // from the summary's plain action-item strings above.
            dict["tasks"] = m.liveActionItems.map {
                ["text": $0.text, "owner": $0.owner ?? "", "done": $0.isDone] as [String: Any]
            }
            dict["notes"] = m.enhancedNotes
            dict["transcript"] = m.transcriptText
            return dict
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url, options: [.atomic])
            // Restrict to owner-only — the mirror contains full transcripts/notes.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
