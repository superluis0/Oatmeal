import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

/// Captures system (meeting) audio via ScreenCaptureKit and microphone audio via
/// AVAudioEngine, resampling both to 16 kHz mono Float32 for Parakeet.
final class AudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    enum CaptureError: LocalizedError {
        case screenRecordingDenied
        case noDisplay
        case streamFailed(String)

        var errorDescription: String? {
            switch self {
            case .screenRecordingDenied:
                return "Screen Recording permission is required to capture meeting audio. Grant it in System Settings → Privacy & Security → Screen Recording, then relaunch Oatmeal."
            case .noDisplay:
                return "No display available for audio capture."
            case .streamFailed(let m):
                return "Audio capture failed: \(m)"
            }
        }
    }

    private let sampleRate: Double = 16_000

    private var stream: SCStream?
    private let audioEngine = AVAudioEngine()

    private var systemResampler: Resampler?
    private var micResampler: Resampler?

    // Accumulated 16 kHz mono samples for each source.
    private(set) var systemSamples: [Float] = []
    private(set) var micSamples: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.oatmeal.audio.buffer")

    private(set) var isRunning = false

    /// Set when system-audio capture couldn't start (e.g. Screen Recording denied).
    /// Non-fatal: the mic still records. Surfaced to the UI as a soft warning.
    private(set) var systemCaptureWarning: String?

    private var micBufferCount = 0
    private var systemBufferCount = 0

    /// Called on the audio buffer queue with each newly resampled 16 kHz mono chunk,
    /// for live streaming transcription. Calls are serialized per source.
    var onMicSamples: (@Sendable ([Float]) -> Void)?
    var onSystemSamples: (@Sendable ([Float]) -> Void)?

    // MARK: - Permissions

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Triggers the Screen Recording permission prompt and reports whether it's
    /// usable (a display is enumerable). May require a relaunch on first grant.
    static func requestScreenRecordingAccess() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }

    /// Non-prompting check of whether Screen Recording is currently granted to this
    /// app — unlike `requestScreenRecordingAccess()`, this never shows a system
    /// dialog, so it's safe to call before a recording to decide whether to warn.
    /// Note: a grant that's enabled in System Settings but needs a relaunch to take
    /// effect can still read as granted here — the runtime capture check is the
    /// reliable backstop for that case.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers / verifies the Screen Recording permission and returns a usable display filter.
    private func makeContentFilter() async throws -> (SCContentFilter, SCDisplay) {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { throw CaptureError.noDisplay }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            return (filter, display)
        } catch let error as CaptureError {
            throw error
        } catch {
            // SCShareableContent throws when Screen Recording permission is missing.
            throw CaptureError.screenRecordingDenied
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isRunning else { return }
        bufferQueue.sync {
            systemSamples.removeAll(keepingCapacity: false)
            micSamples.removeAll(keepingCapacity: false)
            micBufferCount = 0
            systemBufferCount = 0
        }
        systemCaptureWarning = nil

        // Mic is the primary source — fatal if it can't start.
        try startMicCapture()

        // System (meeting) audio is best-effort: if Screen Recording is denied or
        // the stream fails, keep recording the mic instead of aborting everything.
        do {
            try await startSystemCapture()
        } catch {
            systemCaptureWarning = (error as? CaptureError)?.errorDescription ?? error.localizedDescription
            NSLog("[Oatmeal] system capture failed (continuing mic-only): \(error)")
        }

        isRunning = true
    }

    func stop() -> (system: [Float], mic: [Float]) {
        guard isRunning else { return ([], []) }
        isRunning = false

        if let stream {
            stream.stopCapture { _ in }
        }
        stream = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        let result: (system: [Float], mic: [Float]) = bufferQueue.sync { (systemSamples, micSamples) }
        NSLog("[Oatmeal] capture stopped — mic=\(result.mic.count) samples (\(String(format: "%.1f", Double(result.mic.count)/sampleRate))s), system=\(result.system.count) samples (\(String(format: "%.1f", Double(result.system.count)/sampleRate))s)")
        return result
    }

    /// Snapshot of samples captured so far (for live transcription).
    func snapshot() -> (system: [Float], mic: [Float]) {
        bufferQueue.sync { (systemSamples, micSamples) }
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemCapture() async throws {
        let (filter, _) = try await makeContentFilter()

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // We do not need video; keep it tiny and slow to minimize cost.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: bufferQueue)
        do {
            try await stream.startCapture()
            NSLog("[Oatmeal] system audio capture started")
        } catch {
            throw CaptureError.streamFailed(error.localizedDescription)
        }
        self.stream = stream
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let input = audioEngine.inputNode

        // Honor the user's chosen input device (empty UID => system default).
        let uid = AppSettings.inputDeviceUID
        if !uid.isEmpty, let deviceID = AudioDevices.deviceID(forUID: uid) {
            do {
                try input.auAudioUnit.setDeviceID(deviceID)
                NSLog("[Oatmeal] mic device set to UID \(uid) (id \(deviceID))")
            } catch {
                NSLog("[Oatmeal] failed to set mic device \(uid): \(error)")
            }
        } else {
            NSLog("[Oatmeal] using system default input device (uid=\(uid.isEmpty ? "default" : uid))")
        }

        // Use the node's OUTPUT format for the tap (what it will actually deliver);
        // the input hardware format can be momentarily 0ch/0Hz right after a
        // permission grant, which silently drops all audio.
        let tapFormat = input.outputFormat(forBus: 0)
        NSLog("[Oatmeal] mic tap format: \(tapFormat.sampleRate)Hz \(tapFormat.channelCount)ch (input hw: \(input.inputFormat(forBus: 0).sampleRate)Hz \(input.inputFormat(forBus: 0).channelCount)ch)")

        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw CaptureError.streamFailed("Microphone has no usable input format (\(tapFormat.sampleRate)Hz, \(tapFormat.channelCount)ch). Check the input device in System Settings → Sound.")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Build the resampler lazily from the ACTUAL delivered buffer format.
            if self.micResampler == nil {
                self.micResampler = Resampler(inputFormat: buffer.format, targetSampleRate: self.sampleRate)
                NSLog("[Oatmeal] mic resampler created: \(buffer.format.sampleRate)Hz \(buffer.format.channelCount)ch -> 16kHz mono (ok=\(self.micResampler != nil))")
            }
            guard let resampler = self.micResampler, let floats = resampler.resample(buffer) else { return }
            self.bufferQueue.async {
                self.micSamples.append(contentsOf: floats)
                self.micBufferCount += 1
                if self.micBufferCount == 1 || self.micBufferCount % 50 == 0 {
                    NSLog("[Oatmeal] mic buffers=\(self.micBufferCount) totalSamples=\(self.micSamples.count) (\(String(format: "%.1f", Double(self.micSamples.count)/self.sampleRate))s)")
                }
                self.onMicSamples?(floats)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            NSLog("[Oatmeal] audioEngine started")
        } catch {
            NSLog("[Oatmeal] audioEngine.start() failed: \(error)")
            throw CaptureError.streamFailed("Couldn't start the microphone engine: \(error.localizedDescription)")
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcm = sampleBuffer.toPCMBuffer() else { return }

        if systemResampler == nil {
            systemResampler = Resampler(inputFormat: pcm.format, targetSampleRate: sampleRate)
        }
        guard let resampler = systemResampler, let floats = resampler.resample(pcm) else { return }
        // Already on bufferQueue (sampleHandlerQueue).
        systemSamples.append(contentsOf: floats)
        systemBufferCount += 1
        if systemBufferCount == 1 || systemBufferCount % 50 == 0 {
            NSLog("[Oatmeal] system buffers=\(systemBufferCount) totalSamples=\(systemSamples.count) (\(String(format: "%.1f", Double(systemSamples.count)/sampleRate))s) srcFmt=\(pcm.format.sampleRate)Hz \(pcm.format.channelCount)ch")
        }
        onSystemSamples?(floats)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
    }
}
