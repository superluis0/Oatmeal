import Foundation
import AVFoundation

/// Plays a meeting's archived audio and tracks position for click-to-seek.
@MainActor
@Observable
final class AudioPlayer {
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    /// Playback speed; cycles through `speeds`. Persists across loads within a view.
    var rate: Float = 1.0
    private(set) var loadedPath: String?

    private let speeds: [Float] = [1.0, 1.25, 1.5, 2.0]

    func load(path: String) {
        guard path != loadedPath else { return }
        stop()
        let url = URL(fileURLWithPath: path)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.enableRate = true        // allow variable-speed playback
        player?.rate = rate
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
        loadedPath = path
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        player.enableRate = true
        player.play()
        player.rate = rate               // set after play() so the speed reliably applies
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    /// Halt playback and return to the start.
    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopTimer()
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(time, duration))
        currentTime = player.currentTime
    }

    /// Jump by a relative offset (negative = back), clamped to the clip.
    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func setRate(_ r: Float) {
        rate = r
        player?.rate = r                 // applies live when playing; stored otherwise
    }

    /// Step to the next preset playback speed (1× → 1.25× → 1.5× → 2× → 1×).
    func cycleSpeed() {
        let next = speeds.firstIndex(of: rate).map { speeds[($0 + 1) % speeds.count] } ?? 1.0
        setRate(next)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
