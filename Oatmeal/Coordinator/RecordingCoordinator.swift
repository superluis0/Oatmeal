import Foundation
import SwiftUI
import SwiftData
import AppKit
import FluidAudio

@MainActor
@Observable
final class RecordingCoordinator {

    enum Phase: Equatable {
        case idle
        case preparingModels
        case recording
        case processing(String)
        case error(String)
    }

    var phase: Phase = .idle
    var elapsed: TimeInterval = 0
    var liveSegments: [LiveSegment] = []
    var activeMeeting: Meeting?
    var liveEnhanced: String = ""
    var isEnhancingLive = false
    /// Live Assist: real-time suggestion cards (newest first), and in-flight flag.
    var liveSuggestions: [LiveSuggestion] = []
    var isSuggesting = false
    /// Non-fatal warning (e.g. system audio unavailable) shown during recording.
    var captureWarning: String?
    /// Set just before a meeting is deleted out from under the UI (e.g. discarding
    /// an empty failed recording), so the view layer can drop it from `selection`
    /// before the model is invalidated and a layout pass reads a dead object.
    var lastDiscardedMeetingID: PersistentIdentifier?

    private let engine = AudioCaptureEngine()
    private let transcription = TranscriptionService()
    private let calendar = CalendarService()

    private var timer: Timer?
    private var liveTask: Task<Void, Never>?
    private var startDate: Date?

    // Live streaming caption text per source.
    private var liveMe = ""
    private var liveOthers = ""

    // Live Assist question-detection state.
    private var lastAssistQuestion = ""
    private var lastAssistFire: Date?
    private static let assistCooldown: TimeInterval = 10

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .preparingModels, .processing: return true
        default: return false
        }
    }

    // MARK: - Start

    func start(context: ModelContext, event: UpcomingMeeting? = nil) async {
        guard phase == .idle else { return }
        Log.info("recording start requested", "recording")
        liveSegments = []
        liveMe = ""
        liveOthers = ""
        liveEnhanced = ""
        liveSuggestions = []
        lastAssistQuestion = ""
        lastAssistFire = nil
        captureWarning = nil

        // Permissions
        let micOK = await AudioCaptureEngine.requestMicrophoneAccess()
        guard micOK else {
            phase = .error("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
            return
        }

        phase = .preparingModels
        do {
            try await transcription.prepare()
        } catch {
            phase = .error("Failed to load speech models: \(error.localizedDescription)")
            return
        }

        // Begin live streaming captions before audio starts flowing.
        let updates: AsyncStream<LiveUpdate>
        do {
            updates = try await transcription.beginStreaming()
        } catch {
            phase = .error("Failed to start live transcription: \(error.localizedDescription)")
            return
        }

        engine.onMicSamples = { [transcription] samples in transcription.feedMic(samples) }
        engine.onSystemSamples = { [transcription] samples in transcription.feedSystem(samples) }

        do {
            try await engine.start()
        } catch {
            engine.onMicSamples = nil
            engine.onSystemSamples = nil
            await transcription.endStreaming()
            phase = .error(error.localizedDescription)
            return
        }
        captureWarning = engine.systemCaptureWarning

        let meeting = Meeting(title: defaultTitle())
        context.insert(meeting)
        if let event {
            // The user picked a specific calendar meeting — seed from THAT one,
            // not whichever event the calendar thinks is "current" (which is wrong
            // when meetings overlap).
            seed(from: event, into: meeting, context: context)
        } else {
            await seedFromCalendar(meeting, context: context)
        }
        activeMeeting = meeting

        startDate = Date()
        phase = .recording
        playChime("Glass")
        startTimer()
        consumeLiveUpdates(updates)
    }

    private func playChime(_ name: String) {
        guard Appearance.shared.recordingChime else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Stop

    func stop(context: ModelContext) async {
        guard isRecording else { return }
        Log.info("recording stop requested", "recording")
        liveTask?.cancel()
        liveTask = nil
        timer?.invalidate()
        timer = nil

        engine.onMicSamples = nil
        engine.onSystemSamples = nil
        let (system, mic) = engine.stop()
        playChime("Pop")
        await transcription.endStreaming()
        let duration = startDate.map { Date().timeIntervalSince($0) } ?? elapsed

        guard let meeting = activeMeeting else {
            phase = .idle
            return
        }
        meeting.duration = duration

        phase = .processing("Transcribing and identifying speakers…")
        let segments: [LiveSegment]
        do {
            segments = try await transcription.buildTranscript(
                systemSamples: system, micSamples: mic,
                expectedSpeakers: expectedSpeakerHint(for: meeting)
            )
        } catch {
            // Clear active state so the next recording starts clean (otherwise a
            // stale startDate inflates the next session's elapsed time).
            Log.error("transcription failed", "recording", error)
            // Discard the empty meeting (nothing was transcribed) unless the user
            // typed notes — leaving it behind creates a broken half-meeting.
            if meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && meeting.segments.isEmpty {
                // Signal the UI to drop this from `selection` BEFORE we invalidate it.
                lastDiscardedMeetingID = meeting.persistentModelID
                context.delete(meeting)
                SafeStore.save(context, "discard-empty-meeting")
            }
            activeMeeting = nil
            startDate = nil
            phase = .error("Transcription failed: \(error.localizedDescription)")
            return
        }

        // Persist transcript
        for seg in segments {
            let model = TranscriptSegment(start: seg.start, end: seg.end, speaker: seg.speaker, text: seg.text)
            model.meeting = meeting
            meeting.segments.append(model)
            context.insert(model)
        }
        liveSegments = segments
        autoNameSpeakers(meeting, segments: segments)

        // Archive audio (mixed) best-effort
        meeting.audioPath = saveAudio(system: system, mic: mic, meetingID: meeting.id)

        guard await summarizeAndEnhance(meeting: meeting, context: context) else { return }
        activeMeeting = nil
        phase = .idle
    }

    /// Summary + note enhancement + persist + semantic reindex. Returns false (and
    /// leaves `phase` in `.error`) if summarization fails; the transcript is kept.
    private func summarizeAndEnhance(meeting: Meeting, context: ModelContext) async -> Bool {
        // Ground the transcript + prompts in WHO is speaking, so the AI doesn't
        // confuse the note-taker ("Me") with the other participants or invent
        // affiliations.
        let identity = MeetingIdentity.preamble(knownSpeakers: meeting.speakerNames)
        let transcript = MeetingIdentity.ground(transcript: meeting.transcriptText, userName: AppSettings.userName)

        phase = .processing("Generating summary with LM Studio…")
        do {
            let result = try await SummarizationService().summarize(
                transcript: transcript,
                title: meeting.title,
                attendees: meeting.attendeeNames,
                identity: identity
            )
            let summary = Summary(text: result.text, actionItems: result.actionItems, keyPoints: result.keyPoints)
            context.insert(summary)
            meeting.summary = summary
        } catch {
            Log.error("summarization failed (transcript kept)", "summary", error)
            phase = .error("Transcript saved, but summary failed: \(error.localizedDescription)")
            try? context.save()
            SemanticIndex(context: context).reindex(meeting)
            return false
        }

        // Non-fatal: keep transcript + summary even if enhancement fails.
        phase = .processing("Enhancing your notes…")
        let template = await resolveTemplate(for: meeting, transcript: transcript, context: context)
        meeting.templateName = template.name
        if let result = try? await NoteEnhancementService()
            .enhance(rawNotes: meeting.notes, transcript: transcript, template: template, identity: identity) {
            meeting.enhancedNotes = result.markdown
            meeting.noteBlocks = result.blocks
        }

        // Structured action items (task + owner + due).
        phase = .processing("Extracting action items…")
        await extractActionItems(for: meeting, context: context)

        try? context.save()
        SemanticIndex(context: context).reindex(meeting)
        MCPExport.sync(context: context)
        StoreBackup.snapshot(context: context)
        await WebhookService().postIfConfigured(
            title: meeting.title,
            summary: meeting.summary?.text ?? "",
            actionItems: meeting.summary?.actionItems ?? []
        )
        Log.info("meeting processed & saved: \(meeting.title) (\(meeting.segments.count) segments)", "summary")
        return true
    }

    /// Extracts structured action items (dedup on text) and attaches them to the meeting.
    func extractActionItems(for meeting: Meeting, context: ModelContext) async {
        let notes = meeting.enhancedNotes.isEmpty ? meeting.notes : meeting.enhancedNotes
        let extracted = await ActionItemExtractor().extract(transcript: meeting.transcriptText, notes: notes)
        let existing = Set(meeting.actionItems.map { $0.text.lowercased() })
        for action in extracted where !existing.contains(action.text.lowercased()) {
            let item = ActionItem(text: action.text, dueDate: action.dueDate, owner: action.owner)
            context.insert(item)
            item.meeting = meeting
        }
        try? context.save()
    }

    // MARK: - Import pre-recorded audio

    func importAudio(url: URL, context: ModelContext) async {
        guard phase == .idle else { return }

        phase = .preparingModels
        do {
            try await transcription.prepare()
        } catch {
            phase = .error("Failed to load speech models: \(error.localizedDescription)")
            return
        }

        let samples: [Float]
        do {
            samples = try AudioImporter.loadMono16k(from: url)
        } catch {
            phase = .error("Couldn't read audio file: \(error.localizedDescription)")
            return
        }
        guard !samples.isEmpty else {
            phase = .error("No audio found in that file.")
            return
        }

        let meeting = Meeting(title: url.deletingPathExtension().lastPathComponent)
        context.insert(meeting)
        meeting.duration = Double(samples.count) / 16_000

        phase = .processing("Transcribing imported audio…")
        let segments: [LiveSegment]
        do {
            segments = try await transcription.buildTranscript(systemSamples: samples, micSamples: [])
        } catch {
            phase = .error("Transcription failed: \(error.localizedDescription)")
            return
        }
        for seg in segments {
            let model = TranscriptSegment(start: seg.start, end: seg.end, speaker: seg.speaker, text: seg.text)
            model.meeting = meeting
            meeting.segments.append(model)
            context.insert(model)
        }
        meeting.audioPath = saveAudio(system: samples, mic: [], meetingID: meeting.id)

        guard await summarizeAndEnhance(meeting: meeting, context: context) else { return }
        phase = .idle
    }

    /// If the number of diarized "Speaker N" labels matches the attendee count,
    /// pre-fill display names from the calendar attendees (user can re-edit).
    private func autoNameSpeakers(_ meeting: Meeting, segments: [LiveSegment]) {
        let labels = Set(segments.map { $0.speaker }.filter { $0.hasPrefix("Speaker ") })
            .sorted { lhs, rhs in
                (Int(lhs.dropFirst(8)) ?? 0) < (Int(rhs.dropFirst(8)) ?? 0)
            }
        let names = meeting.attendees.map { $0.name }
        guard !labels.isEmpty, labels.count == names.count else { return }
        for (label, name) in zip(labels, names) {
            meeting.speakerNames[label] = name
        }
    }

    // MARK: - Highlights

    /// Bookmark the current moment in the active recording.
    @discardableResult
    func markHighlight(context: ModelContext) -> Bool {
        guard isRecording, let meeting = activeMeeting else { return false }
        let highlight = Highlight(time: elapsed)
        context.insert(highlight)
        highlight.meeting = meeting
        try? context.save()
        return true
    }

    // MARK: - Live note enhancement

    var liveTranscriptText: String {
        liveSegments.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// Enhances notes mid-recording from the rolling live transcript.
    func enhanceLive(context: ModelContext) async {
        guard let meeting = activeMeeting, !isEnhancingLive else { return }
        isEnhancingLive = true
        defer { isEnhancingLive = false }
        let transcript = liveTranscriptText
        let template = TemplateProvider.resolve(name: meeting.templateName ?? AppSettings.defaultTemplate, context: context)
        if let result = try? await NoteEnhancementService()
            .enhance(rawNotes: meeting.notes, transcript: transcript, template: template) {
            liveEnhanced = result.markdown
            meeting.enhancedNotes = result.markdown
            meeting.noteBlocks = result.blocks
        }
    }

    // MARK: - Live Assist (real-time suggestions)

    /// Auto-fire a suggestion when the other party finishes a new question, with a
    /// cooldown so a growing live buffer doesn't re-trigger on the same question.
    private func maybeAutoAssist() {
        guard AppSettings.liveAssistEnabled, !isSuggesting else { return }
        guard let question = Self.latestQuestion(in: liveOthers), question != lastAssistQuestion else { return }
        if let last = lastAssistFire, Date().timeIntervalSince(last) < Self.assistCooldown { return }
        lastAssistQuestion = question
        lastAssistFire = Date()
        Task { await generateSuggestion(question: question) }
    }

    /// Manually request a suggestion (the "Suggest now" button). Uses the most
    /// recent detected question for context if there is one.
    func requestSuggestion() async {
        let question = Self.latestQuestion(in: liveOthers)
        lastAssistFire = Date()
        if let question { lastAssistQuestion = question }
        await generateSuggestion(question: question)
    }

    private func generateSuggestion(question: String?) async {
        guard !isSuggesting else { return }
        isSuggesting = true
        defer { isSuggesting = false }
        let transcript = recentAssistTranscript()
        let profile = AppSettings.assistProfile
        guard let suggestion = try? await LiveAssistService()
            .suggest(question: question, recentTranscript: transcript, profile: profile),
              !suggestion.isEmpty else { return }
        liveSuggestions.insert(suggestion, at: 0)
        if liveSuggestions.count > 8 { liveSuggestions.removeLast() }
    }

    /// A compact recent window of the conversation for the assist prompt.
    private func recentAssistTranscript() -> String {
        var parts: [String] = []
        if !liveOthers.isEmpty { parts.append("Them: \(String(liveOthers.suffix(1_500)))") }
        if !liveMe.isEmpty { parts.append("Me: \(String(liveMe.suffix(800)))") }
        return parts.joined(separator: "\n")
    }

    /// Extracts the latest question from the rolling "others" text. The live ASR
    /// buffer usually has trailing partial words after the question mark, so we
    /// look for the last `?` ANYWHERE — not just as a suffix — and take the
    /// sentence ending at it.
    private static func latestQuestion(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let qIdx = trimmed.lastIndex(of: "?") else { return nil }
        let body = trimmed[..<qIdx] // text before the last '?'
        let question: String
        if let sepIdx = body.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            question = body[body.index(after: sepIdx)...].trimmingCharacters(in: .whitespaces) + "?"
        } else {
            question = body.trimmingCharacters(in: .whitespaces) + "?"
        }
        return question.count >= 8 ? question : nil
    }

    // MARK: - Live streaming captions

    private func consumeLiveUpdates(_ updates: AsyncStream<LiveUpdate>) {
        liveTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                switch update.source {
                case .me: self.liveMe = update.text
                case .others:
                    self.liveOthers = update.text
                    self.maybeAutoAssist()
                }
                self.refreshLiveSegments()
            }
        }
    }

    private func refreshLiveSegments() {
        var segments: [LiveSegment] = []
        if !liveOthers.isEmpty {
            segments.append(LiveSegment(start: 0, end: 0, speaker: "Others", text: liveOthers))
        }
        if !liveMe.isEmpty {
            segments.append(LiveSegment(start: 0, end: 0, speaker: "Me", text: liveMe))
        }
        liveSegments = segments
    }

    // MARK: - Helpers

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startDate else { return }
            Task { @MainActor in
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    /// Resolves the template for enhancement: auto-classify if enabled, else the
    /// meeting's own template (or the default).
    private func resolveTemplate(for meeting: Meeting, transcript: String, context: ModelContext) async -> NoteTemplate {
        if AppSettings.autoSelectTemplate {
            let names = TemplateProvider.all(context: context).map(\.name)
            if let picked = await TemplateClassifier().pick(from: names, transcript: transcript) {
                return TemplateProvider.resolve(name: picked, context: context)
            }
        }
        return TemplateProvider.resolve(name: meeting.templateName ?? AppSettings.defaultTemplate, context: context)
    }

    /// If a calendar event is happening now, use its title + attendees instead
    /// of the generic timestamp title.
    private func seedFromCalendar(_ meeting: Meeting, context: ModelContext) async {
        guard await calendar.requestAccess(),
              let event = calendar.currentOrUpcomingEvent() else { return }
        meeting.title = event.title
        meeting.calendarEventID = event.id
        for name in event.attendees {
            let attendee = Attendee(name: name)
            context.insert(attendee)
            attendee.meeting = meeting
        }
    }

    /// Seeds a new recording from a specific upcoming meeting the user chose
    /// (title, calendar id, attendees) — no calendar re-pick, so overlapping
    /// meetings can't cause the wrong one to be attached.
    private func seed(from event: UpcomingMeeting, into meeting: Meeting, context: ModelContext) {
        meeting.title = event.title
        meeting.calendarEventID = event.id
        for name in event.attendees {
            let attendee = Attendee(name: name)
            context.insert(attendee)
            attendee.meeting = meeting
        }
    }

    private func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Meeting · \(formatter.string(from: .now))"
    }

    private func saveAudio(system: [Float], mic: [Float], meetingID: UUID) -> String? {
        guard max(system.count, mic.count) > 0 else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oatmeal/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(meetingID.uuidString).wav")
        do {
            if system.isEmpty || mic.isEmpty {
                // Only one stream (e.g. imported audio) — write it as plain mono.
                try WavWriter.write(samples: system.isEmpty ? mic : system, to: url)
            } else {
                // Stereo: left = system, right = mic, so the recording can be
                // re-diarized later with the two streams separated. AVAudioPlayer
                // plays it back as a normal mix.
                try WavWriter.write(left: system, right: mic, to: url)
            }
            return url.path
        } catch {
            return nil
        }
    }

    /// Upper-bound speaker hint for diarization, drawn from the calendar attendee
    /// count (nil when unknown, so the diarizer auto-detects).
    private func expectedSpeakerHint(for meeting: Meeting) -> Int? {
        let n = meeting.attendees.count
        return n >= 2 ? n : nil
    }

    /// Re-runs speaker identification on a finished meeting's archived audio,
    /// optionally with an explicit expected-speaker count. Replaces the existing
    /// transcript segments in place; no re-recording needed.
    func reidentifySpeakers(for meeting: Meeting, expectedSpeakers: Int?, context: ModelContext) async {
        guard phase == .idle else { return }
        guard let path = meeting.audioPath else {
            phase = .error("This meeting has no archived audio to re-process.")
            return
        }

        phase = .processing("Loading speech models…")
        do { try await transcription.prepare() } catch {
            phase = .error("Failed to load speech models: \(error.localizedDescription)")
            return
        }

        let streams: (system: [Float], mic: [Float])
        do {
            streams = try AudioImporter.loadStereo16k(from: URL(fileURLWithPath: path))
        } catch {
            phase = .error("Couldn't read archived audio: \(error.localizedDescription)")
            return
        }

        phase = .processing("Re-identifying speakers…")
        let segments: [LiveSegment]
        do {
            segments = try await transcription.buildTranscript(
                systemSamples: streams.system, micSamples: streams.mic,
                expectedSpeakers: expectedSpeakers
            )
        } catch {
            phase = .error("Re-identification failed: \(error.localizedDescription)")
            return
        }

        // Replace the meeting's transcript segments.
        for seg in meeting.segments { context.delete(seg) }
        meeting.segments.removeAll()
        for seg in segments {
            let model = TranscriptSegment(start: seg.start, end: seg.end, speaker: seg.speaker, text: seg.text)
            model.meeting = meeting
            meeting.segments.append(model)
            context.insert(model)
        }
        // Keep only speaker names whose labels still exist; then auto-name afresh.
        let newLabels = Set(segments.map { $0.speaker })
        meeting.speakerNames = meeting.speakerNames.filter { newLabels.contains($0.key) }
        autoNameSpeakers(meeting, segments: segments)
        try? context.save()
        SemanticIndex(context: context).reindex(meeting)
        phase = .idle
    }

    /// Re-runs the summary on a finished meeting using the current identity
    /// settings (your name / role). Use after filling in "Your name" in Settings,
    /// or any time the summary got the speakers wrong. Leaves your edited notes
    /// untouched — only the Summary (overview, key points, action items) is redone.
    func regenerateSummary(for meeting: Meeting, context: ModelContext) async {
        guard phase == .idle, meeting.modelContext != nil else { return }
        let raw = meeting.transcriptText
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .error("There's no transcript to summarize for this meeting.")
            return
        }
        let identity = MeetingIdentity.preamble(knownSpeakers: meeting.speakerNames)
        let transcript = MeetingIdentity.ground(transcript: raw, userName: AppSettings.userName)

        phase = .processing("Regenerating summary…")
        do {
            let result = try await SummarizationService().summarize(
                transcript: transcript, title: meeting.title,
                attendees: meeting.attendeeNames, identity: identity)
            guard meeting.modelContext != nil else { phase = .idle; return }
            if let old = meeting.summary { context.delete(old) }
            let summary = Summary(text: result.text, actionItems: result.actionItems, keyPoints: result.keyPoints)
            context.insert(summary)
            meeting.summary = summary
            SafeStore.save(context, "resummarize")
            SemanticIndex(context: context).reindex(meeting)
            StoreBackup.snapshot(context: context)
            phase = .idle
        } catch {
            phase = .error("Couldn't regenerate the summary: \(error.localizedDescription)")
        }
    }

    func dismissError() {
        phase = .idle
    }
}
