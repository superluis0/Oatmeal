import Foundation
import SwiftData
import CryptoKit

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

    // MARK: Summary staleness

    /// The exact string fed to the summarizer — display names resolved, "Me"
    /// grounded to the user's real name. The staleness signature is derived from
    /// this so the summary tracks precisely what the LLM saw.
    var summarySignatureBasis: String {
        MeetingIdentity.ground(transcript: transcriptText, userName: AppSettings.userName)
    }

    /// Stable content hash (SHA-256 hex) of `summarySignatureBasis`. Stable across
    /// launches — deliberately NOT Swift's per-process-seeded `Hasher`, which would
    /// mark every summary stale on each relaunch.
    var currentSummarySignatureHash: String {
        Meeting.signatureHash(forBasis: summarySignatureBasis)
    }

    /// SHA-256 hex of an already-grounded transcript basis. Lets the post-recording
    /// and regenerate flows stamp the signature from the grounded transcript STRING
    /// they already hold, instead of re-reading live `TranscriptSegment`s in a late
    /// async continuation — that re-read sorts the segments and can trap
    /// (SwiftData fault-fulfillment) if the store or objects have gone bad by then,
    /// which is exactly the post-recording crash seen in the wild.
    static func signatureHash(forBasis basis: String) -> String {
        SHA256.hash(data: Data(basis.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// True when a summary exists but the transcript it was generated from no
    /// longer matches the current (speaker-resolved) transcript — e.g. after a
    /// merge, re-identify, or transcript edit. A `nil` stored signature (legacy
    /// summaries) reads as not-stale.
    var summaryIsStale: Bool {
        guard let s = liveSummary, let sig = s.transcriptSignature else { return false }
        return sig != currentSummarySignatureHash
    }

    /// Diarized "Speaker N" labels (the non-self voices) that still carry no
    /// assigned name — the ones a wrap-up confirm step would ask about. Sorted by
    /// speaker number.
    var unnamedSpeakerLabels: [String] {
        Set(orderedSegments.map(\.speaker).filter { $0.hasPrefix("Speaker ") })
            .filter { speakerNames[$0] == nil }
            .sorted { (Int($0.dropFirst(8)) ?? 0) < (Int($1.dropFirst(8)) ?? 0) }
    }

    /// True when auto-naming couldn't confidently name every detected voice (a
    /// count mismatch, no roster, etc.) — the signal that the wrap-up should show
    /// its confirm-speakers step. Empty/false in the confident case (clean match),
    /// so confident meetings skip straight to the summary.
    var needsSpeakerConfirmation: Bool { !unnamedSpeakerLabels.isEmpty }

    /// Set or clear a diarized speaker label's display name and keep an existing
    /// summary textually in sync **cheaply** (no LLM): whole-word replace the old
    /// display name with the new one across the summary's prose/points/items, then
    /// re-stamp the signature so the (now-correct) summary doesn't read as stale.
    /// The caller is responsible for saving + reindexing.
    func setSpeakerName(_ rawName: String, for label: String) {
        let old = displayName(for: label)
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerNames[label] = (trimmed.isEmpty || trimmed == label) ? nil : trimmed
        let new = displayName(for: label)
        guard old != new else { return }
        // Carry the speaker's tasks over to the new name too.
        relabelOwners(from: old, to: new)
        patchSummaryName(from: old, to: new)
    }

    /// Whole-word replace one display name with another across the existing summary
    /// (prose / key points / action items), then re-stamp the staleness signature so
    /// the now-corrected summary doesn't immediately read as stale. Used by BOTH
    /// rename and merge to keep the summary in sync **cheaply** (no LLM). No-op
    /// without a summary or when nothing changes. MUST be called *after* the
    /// transcript-affecting mutation (the `speakerNames` change or segment
    /// reassignment) so the re-stamped hash reflects the final transcript.
    func patchSummaryName(from old: String, to new: String) {
        guard old != new, let s = liveSummary else { return }
        s.text = Meeting.replacingWholeWord(old, with: new, in: s.text)
        s.keyPoints = s.keyPoints.map { Meeting.replacingWholeWord(old, with: new, in: $0) }
        s.actionItems = s.actionItems.map { Meeting.replacingWholeWord(old, with: new, in: $0) }
        s.transcriptSignature = currentSummarySignatureHash
    }

    /// Reassign action items owned under one display name to another, so a fixed
    /// or merged speaker carries their tasks. Used by rename and merge.
    func relabelOwners(from old: String, to new: String) {
        guard old != new else { return }
        for item in liveActionItems where item.owner == old {
            item.owner = new
        }
    }

    /// Whole-word replace that won't let "Speaker 1" match inside "Speaker 12" or
    /// "Sam" match inside "Samantha" (Unicode letter/number boundaries on both
    /// sides). Returns the input unchanged when there's nothing safe to do.
    static func replacingWholeWord(_ old: String, with new: String, in text: String) -> String {
        let o = old.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, o != new else { return text }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: o) + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range,
                                           withTemplate: NSRegularExpression.escapedTemplate(for: new))
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
    /// Hash of the grounded transcript this summary was generated from, used to
    /// detect when speaker fixes / transcript edits have made the summary stale.
    /// Optional with a default so adding it is a lightweight, non-destructive
    /// SwiftData migration; legacy summaries migrate in as `nil` (treated as
    /// not-stale, so old meetings never surface a spurious "update" prompt).
    var transcriptSignature: String? = nil

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
