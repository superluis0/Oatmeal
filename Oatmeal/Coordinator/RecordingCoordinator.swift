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
    /// True when the in-progress recording can't capture system (meeting) audio in
    /// REMOTE mode — i.e. the other participants aren't being recorded. Surfaced
    /// prominently (main window + floating panel), unlike the soft `captureWarning`.
    private(set) var systemAudioMissing = false
    /// Set when a remote recording was requested without Screen Recording granted,
    /// so the UI can confirm before wasting a meeting on a mic-only capture.
    var pendingScreenRecordingDecision = false
    /// The event awaiting a "record anyway (mic only)" decision, replayed on resume.
    private var pendingEvent: UpcomingMeeting?
    /// Smoothed live input level in 0...1, driven by the mic+system sample flow.
    /// Used by audio-reactive UI (e.g. the record orb). Updated on the main actor.
    private(set) var audioLevel: Float = 0
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

    /// Warm the speech models in the background so the first **Record** tap is
    /// instant instead of waiting on a cold model load. `prepare()` is idempotent
    /// and guarded, so this is a cheap no-op once ready (or if a recording is
    /// already starting). Call only when models are known present (see
    /// `AppSettings.modelsPreparedBefore`) so we never trigger the first-run
    /// download ahead of the user choosing to record.
    func prewarm() {
        Task(priority: .utility) {
            // Let launch settle before pulling the models into memory.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard phase == .idle else { return }
            do { try await transcription.prepare() }
            catch { Log.warn("model prewarm failed (will retry on record): \(error.localizedDescription)", "recording") }
        }
    }

    // MARK: - Start

    func start(context: ModelContext, event: UpcomingMeeting? = nil, forceMicOnly: Bool = false) async {
        guard phase == .idle else { return }
        // Remote calls live or die on system audio (the other participants). If Screen
        // Recording isn't granted, don't silently fall back to a near-useless mic-only
        // recording — surface a decision first. Bring the main window forward so the
        // prompt is visible even when recording was triggered with no window open.
        if !forceMicOnly, !AppSettings.inPersonMode, !AudioCaptureEngine.hasScreenRecordingPermission {
            pendingEvent = event
            pendingScreenRecordingDecision = true
            MainWindowAccess.shared.show()
            return
        }
        Log.info("recording start requested", "recording")
        liveSegments = []
        liveMe = ""
        liveOthers = ""
        liveEnhanced = ""
        liveSuggestions = []
        lastAssistQuestion = ""
        lastAssistFire = nil
        captureWarning = nil
        systemAudioMissing = false

        // Permissions
        let micOK = await AudioCaptureEngine.requestMicrophoneAccess()
        guard micOK else {
            phase = .error("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
            return
        }

        phase = .preparingModels
        do {
            try await transcription.prepare()
            // Models are now on disk — safe to prewarm them on future launches.
            AppSettings.modelsPreparedBefore = true
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

        // Feed transcription AND drive the live audio level off the same sample
        // flow. Callbacks fire on the audio buffer queue, so the level update hops
        // to the main actor (see ingestLevel).
        engine.onMicSamples = { [weak self, transcription] samples in
            transcription.feedMic(samples)
            self?.ingestLevel(from: samples)
        }
        engine.onSystemSamples = { [weak self, transcription] samples in
            transcription.feedSystem(samples)
            self?.ingestLevel(from: samples)
        }

        do {
            try await engine.start()
        } catch {
            engine.onMicSamples = nil
            engine.onSystemSamples = nil
            await transcription.endStreaming()
            phase = .error(error.localizedDescription)
            return
        }
        // Surface either warning; the engine-fallback note (Nemotron → Parakeet)
        // is non-fatal and the recording proceeds normally.
        let engineNote = await transcription.takeLiveEngineNote()
        captureWarning = engine.systemCaptureWarning ?? engineNote
        // In remote mode, losing system audio means the other participants aren't
        // recorded — flag it for the prominent in-recording warning (not just the
        // soft strip). This also catches a stale grant that the pre-flight missed.
        systemAudioMissing = (engine.systemCaptureWarning != nil) && !AppSettings.inPersonMode

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

    /// Proceed with a recording the user chose to keep mic-only after being warned
    /// that Screen Recording is off.
    func startMicOnlyAfterPrompt(context: ModelContext) async {
        let event = pendingEvent
        pendingEvent = nil
        pendingScreenRecordingDecision = false
        await start(context: context, event: event, forceMicOnly: true)
    }

    /// Open macOS Screen Recording settings (and dismiss the decision prompt).
    func openScreenRecordingSettings() {
        pendingScreenRecordingDecision = false
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
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
        audioLevel = 0
        let (system, mic) = engine.stop()
        playChime("Pop")
        await transcription.endStreaming()
        let duration = startDate.map { Date().timeIntervalSince($0) } ?? elapsed

        guard let meeting = activeMeeting else {
            phase = .idle
            return
        }
        meeting.duration = duration

        // Save the raw audio FIRST — it's the durable source of truth. The transcript
        // and summary can always be rebuilt from it (see reprocessFromAudio), so even
        // if transcription/processing fails or the app is killed, the recording itself
        // is never lost. (saveAudio returns nil when there were no samples at all.)
        let hasAudio = !system.isEmpty || !mic.isEmpty
        if hasAudio {
            meeting.audioPath = saveAudio(system: system, mic: mic, meetingID: meeting.id)
            SafeStore.save(context, "audio-saved")
        }

        phase = .processing("Transcribing and identifying speakers…")
        let segments: [LiveSegment]
        do {
            segments = try await transcription.buildTranscript(
                systemSamples: system, micSamples: mic,
                expectedSpeakers: expectedSpeakerHint(for: meeting)
            )
        } catch {
            Log.error("transcription failed", "recording", error)
            // Clear active state so the next recording starts clean (a stale
            // startDate would inflate the next session's elapsed time).
            activeMeeting = nil
            startDate = nil
            // If any audio was captured it's already saved — KEEP the recording so
            // the user can re-run transcription from it ("Transcribe recording" in
            // the detail view). Never discard a recording that has audio.
            if hasAudio {
                if meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    meeting.notes = systemAudioMissing
                        ? "⚠️ Screen Recording was off, so the other participants weren't captured. The audio that was recorded is saved — if it has usable speech you can re-transcribe it below. To capture the other side next time: System Settings → Privacy & Security → Screen & System Audio Recording → turn on Oatmeal, then fully quit Oatmeal (menu-bar icon → Quit) and reopen it."
                        : "⚠️ This recording couldn't be transcribed (\(error.localizedDescription)). The audio is saved — use \"Transcribe recording\" to try again."
                }
                SafeStore.save(context, "transcription-failed-kept")
                phase = .error(systemAudioMissing
                    ? "No system audio (Screen Recording looks off) — your recording was kept; you can re-transcribe it from the meeting."
                    : "Couldn't transcribe the recording — it was kept. Open it and tap \"Transcribe recording\" to try again.")
                return
            }
            // No audio at all (e.g. a 0-second tap) — nothing to recover; drop the
            // empty shell unless the user typed notes.
            if meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && meeting.segments.isEmpty {
                // Signal the UI to drop this from `selection` BEFORE we invalidate it.
                lastDiscardedMeetingID = meeting.persistentModelID
                context.delete(meeting)
                SafeStore.save(context, "discard-empty-meeting")
            }
            phase = .error("No audio was captured for this recording.")
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

        // Audio was already archived up front. Commit the transcript NOW, before the
        // multi-second LLM step, so a crash/force-quit can't lose it — only the
        // summary would then need a redo (the detail view's banner offers that).
        SafeStore.save(context, "transcript-saved")

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

        // Capture the model-derived inputs on the main actor up front, then run the
        // two independent LLM calls — the summary (required) and note enhancement
        // (best-effort) — concurrently. At most two requests are in flight, which a
        // local server simply queues if it isn't running parallel slots (no downside
        // on a single-stream model, a real win on one that batches). Action-item
        // extraction stays after enhancement since it reads the enhanced notes.
        let title = meeting.title
        let attendees = meeting.attendeeNames
        let rawNotes = meeting.notes
        let template = await resolveTemplate(for: meeting, transcript: transcript, context: context)

        phase = .processing("Generating summary & notes…")
        async let summaryResult = SummarizationService().summarize(
            transcript: transcript, title: title, attendees: attendees, identity: identity)
        async let enhanceResult = NoteEnhancementService()
            .enhance(rawNotes: rawNotes, transcript: transcript, template: template, identity: identity)

        let result: MeetingSummary
        do {
            result = try await summaryResult
        } catch {
            _ = try? await enhanceResult   // drain the concurrent enhance before bailing
            Log.error("summarization failed (transcript kept)", "summary", error)
            phase = .error("Transcript saved, but summary failed: \(error.localizedDescription)")
            SafeStore.save(context, "summary-failed")
            SemanticIndex(context: context).reindex(meeting)
            return false
        }
        let summary = Summary(text: result.text, actionItems: result.actionItems, keyPoints: result.keyPoints)
        context.insert(summary)
        meeting.summary = summary
        // Stamp the transcript the summary was built from, so later speaker
        // fixes / edits can detect when it's gone stale.
        summary.transcriptSignature = meeting.currentSummarySignatureHash

        // Non-fatal: keep transcript + summary even if enhancement fails.
        meeting.templateName = template.name
        if let enhanced = try? await enhanceResult {
            meeting.enhancedNotes = enhanced.markdown
            meeting.noteBlocks = enhanced.blocks
        }

        // Structured action items (task + owner + due).
        phase = .processing("Extracting action items…")
        await extractActionItems(for: meeting, context: context)

        SafeStore.save(context, "process-meeting")
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
        SafeStore.save(context, "extract-action-items")
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

        // Commit the transcript before the LLM step so it survives a crash/quit.
        SafeStore.save(context, "transcript-saved")

        guard await summarizeAndEnhance(meeting: meeting, context: context) else { return }
        phase = .idle
    }

    /// Best-effort pre-fill of display names from the roster. Maps the diarized
    /// "Speaker N" labels (in order) onto the non-self expected speakers (in roster
    /// order). The note-taker is excluded — their speech is already labeled "Me".
    ///
    /// Two deliberate properties:
    /// - **Never bail on a count mismatch.** `zip` maps up to the smaller of the
    ///   two, so a near-miss (e.g. 3 detected voices vs 2 roster names) still names
    ///   what it can instead of leaving everything as "Speaker N". The wrap-up
    ///   confirm step (shown only when a voice is left unnamed — see
    ///   `Meeting.needsSpeakerConfirmation`) lets the user resolve the rest in one
    ///   tap each.
    /// - **Positional mapping is a GUESS**, not verified: label order is the
    ///   diarizer's discovery order and roster order is arbitrary, so even a clean
    ///   count match can be swapped. That's acceptable for a prefill the user
    ///   confirms; never treat these names as ground truth.
    ///
    /// Never overwrites a name the user already set (e.g. on the re-identify path).
    private func autoNameSpeakers(_ meeting: Meeting, segments: [LiveSegment]) {
        let labels = Set(segments.map { $0.speaker }.filter { $0.hasPrefix("Speaker ") })
            .sorted { lhs, rhs in
                (Int(lhs.dropFirst(8)) ?? 0) < (Int(rhs.dropFirst(8)) ?? 0)
            }
        let names = meeting.attendees
            .filter { $0.expectedToSpeak && !$0.isSelf }
            .map { $0.name }
        guard !labels.isEmpty, !names.isEmpty else { return }
        for (label, name) in zip(labels, names) where meeting.speakerNames[label] == nil {
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
        SafeStore.save(context, "mark-highlight")
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

    // MARK: - Live audio level

    /// Computes per-buffer RMS off the audio thread, then hops to the main actor
    /// to fold it into the smoothed, observable `audioLevel`. Mic and system both
    /// call this; whichever buffer is louder wins via the exponential smoother.
    nonisolated private func ingestLevel(from samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sumSquares: Double = 0
        for sample in samples { sumSquares += Double(sample) * Double(sample) }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        // Speech RMS is small; apply gain and clamp into 0...1.
        let gained = Float(min(rms * 6.0, 1.0))
        Task { @MainActor [weak self] in self?.applyLevel(gained) }
    }

    /// Exponentially smooths toward `target` so the orb glides instead of jittering.
    /// Rises fast (responsive to speech onset), falls slower (settles gracefully).
    private func applyLevel(_ target: Float) {
        guard isRecording else { audioLevel = 0; return }
        let rising = target > audioLevel
        let alpha: Float = rising ? 0.45 : 0.18
        audioLevel += (target - audioLevel) * alpha
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
            // Read the main-actor-isolated state inside the hop, not in the
            // Sendable timer closure (which can't safely touch actor state).
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
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
        seedAttendees(into: meeting, eventID: event.id, eventAttendees: event.attendees, context: context)
    }

    /// Seeds a new recording from a specific upcoming meeting the user chose
    /// (title, calendar id, attendees) — no calendar re-pick, so overlapping
    /// meetings can't cause the wrong one to be attached.
    private func seed(from event: UpcomingMeeting, into meeting: Meeting, context: ModelContext) {
        meeting.title = event.title
        meeting.calendarEventID = event.id
        seedAttendees(into: meeting, eventID: event.id, eventAttendees: event.attendees, context: context)
    }

    /// The saved pre-meeting prep for a calendar event, if the user opened the
    /// Prep sheet for it. Most recent wins should duplicates ever exist.
    private func savedPrep(for eventID: String?, context: ModelContext) -> MeetingPrep? {
        guard let eventID, !eventID.isEmpty else { return nil }
        var descriptor = FetchDescriptor<MeetingPrep>(
            predicate: #Predicate { $0.calendarEventID == eventID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Creates the meeting's attendees, preferring the pre-meeting prep roster
    /// (user-curated names, emails, who speaks) over the raw calendar invitees.
    /// Prep talking points seed the raw notes so live enhancement and the final
    /// summary pick them up.
    private func seedAttendees(into meeting: Meeting, eventID: String?,
                               eventAttendees: [EventAttendee], context: ModelContext) {
        if let prep = savedPrep(for: eventID, context: context) {
            for planned in prep.speakers {
                let trimmed = planned.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let attendee = Attendee(name: trimmed, email: planned.email)
                attendee.expectedToSpeak = planned.willSpeak
                attendee.isSelf = planned.isSelf
                context.insert(attendee)
                attendee.meeting = meeting
            }
            let notes = prep.prepNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty && meeting.notes.isEmpty {
                meeting.notes = notes
            }
        } else {
            for person in eventAttendees {
                let attendee = Attendee(name: person.name, email: person.email)
                attendee.isSelf = person.isSelf
                context.insert(attendee)
                attendee.meeting = meeting
            }
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

    /// Upper-bound speaker hint for diarization, drawn from the attendees who
    /// are expected to speak (nil when unknown, so the diarizer auto-detects).
    ///
    /// Remote calls: the other participants are on the SYSTEM stream while the
    /// note-taker is on the mic (labeled "Me"), so the hint — which constrains the
    /// system diarizer — must EXCLUDE self. Counting self here told the diarizer to
    /// find one extra speaker, over-splitting the others. In-person: everyone
    /// (including self) is on the mic, so count all expected speakers.
    /// Stays an upper bound (`maxSpeakers`), never a hard count: the roster is
    /// routinely wrong in both directions.
    private func expectedSpeakerHint(for meeting: Meeting) -> Int? {
        let expected = meeting.attendees.filter(\.expectedToSpeak)
        let n = AppSettings.inPersonMode ? expected.count
                                         : expected.filter { !$0.isSelf }.count
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
        SafeStore.save(context, "reidentify-speakers")
        SemanticIndex(context: context).reindex(meeting)
        phase = .idle
    }

    /// Rescue path: rebuild the transcript AND summary from a meeting's archived
    /// audio. The audio is the durable source of truth, so when the original run
    /// failed (LM Studio down, an interrupted/killed process, a transient model
    /// error, or no system audio) this re-runs the whole pipeline on the recording.
    func reprocessFromAudio(meeting: Meeting, context: ModelContext) async {
        guard phase == .idle, meeting.modelContext != nil else { return }
        guard let path = meeting.audioPath,
              FileManager.default.fileExists(atPath: path) else {
            phase = .error("This recording has no archived audio to re-process.")
            return
        }

        phase = .processing("Loading speech models…")
        do {
            try await transcription.prepare()
            AppSettings.modelsPreparedBefore = true
        } catch {
            phase = .error("Failed to load speech models: \(error.localizedDescription)")
            return
        }

        let streams: (system: [Float], mic: [Float])
        do {
            streams = try AudioImporter.loadStereo16k(from: URL(fileURLWithPath: path))
        } catch {
            phase = .error("Couldn't read the archived audio: \(error.localizedDescription)")
            return
        }

        phase = .processing("Transcribing the recording…")
        let segments: [LiveSegment]
        do {
            segments = try await transcription.buildTranscript(
                systemSamples: streams.system, micSamples: streams.mic,
                expectedSpeakers: expectedSpeakerHint(for: meeting))
        } catch {
            phase = .error("Couldn't transcribe this recording — it may not contain usable speech.")
            return
        }

        // Replace any existing (usually empty) transcript with the rebuilt one.
        for seg in meeting.segments { context.delete(seg) }
        meeting.segments.removeAll()
        for seg in segments {
            let model = TranscriptSegment(start: seg.start, end: seg.end, speaker: seg.speaker, text: seg.text)
            model.meeting = meeting
            meeting.segments.append(model)
            context.insert(model)
        }
        let newLabels = Set(segments.map { $0.speaker })
        meeting.speakerNames = meeting.speakerNames.filter { newLabels.contains($0.key) }
        autoNameSpeakers(meeting, segments: segments)
        SafeStore.save(context, "reprocess-transcript")

        // …then (re)build the summary + notes from the rebuilt transcript.
        let ok = await summarizeAndEnhance(meeting: meeting, context: context)
        if ok { phase = .idle }   // on failure, summarizeAndEnhance leaves phase = .error
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
            // Point the meeting at the new summary BEFORE deleting the old one:
            // the moment context.delete() runs, any in-flight view render that
            // reads the old Summary's properties traps. Reordering keeps
            // meeting.summary valid at every observable step.
            let old = meeting.summary
            let summary = Summary(text: result.text, actionItems: result.actionItems, keyPoints: result.keyPoints)
            context.insert(summary)
            meeting.summary = summary
            summary.transcriptSignature = meeting.currentSummarySignatureHash
            if let old { context.delete(old) }
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
