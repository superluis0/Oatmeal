import Foundation
import AVFoundation
import FluidAudio

struct LiveSegment: Identifiable, Sendable {
    let id = UUID()
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

/// Which capture source a live caption update came from.
enum LiveSource: Sendable {
    case me
    case others
}

/// A streaming caption update: the full running text for one source.
struct LiveUpdate: Sendable {
    let source: LiveSource
    let text: String
}

/// Wraps FluidAudio ASR (Parakeet): real-time sliding-window streaming for live
/// captions, plus an offline speaker-diarized pass for the final transcript.
actor TranscriptionService {

    enum ServiceError: LocalizedError {
        case notReady
        var errorDescription: String? { "Speech models are not loaded yet." }
    }

    private var models: AsrModels?
    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    private var isPreparing = false

    // Streaming (live captions)
    private var micStream: SlidingWindowAsrManager?
    private var systemStream: SlidingWindowAsrManager?
    private var streamTasks: [Task<Void, Never>] = []
    nonisolated(unsafe) private var micFeed: AsyncStream<[Float]>.Continuation?
    nonisolated(unsafe) private var systemFeed: AsyncStream<[Float]>.Continuation?
    private var updateFeed: AsyncStream<LiveUpdate>.Continuation?

    // Parakeet v2 uses blank token id 1024 (v3 default is 8192). Tuned for snappier
    // captions than the stock `.streaming` preset: shorter chunk + lookahead and a
    // faster hypothesis cadence so volatile text appears sooner.
    private static let v2Config = SlidingWindowAsrConfig(
        chunkSeconds: 8.0,
        hypothesisChunkSeconds: 0.5,
        leftContextSeconds: 2.0,
        rightContextSeconds: 1.0,
        minContextForConfirmation: 6.0,
        confirmationThreshold: 0.80,
        tdtConfig: TdtConfig(blankId: 1024)
    )

    // v3 (multilingual) uses the default blank token id (8192).
    private static let v3Config = SlidingWindowAsrConfig(
        chunkSeconds: 8.0,
        hypothesisChunkSeconds: 0.5,
        leftContextSeconds: 2.0,
        rightContextSeconds: 1.0,
        minContextForConfirmation: 6.0,
        confirmationThreshold: 0.80
    )

    private var loadedVersion: String?
    private var streamConfig: SlidingWindowAsrConfig {
        loadedVersion == "v3" ? Self.v3Config : Self.v2Config
    }

    var isReady: Bool { asr != nil && diarizer != nil }

    /// Downloads (first run) and loads the Parakeet + diarization models. Reuses
    /// Spokenly's already-downloaded model when present to skip the download.
    /// Reloads if the user switched model version (v2 ↔ v3).
    func prepare() async throws {
        let desired = AppSettings.modelVersion
        if isReady && loadedVersion == desired { return }
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        if loadedVersion != desired {
            asr = nil
            models = nil
        }

        if desired == "v2" { ModelProvisioner.provisionParakeetIfNeeded() }

        let models = try await AsrModels.downloadAndLoad(version: desired == "v3" ? .v3 : .v2)
        self.models = models

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asr = manager

        if diarizer == nil {
            let diar = OfflineDiarizerManager(config: .default)
            try await diar.prepareModels()
            self.diarizer = diar
        }

        loadedVersion = desired
    }

    // MARK: - Live streaming captions

    /// Starts two sliding-window ASR streams (mic → "Me", system → "Others") and
    /// returns a stream of running-text updates. Feed audio via `feedMic`/`feedSystem`.
    func beginStreaming() async throws -> AsyncStream<LiveUpdate> {
        guard let models else { throw ServiceError.notReady }

        let config = streamConfig
        let mic = SlidingWindowAsrManager(config: config)
        try await mic.loadModels(models)
        try await mic.startStreaming(source: .microphone)

        let sys = SlidingWindowAsrManager(config: config)
        try await sys.loadModels(models)
        try await sys.startStreaming(source: .system)

        self.micStream = mic
        self.systemStream = sys

        let (micIn, micCont) = AsyncStream<[Float]>.makeStream()
        let (sysIn, sysCont) = AsyncStream<[Float]>.makeStream()
        self.micFeed = micCont
        self.systemFeed = sysCont

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let (updates, updateCont) = AsyncStream<LiveUpdate>.makeStream()
        self.updateFeed = updateCont

        // Feed audio into the managers in arrival order.
        let micFeeder = Task {
            for await samples in micIn {
                if let buffer = Self.makeBuffer(samples, format: format) {
                    await mic.streamAudio(buffer)
                }
            }
        }
        let sysFeeder = Task {
            for await samples in sysIn {
                if let buffer = Self.makeBuffer(samples, format: format) {
                    await sys.streamAudio(buffer)
                }
            }
        }
        // Forward running transcripts to the UI.
        let micConsumer = Task {
            for await _ in await mic.transcriptionUpdates {
                updateCont.yield(LiveUpdate(source: .me, text: await Self.runningText(mic)))
            }
        }
        let sysConsumer = Task {
            for await _ in await sys.transcriptionUpdates {
                updateCont.yield(LiveUpdate(source: .others, text: await Self.runningText(sys)))
            }
        }

        streamTasks = [micFeeder, sysFeeder, micConsumer, sysConsumer]
        return updates
    }

    /// Push newly captured 16 kHz mono samples into the live streams. Safe to call
    /// from the audio capture queue; ordering is preserved per source.
    nonisolated func feedMic(_ samples: [Float]) { micFeed?.yield(samples) }
    nonisolated func feedSystem(_ samples: [Float]) { systemFeed?.yield(samples) }

    /// Tears down the live streams (called on stop).
    func endStreaming() async {
        micFeed?.finish()
        systemFeed?.finish()
        updateFeed?.finish()
        updateFeed = nil
        _ = try? await micStream?.finish()
        _ = try? await systemStream?.finish()
        await micStream?.cleanup()
        await systemStream?.cleanup()
        for task in streamTasks { task.cancel() }
        streamTasks.removeAll()
        micStream = nil
        systemStream = nil
        micFeed = nil
        systemFeed = nil
    }

    private static func runningText(_ manager: SlidingWindowAsrManager) async -> String {
        let confirmed = await manager.confirmedTranscript
        let volatileText = await manager.volatileTranscript
        return [confirmed, volatileText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // MARK: - Final pass (diarized, speaker-attributed)

    /// Builds the authoritative transcript: diarizes each source, then transcribes
    /// each speaker turn. Microphone turns are labeled "Me"; system turns become
    /// "Speaker 1", "Speaker 2", ... merged and time-ordered.
    func buildTranscript(
        systemSamples: [Float],
        micSamples: [Float],
        expectedSpeakers: Int? = nil
    ) async throws -> [LiveSegment] {
        guard let asr else { throw ServiceError.notReady }
        let inPerson = AppSettings.inPersonMode
        // Apply the speaker-count hint to whichever stream actually carries
        // multiple people: the system stream on remote calls, or the mic in
        // in-person mode. The other stream uses the default auto-detecting config.
        let micDiar = try await makeDiarizer(maxSpeakers: inPerson ? expectedSpeakers : nil)
        let sysDiar = try await makeDiarizer(maxSpeakers: inPerson ? nil : expectedSpeakers)
        var segments: [LiveSegment] = []
        var labelMap: [String: String] = [:]
        var nextIndex = 1
        func label(for key: String) -> String {
            if let existing = labelMap[key] { return existing }
            let label = "Speaker \(nextIndex)"
            labelMap[key] = label
            nextIndex += 1
            return label
        }

        // Microphone => "Me" normally, or diarized speakers when in-person mode is on.
        var micSegments: [LiveSegment] = []
        if micSamples.count > 1_600 {
            let micResult = try await micDiar.process(audio: micSamples)
            for turn in micResult.segments {
                let speaker = inPerson ? label(for: "mic-\(turn.speakerId)") : "Me"
                if let seg = try await transcribeTurn(
                    asr: asr, samples: micSamples,
                    start: Double(turn.startTimeSeconds), end: Double(turn.endTimeSeconds),
                    speaker: speaker
                ) {
                    micSegments.append(seg)
                }
            }
        }

        // System => Speaker N
        var sysSegments: [LiveSegment] = []
        if systemSamples.count > 1_600 {
            let sysResult = try await sysDiar.process(audio: systemSamples)
            for turn in sysResult.segments {
                if let seg = try await transcribeTurn(
                    asr: asr, samples: systemSamples,
                    start: Double(turn.startTimeSeconds), end: Double(turn.endTimeSeconds),
                    speaker: label(for: "sys-\(turn.speakerId)")
                ) {
                    sysSegments.append(seg)
                }
            }
        }

        // Acoustic-echo dedup: when recording without headphones, the other
        // party's audio plays out the speakers and bleeds into the mic, so it
        // gets transcribed a SECOND time and mislabeled as "Me". The system
        // stream already holds the clean copy, so drop any mic segment that
        // overlaps a system segment in time AND closely matches its text.
        // (Only in remote mode — in-person mode has no system playback to echo.)
        if !inPerson && !sysSegments.isEmpty {
            let before = micSegments.count
            micSegments = micSegments.filter { mic in
                !Self.isEcho(of: mic, in: sysSegments)
            }
            let dropped = before - micSegments.count
            if dropped > 0 { Log.info("echo dedup: dropped \(dropped) mic echo segment(s)", "transcription") }
        }

        segments = micSegments + sysSegments
        return segments.sorted { $0.start < $1.start }
    }

    /// A mic segment is echo if some system segment overlaps it in time (with a
    /// little slack for echo delay) and the two share most of their words.
    private static func isEcho(of mic: LiveSegment, in sysSegments: [LiveSegment]) -> Bool {
        let micWords = significantWords(mic.text)
        // Don't drop short interjections ("yeah", "right") on a coincidental match.
        guard micWords.count >= 4 else { return false }
        let slack = 1.5 // seconds — echo lags the source slightly
        for sys in sysSegments {
            let overlaps = mic.start < sys.end + slack && sys.start < mic.end + slack
            guard overlaps else { continue }
            let sysWords = significantWords(sys.text)
            guard !sysWords.isEmpty else { continue }
            // Overlap coefficient: |shared| / min(|a|,|b|). Robust to the echo
            // copy being garbled/longer than the clean source.
            let shared = micWords.intersection(sysWords).count
            let coeff = Float(shared) / Float(min(micWords.count, sysWords.count))
            if coeff >= 0.6 { return true }
        }
        return false
    }

    private static let echoFiller: Set<String> = [
        "um", "uh", "you", "know", "like", "i", "it", "its", "the", "a", "an",
        "and", "so", "to", "of", "is", "in", "that", "this", "we", "yeah"
    ]

    /// Lowercased content words (filler/stopwords removed) for fuzzy text matching.
    private static func significantWords(_ text: String) -> Set<String> {
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(tokens.filter { $0.count > 1 && !echoFiller.contains($0) })
    }

    /// Returns the shared default diarizer when no hint is given, or a freshly
    /// configured one that caps the speaker count (reduces over-splitting and
    /// mid-turn label flips). A slightly larger merge gap also stabilizes turns.
    private func makeDiarizer(maxSpeakers: Int?) async throws -> OfflineDiarizerManager {
        guard let maxSpeakers, maxSpeakers > 0 else {
            guard let diarizer else { throw ServiceError.notReady }
            return diarizer
        }
        var clustering = OfflineDiarizerConfig.Clustering.community
        clustering.maxSpeakers = maxSpeakers
        var post = OfflineDiarizerConfig.PostProcessing.community
        post.minGapDurationSeconds = max(post.minGapDurationSeconds, 0.25)
        let config = OfflineDiarizerConfig(clustering: clustering, postProcessing: post)
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        return manager
    }

    private func transcribeTurn(
        asr: AsrManager,
        samples: [Float],
        start: Double,
        end: Double,
        speaker: String
    ) async throws -> LiveSegment? {
        let sampleRate = 16_000.0
        let from = max(0, Int(start * sampleRate))
        let to = min(samples.count, Int(end * sampleRate))
        guard to - from > 1_600 else { return nil }
        let slice = Array(samples[from..<to])
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(slice, decoderState: &state)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LiveSegment(start: start, end: end, speaker: speaker, text: text)
    }
}
