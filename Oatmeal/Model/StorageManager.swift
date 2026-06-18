import Foundation
import SwiftData

/// One unsaved recording: audio on disk with no matching meeting. Happens when a
/// store failure blocked the meeting's save (the WAV is written to disk first, in
/// `RecordingCoordinator.saveAudio`, before the database save) or a backup restore
/// dropped a recent meeting. The `.wav` filename is the original meeting id.
struct OrphanRecording: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let date: Date
    let sizeBytes: Int64
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

/// Manages the archived-audio footprint. Transcripts/notes are always kept;
/// only the heavy WAVs are measured/pruned.
@MainActor
enum StorageManager {
    static func recordingsDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Oatmeal/Recordings", isDirectory: true)
    }

    /// The SwiftData store's EFFECTIVE location: the app's OWN namespaced
    /// subdirectory (`…/Application Support/Oatmeal/default.store`), alongside
    /// `Recordings/` and `Backups/` — never the shared Application Support root, so
    /// nothing else there can collide with or touch the SQLite files. Falls back to a
    /// not-yet-relocated legacy AS-root `default.store` if one still exists (so a
    /// deferred migration keeps using the real data). The single source of truth for
    /// the store path (container bootstrap, move-aside, diagnostics). `nonisolated`
    /// so the `@MainActor` App container closure can call it during early bootstrap.
    /// `nil` only if Application Support can't be resolved.
    nonisolated static func storeURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let namespaced = appSupport.appendingPathComponent("Oatmeal/default.store", isDirectory: false)
        if fm.fileExists(atPath: namespaced.path) { return namespaced }
        let legacy = appSupport.appendingPathComponent("default.store", isDirectory: false)
        if fm.fileExists(atPath: legacy.path) { return legacy }
        return namespaced   // fresh install → where SwiftData will create it
    }

    /// Recordings on disk whose meeting id is NOT among `meetingIDs` — i.e. audio
    /// with no meeting to attach it to (a store failure blocked the save, or a
    /// restore dropped the meeting). Newest first. A cheap scan of a handful of
    /// files, safe to call from a view on the main actor.
    static func orphanedRecordings(meetingIDs: Set<UUID>) -> [OrphanRecording] {
        guard let dir = recordingsDirectory() else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { url -> OrphanRecording? in
            guard url.pathExtension.lowercased() == "wav",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !meetingIDs.contains(id) else { return nil }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            return OrphanRecording(
                id: id, url: url,
                date: vals?.contentModificationDate ?? .distantPast,
                sizeBytes: Int64(vals?.fileSize ?? 0))
        }
        .sorted { $0.date > $1.date }
    }

    static func audioBytes() -> Int64 {
        guard let dir = recordingsDirectory(),
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func formattedAudioSize() -> String {
        ByteCountFormatter.string(fromByteCount: audioBytes(), countStyle: .file)
    }

    /// Delete every archived audio file and clear `audioPath` on all meetings.
    static func deleteAllAudio(meetings: [Meeting], context: ModelContext) {
        for meeting in meetings where meeting.audioPath != nil {
            if let path = meeting.audioPath { try? FileManager.default.removeItem(atPath: path) }
            meeting.audioPath = nil
        }
        if let dir = recordingsDirectory(),
           let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in items { try? FileManager.default.removeItem(at: url) }
        }
        SafeStore.save(context, "delete-all-audio")
    }

    /// Prune audio older than the retention setting (0 = keep forever).
    static func pruneOldAudio(meetings: [Meeting], context: ModelContext) {
        let days = AppSettings.audioRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var changed = false
        for meeting in meetings where meeting.date < cutoff && meeting.audioPath != nil {
            if let path = meeting.audioPath { try? FileManager.default.removeItem(atPath: path) }
            meeting.audioPath = nil
            changed = true
        }
        if changed { SafeStore.save(context, "prune-old-audio") }
    }
}
