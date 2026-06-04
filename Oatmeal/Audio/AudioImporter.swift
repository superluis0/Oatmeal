import Foundation
import AVFoundation

/// Decodes a pre-recorded audio file to 16 kHz mono Float32 for transcription.
enum AudioImporter {
    static func loadMono16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer)
        guard let resampler = Resampler(inputFormat: format, targetSampleRate: 16_000) else {
            return []
        }
        return resampler.resample(buffer) ?? []
    }

    /// Loads a stereo archive (left = system, right = mic) as two 16 kHz mono
    /// streams for re-diarization. A mono file is returned as (system, []) so the
    /// caller can still re-run, just without the Me/Others split.
    static func loadStereo16k(from url: URL) throws -> (system: [Float], mic: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return ([], [])
        }
        try file.read(into: buffer)

        guard format.channelCount >= 2, let chans = buffer.floatChannelData else {
            return (try loadMono16k(from: url), [])
        }
        let n = Int(buffer.frameLength)
        let leftSrc = Array(UnsafeBufferPointer(start: chans[0], count: n))
        let rightSrc = Array(UnsafeBufferPointer(start: chans[1], count: n))
        return (resampleMono(leftSrc, from: format.sampleRate),
                resampleMono(rightSrc, from: format.sampleRate))
    }

    /// Resamples a single mono channel (given at `sourceRate`) to 16 kHz.
    private static func resampleMono(_ samples: [Float], from sourceRate: Double) -> [Float] {
        guard !samples.isEmpty,
              let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                          channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buf.floatChannelData else { return [] }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in dst[0].update(from: src.baseAddress!, count: samples.count) }
        guard let resampler = Resampler(inputFormat: monoFmt, targetSampleRate: 16_000) else { return [] }
        return resampler.resample(buf) ?? []
    }
}
