import Foundation
import SwiftData

/// Full-fidelity JSON backup of the meeting store, plus restore.
///
/// Written on every launch and after each meeting, so that if SwiftData ever
/// fails to open the store and it has to be moved aside, the data can be restored
/// automatically — no more silent wipes. On first run after a wipe it also falls
/// back to the older `mcp-meetings.json` mirror to recover pre-backup data.
@MainActor
enum StoreBackup {
    private static let version = 2

    private static var supportDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
    private static var backupDir: URL? { supportDir?.appendingPathComponent("Oatmeal/Backups", isDirectory: true) }
    private static var snapshotURL: URL? { backupDir?.appendingPathComponent("meetings-backup.json") }
    private static var prevSnapshotURL: URL? { backupDir?.appendingPathComponent("meetings-backup.prev.json") }
    private static var mcpMirrorURL: URL? { supportDir?.appendingPathComponent("Oatmeal/mcp-meetings.json") }
    private static var mcpRecoveredMarker: URL? { backupDir?.appendingPathComponent(".mcp-recovered") }

    // MARK: - Snapshot

    /// Write a complete backup of all meetings. No-op if the store is empty (so a
    /// transiently-empty store never clobbers a good backup).
    static func snapshot(context: ModelContext) {
        guard let backupDir, let url = snapshotURL else { return }
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        guard !meetings.isEmpty else { return }

        let payload: [String: Any] = ["version": version, "meetings": meetings.map(encode)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }

        // The model reads + JSON encode above need the main actor, but the file
        // system work (dir create, previous-generation copy, atomic write) is pure
        // I/O on Sendable values — run it on a serial background queue so the main
        // thread isn't blocked on disk latency at launch or after each meeting. The
        // queue is serial, so snapshots still land in call order.
        let prev = prevSnapshotURL
        ioQueue.async { writeSnapshot(data, to: url, backupDir: backupDir, prevURL: prev) }
    }

    private static let ioQueue = DispatchQueue(label: "com.oatmeal.backup-io", qos: .utility)

    /// Performs the snapshot's disk I/O off the main actor. Pure file operations on
    /// Sendable inputs — touches no SwiftData model.
    nonisolated private static func writeSnapshot(_ data: Data, to url: URL, backupDir: URL, prevURL: URL?) {
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        // Keep one previous generation as a second safety net.
        if let prev = prevURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.copyItem(at: url, to: prev)
        }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func encode(_ m: Meeting) -> [String: Any] {
        var dict: [String: Any] = [
            "id": m.id.uuidString,
            "title": m.title,
            "date": m.date.timeIntervalSince1970,
            "duration": m.duration,
            "notes": m.notes,
            "enhancedNotes": m.enhancedNotes,
            "tags": m.tags,
            "speakerNames": m.speakerNames,
        ]
        if let p = m.audioPath { dict["audioPath"] = p }
        if let c = m.calendarEventID { dict["calendarEventID"] = c }
        if let t = m.templateName { dict["templateName"] = t }
        if let f = m.folder?.name { dict["folder"] = f }
        dict["attendees"] = m.attendees.map { ["name": $0.name, "email": $0.email ?? ""] }
        if let s = m.summary {
            var sd: [String: Any] = ["text": s.text, "keyPoints": s.keyPoints, "actionItems": s.actionItems]
            // Persist the staleness signature too. Without it, every restored summary
            // comes back with a nil signature → `summaryIsStale` is always false → the
            // "Update summary" banner can never appear after a restore (which this
            // store does often). Speaker fixes then silently never reach the summary.
            if let sig = s.transcriptSignature { sd["transcriptSignature"] = sig }
            dict["summary"] = sd
        }
        dict["actionItems"] = m.actionItems.map { a -> [String: Any] in
            var d: [String: Any] = ["text": a.text, "isDone": a.isDone]
            if let o = a.owner { d["owner"] = o }
            if let due = a.dueDate { d["dueDate"] = due.timeIntervalSince1970 }
            if let snz = a.snoozedUntil { d["snoozedUntil"] = snz.timeIntervalSince1970 }
            if let r = a.reminderID { d["reminderID"] = r }
            return d
        }
        dict["segments"] = m.orderedSegments.map {
            ["start": $0.start, "end": $0.end, "speaker": $0.speaker, "text": $0.text]
        }
        return dict
    }

    // MARK: - Restore

    /// If the store has no meetings, restore from the latest full backup — or, one
    /// time only, from the older MCP mirror. Returns the number restored.
    @discardableResult
    static func restoreIfEmpty(context: ModelContext) -> Int {
        let existing = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        guard existing.isEmpty else { return 0 }

        // Prefer our full-fidelity snapshot (current, then previous generation).
        for candidate in [snapshotURL, prevSnapshotURL].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: candidate),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["meetings"] as? [[String: Any]], !arr.isEmpty {
                return importSnapshot(arr, context: context)
            }
        }

        // One-time fallback: the older MCP mirror (partial fidelity).
        if let marker = mcpRecoveredMarker, !FileManager.default.fileExists(atPath: marker.path),
           let url = mcpMirrorURL, let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !arr.isEmpty {
            let n = importMirror(arr, context: context)
            if let dir = backupDir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: marker.path, contents: Data())
            }
            return n
        }
        return 0
    }

    private static func importSnapshot(_ arr: [[String: Any]], context: ModelContext) -> Int {
        var folders: [String: Folder] = [:]
        var count = 0
        for m in arr {
            guard let idStr = m["id"] as? String, let id = UUID(uuidString: idStr),
                  let title = m["title"] as? String else { continue }
            let date = (m["date"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .now
            let meeting = Meeting(
                id: id, title: title, date: date,
                duration: m["duration"] as? Double ?? 0,
                audioPath: m["audioPath"] as? String,
                notes: m["notes"] as? String ?? "",
                enhancedNotes: m["enhancedNotes"] as? String ?? "",
                calendarEventID: m["calendarEventID"] as? String,
                tags: m["tags"] as? [String] ?? [],
                templateName: m["templateName"] as? String)
            meeting.speakerNames = m["speakerNames"] as? [String: String] ?? [:]
            context.insert(meeting)
            attachFolder(named: m["folder"] as? String, to: meeting, folders: &folders, context: context)

            for a in (m["attendees"] as? [[String: Any]] ?? []) {
                guard let name = a["name"] as? String else { continue }
                let email = (a["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let att = Attendee(name: name, email: email); att.meeting = meeting; context.insert(att)
            }
            if let s = m["summary"] as? [String: Any] {
                let summary = Summary(text: s["text"] as? String ?? "",
                                      actionItems: s["actionItems"] as? [String] ?? [],
                                      keyPoints: s["keyPoints"] as? [String] ?? [])
                // Restore the staleness signature so speaker-fix detection keeps working
                // across a restore (see the encode side).
                summary.transcriptSignature = s["transcriptSignature"] as? String
                context.insert(summary); meeting.summary = summary
            }
            for a in (m["actionItems"] as? [[String: Any]] ?? []) {
                guard let text = a["text"] as? String else { continue }
                let item = ActionItem(text: text, isDone: a["isDone"] as? Bool ?? false,
                                      dueDate: (a["dueDate"] as? Double).map { Date(timeIntervalSince1970: $0) },
                                      owner: a["owner"] as? String)
                item.snoozedUntil = (a["snoozedUntil"] as? Double).map { Date(timeIntervalSince1970: $0) }
                item.reminderID = a["reminderID"] as? String
                item.meeting = meeting; context.insert(item)
            }
            for seg in (m["segments"] as? [[String: Any]] ?? []) {
                guard let text = seg["text"] as? String, let speaker = seg["speaker"] as? String else { continue }
                let s = TranscriptSegment(start: seg["start"] as? Double ?? 0,
                                          end: seg["end"] as? Double ?? 0,
                                          speaker: speaker, text: text)
                s.meeting = meeting; meeting.segments.append(s); context.insert(s)
            }
            count += 1
        }
        // Verify the save; reindexing is deferred to the next runloop by the caller
        // (reading the just-inserted segments in THIS runloop traps inside SwiftData).
        do { try context.save() } catch { Log.error("restore import save failed", "store", error) }
        return count
    }

    /// Reconstructs meetings from the partial MCP mirror. Audio is re-linked from
    /// the Recordings folder, and the flat transcript is parsed back into segments.
    private static func importMirror(_ arr: [[String: Any]], context: ModelContext) -> Int {
        let iso = ISO8601DateFormatter()
        var folders: [String: Folder] = [:]
        var count = 0
        for m in arr {
            guard let idStr = m["id"] as? String, let id = UUID(uuidString: idStr),
                  let title = m["title"] as? String else { continue }
            let date = (m["date"] as? String).flatMap { iso.date(from: $0) } ?? .now
            let duration = m["durationSeconds"] as? Double ?? 0
            let meeting = Meeting(
                id: id, title: title, date: date, duration: duration,
                audioPath: recordingPath(for: id),
                notes: "", enhancedNotes: m["notes"] as? String ?? "",
                tags: m["tags"] as? [String] ?? [])
            context.insert(meeting)
            attachFolder(named: m["folder"] as? String, to: meeting, folders: &folders, context: context)

            for name in (m["attendees"] as? [String] ?? []) {
                let att = Attendee(name: name); att.meeting = meeting; context.insert(att)
            }
            let summary = Summary(text: m["summary"] as? String ?? "",
                                  actionItems: m["actionItems"] as? [String] ?? [],
                                  keyPoints: m["keyPoints"] as? [String] ?? [])
            context.insert(summary); meeting.summary = summary
            for t in (m["actionItems"] as? [String] ?? []) {
                let item = ActionItem(text: t); item.meeting = meeting; context.insert(item)
            }
            for seg in parseTranscript(m["transcript"] as? String ?? "", duration: duration) {
                let s = TranscriptSegment(start: seg.start, end: seg.end, speaker: seg.speaker, text: seg.text)
                s.meeting = meeting; meeting.segments.append(s); context.insert(s)
            }
            count += 1
        }
        // Verify the save; reindexing is deferred to the next runloop by the caller
        // (reading the just-inserted segments in THIS runloop traps inside SwiftData).
        do { try context.save() } catch { Log.error("restore import save failed", "store", error) }
        return count
    }

    // MARK: - Helpers

    private static func attachFolder(named name: String?, to meeting: Meeting,
                                     folders: inout [String: Folder], context: ModelContext) {
        guard let name, !name.isEmpty else { return }
        if let existing = folders[name] {
            meeting.folder = existing
        } else {
            let f = Folder(name: name); context.insert(f); folders[name] = f; meeting.folder = f
        }
    }

    private static func recordingPath(for id: UUID) -> String? {
        guard let base = supportDir else { return nil }
        let url = base.appendingPathComponent("Oatmeal/Recordings/\(id.uuidString).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// Parses a flat "Speaker: text" transcript back into segments with timings
    /// spread evenly across the meeting duration (so click-to-seek roughly works).
    private static func parseTranscript(_ text: String, duration: Double)
        -> [(start: Double, end: Double, speaker: String, text: String)] {
        let lines = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return [] }
        let step = duration > 0 ? duration / Double(lines.count) : 1
        return lines.enumerated().map { i, line in
            let speaker: String, body: String
            if let r = line.range(of: ": ") {
                speaker = String(line[..<r.lowerBound]); body = String(line[r.upperBound...])
            } else {
                speaker = "Speaker 1"; body = line
            }
            return (Double(i) * step, Double(i + 1) * step, speaker, body)
        }
    }

    /// Rebuilds embedding chunks for every meeting. MUST be called on a fresh
    /// runloop turn after an import — never inside the import transaction, where
    /// reading just-inserted segment relationships traps inside SwiftData.
    static func reindexAll(context: ModelContext) {
        let index = SemanticIndex(context: context)
        for m in (try? context.fetch(FetchDescriptor<Meeting>())) ?? [] { index.reindex(m) }
    }
}
