import Foundation
import SwiftData

/// Manages the archived-audio footprint. Transcripts/notes are always kept;
/// only the heavy WAVs are measured/pruned.
@MainActor
enum StorageManager {
    static func recordingsDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Oatmeal/Recordings", isDirectory: true)
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
