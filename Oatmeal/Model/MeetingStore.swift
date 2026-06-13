import Foundation
import SwiftData

/// Centralized meeting deletion that also cleans up artifacts not covered by
/// SwiftData cascade rules: the archived audio file and semantic-search chunks.
@MainActor
enum MeetingStore {
    static func delete(_ meeting: Meeting, context: ModelContext) {
        // Remove the archived audio file from disk.
        if let path = meeting.audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        // Remove embedding chunks (referenced by id, not a relationship).
        let id = meeting.id
        if let chunks = try? context.fetch(
            FetchDescriptor<EmbeddingChunk>(predicate: #Predicate { $0.meetingID == id })) {
            for chunk in chunks { context.delete(chunk) }
        }

        // Cascades segments / attendees / chatMessages / summary. Saving a
        // cascade delete is exactly the case that can raise an uncatchable ObjC
        // exception, so go through SafeStore rather than `try?`.
        context.delete(meeting)
        SafeStore.save(context, "delete-meeting")
        MCPExport.sync(context: context)
    }
}
