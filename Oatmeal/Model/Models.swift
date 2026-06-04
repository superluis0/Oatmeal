import Foundation
import SwiftData

@Model
final class Meeting {
    var id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var audioPath: String?

    /// Free-text notes the user types during the call (the "raw" notes).
    var notes: String
    /// AI-rewritten Markdown notes that merge `notes` with transcript facts.
    var enhancedNotes: String

    var calendarEventID: String?
    var tags: [String]
    var templateName: String?

    /// Per-meeting map of diarized speaker label ("Speaker 2") -> display name.
    var speakerNames: [String: String]

    /// Enhanced notes broken into provenance-tagged blocks (user vs AI).
    /// Kept in sync with `enhancedNotes` (the flat Markdown used for export/search).
    var noteBlocks: [NoteBlock]

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment]

    @Relationship(deleteRule: .cascade, inverse: \Attendee.meeting)
    var attendees: [Attendee]

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.meeting)
    var chatMessages: [ChatMessage]

    @Relationship(deleteRule: .cascade, inverse: \ActionItem.meeting)
    var actionItems: [ActionItem]

    @Relationship(deleteRule: .cascade, inverse: \Highlight.meeting)
    var highlights: [Highlight]

    @Relationship(deleteRule: .cascade)
    var summary: Summary?

    var folder: Folder?

    init(
        id: UUID = UUID(),
        title: String = "New Meeting",
        date: Date = .now,
        duration: TimeInterval = 0,
        audioPath: String? = nil,
        notes: String = "",
        enhancedNotes: String = "",
        calendarEventID: String? = nil,
        tags: [String] = [],
        templateName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.audioPath = audioPath
        self.notes = notes
        self.enhancedNotes = enhancedNotes
        self.calendarEventID = calendarEventID
        self.tags = tags
        self.templateName = templateName
        self.speakerNames = [:]
        self.noteBlocks = []
        self.segments = []
        self.attendees = []
        self.chatMessages = []
        self.actionItems = []
        self.highlights = []
        self.summary = nil
        self.folder = nil
    }

    var orderedHighlights: [Highlight] {
        highlights.sorted { $0.time < $1.time }
    }

    var openActionItemCount: Int {
        actionItems.filter { !$0.isDone }.count
    }

    var orderedSegments: [TranscriptSegment] {
        segments.sorted { $0.start < $1.start }
    }

    /// Human-friendly duration: "42s", "3m 10s", "1h 5m".
    var durationLabel: String {
        let total = Int(duration.rounded())
        if total <= 0 { return "—" }
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let seconds = total % 60
        if minutes < 60 { return seconds == 0 ? "\(minutes) min" : "\(minutes)m \(seconds)s" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    var orderedChatMessages: [ChatMessage] {
        chatMessages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Display name for a diarized speaker label, honoring any user rename.
    func displayName(for speaker: String) -> String {
        speakerNames[speaker] ?? speaker
    }

    var transcriptText: String {
        orderedSegments
            .map { "\(displayName(for: $0.speaker)): \($0.text)" }
            .joined(separator: "\n")
    }
}

@Model
final class TranscriptSegment {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
    var meeting: Meeting?

    init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

@Model
final class Summary {
    var text: String
    var actionItems: [String]
    var keyPoints: [String]
    var createdAt: Date

    init(text: String, actionItems: [String] = [], keyPoints: [String] = [], createdAt: Date = .now) {
        self.text = text
        self.actionItems = actionItems
        self.keyPoints = keyPoints
        self.createdAt = createdAt
    }
}

@Model
final class Attendee {
    var name: String
    var email: String?
    /// Ties a diarized label ("Speaker 2") to this real person, when known.
    var mappedSpeakerLabel: String?
    var meeting: Meeting?

    init(name: String, email: String? = nil, mappedSpeakerLabel: String? = nil) {
        self.name = name
        self.email = email
        self.mappedSpeakerLabel = mappedSpeakerLabel
    }
}

@Model
final class ChatMessage {
    /// "user" or "assistant".
    var role: String
    var text: String
    var createdAt: Date
    var meeting: Meeting?
    var session: ChatSession?

    init(role: String, text: String, createdAt: Date = .now) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

@Model
final class Folder {
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Meeting.folder)
    var meetings: [Meeting]

    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
        self.meetings = []
    }
}

/// A provenance-tagged paragraph of enhanced notes. `isAI` text renders muted;
/// editing a block flips it to user-owned (`edited`, `isAI = false`).
struct NoteBlock: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var isAI: Bool
    var edited: Bool = false
}

@Model
final class CustomTemplate {
    var name: String
    var systemPrompt: String
    var skeleton: String
    var createdAt: Date

    init(name: String, systemPrompt: String, skeleton: String, createdAt: Date = .now) {
        self.name = name
        self.systemPrompt = systemPrompt
        self.skeleton = skeleton
        self.createdAt = createdAt
    }
}

@Model
final class Recipe {
    var name: String
    var prompt: String
    var createdAt: Date

    init(name: String, prompt: String, createdAt: Date = .now) {
        self.name = name
        self.prompt = prompt
        self.createdAt = createdAt
    }
}

@Model
final class ChatSession {
    /// "all", "folder:<name>", or "selected".
    var scopeRaw: String
    var title: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage]

    init(scopeRaw: String, title: String, createdAt: Date = .now) {
        self.scopeRaw = scopeRaw
        self.title = title
        self.createdAt = createdAt
        self.messages = []
    }

    var orderedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

/// One embedded chunk of a meeting's text, for on-device semantic search.
@Model
final class EmbeddingChunk {
    var meetingID: UUID
    var text: String
    var vector: [Float]
    /// "notes" or "transcript".
    var kind: String
    var createdAt: Date

    init(meetingID: UUID, text: String, vector: [Float], kind: String, createdAt: Date = .now) {
        self.meetingID = meetingID
        self.text = text
        self.vector = vector
        self.kind = kind
        self.createdAt = createdAt
    }
}

@Model
final class ActionItem {
    var text: String
    var isDone: Bool
    var dueDate: Date?
    /// Person responsible, when the model could infer one.
    var owner: String?
    var createdAt: Date
    var meeting: Meeting?
    /// EventKit reminder identifier, when synced to Apple Reminders.
    var reminderID: String?
    /// When set and in the future, the item is hidden from active buckets until then.
    var snoozedUntil: Date?

    init(text: String, isDone: Bool = false, dueDate: Date? = nil, owner: String? = nil, createdAt: Date = .now) {
        self.text = text
        self.isDone = isDone
        self.dueDate = dueDate
        self.owner = owner
        self.createdAt = createdAt
    }
}

@Model
final class Highlight {
    /// Seconds from the start of the recording.
    var time: Double
    var note: String?
    var createdAt: Date
    var meeting: Meeting?

    init(time: Double, note: String? = nil, createdAt: Date = .now) {
        self.time = time
        self.note = note
        self.createdAt = createdAt
    }
}

/// Trims a transcript so it fits comfortably inside a local model's context
/// window, keeping the start and end (where decisions/action items cluster).
func truncateTranscript(_ transcript: String, maxChars: Int = 12_000) -> String {
    guard transcript.count > maxChars else { return transcript }
    let headLen = maxChars * 2 / 3
    let tailLen = maxChars - headLen
    let head = transcript.prefix(headLen)
    let tail = transcript.suffix(tailLen)
    return "\(head)\n\n…[transcript truncated for length]…\n\n\(tail)"
}
