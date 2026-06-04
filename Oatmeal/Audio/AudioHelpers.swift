import Foundation
import AVFoundation
import CoreMedia

extension CMSampleBuffer {
    /// Converts an audio CMSampleBuffer into an AVAudioPCMBuffer.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let format = AVAudioFormat(streamDescription: asbd)
        guard let format else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}

/// Streaming resampler: converts arbitrary-format PCM buffers to mono Float32 at a target rate.
final class Resampler {
    private let converter: AVAudioConverter
    let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat, targetSampleRate: Double) {
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func resample(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard input.frameLength > 0 else { return [] }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 2048)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return input
        }

        guard status != .error, let channel = output.floatChannelData else { return nil }
        let n = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: channel[0], count: n))
    }
}

enum WavWriter {
    /// Writes 16 kHz mono Float32 samples to a WAV file at `url`.
    static func write(samples: [Float], to url: URL, sampleRate: Double = 16_000) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "WavWriter", code: 1)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunk: AVAudioFrameCount = 16_000
        var offset = 0
        while offset < samples.count {
            let count = min(Int(chunk), samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            if let dst = buffer.floatChannelData {
                samples.withUnsafeBufferPointer { src in
                    dst[0].update(from: src.baseAddress!.advanced(by: offset), count: count)
                }
            }
            try file.write(from: buffer)
            offset += count
        }
    }

    /// Writes a 2-channel WAV (left + right) at `sampleRate`. Oatmeal uses this to
    /// archive system audio on the left and mic on the right, so a recording can
    /// later be re-diarized with the two streams separated. AVAudioPlayer plays it
    /// back as a normal stereo mix.
    static func write(left: [Float], right: [Float], to url: URL, sampleRate: Double = 16_000) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw NSError(domain: "WavWriter", code: 1)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = max(left.count, right.count)
        let chunk = 16_000
        var offset = 0
        while offset < total {
            let count = min(chunk, total - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            if let dst = buffer.floatChannelData {
                for i in 0..<count {
                    let idx = offset + i
                    dst[0][i] = idx < left.count ? left[idx] : 0
                    dst[1][i] = idx < right.count ? right[idx] : 0
                }
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}
