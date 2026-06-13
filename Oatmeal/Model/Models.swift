import Foundation
import SwiftData

// MARK: - Deleted-object safety

extension PersistentModel {
    /// A SwiftData model that has been deleted or invalidated reports a nil
    /// `modelContext`. Reading ANY persisted property on such an instance traps
    /// inside SwiftData (an uncatchable SIGTRAP), so always check this before
    /// touching a model that may have been deleted out from under a live view —
    /// especially one reached by traversing a relationship, since the top-level
    /// `@Query` prunes deletions but related objects don't update in lockstep.
    var isAlive: Bool { modelContext != nil }
}

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

    /// The most recent on-demand coaching / framework-scoring output (Markdown),
    /// persisted so it survives leaving the Analytics tab. Empty until generated.
    var coachingNotes: String = ""

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
        guard isAlive else { return [] }
        return highlights.filter(\.isAlive).sorted { $0.time < $1.time }
    }

    /// Action items that are still live (not deleted). All relationship-reading
    /// helpers funnel through this so no caller ever reads a property on a
    /// removed child (which would trap inside SwiftData).
    var liveActionItems: [ActionItem] {
        guard isAlive else { return [] }
        return actionItems.filter(\.isAlive)
    }

    var openActionItemCount: Int { liveActionItems.filter { !$0.isDone }.count }
    var doneActionItemCount: Int { liveActionItems.filter { $0.isDone }.count }

    /// Attendees that are still live.
    var liveAttendees: [Attendee] {
        guard isAlive else { return [] }
        return attendees.filter(\.isAlive)
    }

    var attendeeNames: [String] { liveAttendees.map(\.name) }

    /// The summary, but only when both it and this meeting are still live.
    var liveSummary: Summary? {
        guard isAlive, let s = summary, s.isAlive else { return nil }
        return s
    }

    var orderedSegments: [TranscriptSegment] {
        guard isAlive else { return [] }
        return segments.filter(\.isAlive).sorted { $0.start < $1.start }
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
        guard isAlive else { return [] }
        return chatMessages.filter(\.isAlive).sorted { $0.createdAt < $1.createdAt }
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
    /// Whether this person is expected to speak (set during pre-meeting prep).
    /// Non-speaking attendees are skipped when auto-naming diarized speakers.
    var expectedToSpeak: Bool = true
    /// True when this attendee is the note-taker — their speech is labeled "Me"
    /// in the transcript, so they're excluded from "Speaker N" auto-naming.
    var isSelf: Bool = false
    var meeting: Meeting?

    init(name: String, email: String? = nil, mappedSpeakerLabel: String? = nil) {
        self.name = name
        self.email = email
        self.mappedSpeakerLabel = mappedSpeakerLabel
    }
}

/// A person expected in an upcoming meeting, set up in the pre-meeting Prep
/// sheet before any recording exists.
struct PlannedSpeaker: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var email: String?
    /// True for the note-taker (matched from the calendar invite when possible).
    var isSelf: Bool = false
    /// Off for attendees who are invited but won't talk (rooms, FYI invitees) —
    /// they're kept for follow-up emails but excluded from speaker matching.
    var willSpeak: Bool = true
}

/// Pre-meeting preparation for a specific calendar event: who is expected to
/// speak (with emails, for follow-ups) and talking points. Consumed by
/// `RecordingCoordinator` when a recording for that event starts: the roster
/// becomes the meeting's attendees, drives the diarization speaker-count hint
/// and speaker auto-naming, and the notes seed the meeting's raw notes.
@Model
final class MeetingPrep {
    /// EventKit event identifier this prep belongs to. One prep per event.
    var calendarEventID: String
    var title: String
    var eventStart: Date
    /// Talking points / agenda, copied into the meeting's notes at record start.
    var prepNotes: String
    var speakers: [PlannedSpeaker]
    var updatedAt: Date

    init(calendarEventID: String, title: String, eventStart: Date,
         prepNotes: String = "", speakers: [PlannedSpeaker] = [], updatedAt: Date = .now) {
        self.calendarEventID = calendarEventID
        self.title = title
        self.eventStart = eventStart
        self.prepNotes = prepNotes
        self.speakers = speakers
        self.updatedAt = updatedAt
    }

    /// The people expected to actually talk, in roster order.
    var speakingRoster: [PlannedSpeaker] { speakers.filter(\.willSpeak) }
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
        guard isAlive else { return [] }
        return messages.filter(\.isAlive).sorted { $0.createdAt < $1.createdAt }
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
