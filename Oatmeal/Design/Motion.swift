import SwiftUI

/// A small, dependency-free motion toolkit shared across the app.
///
/// All animations are *reduce-motion aware*: every factory takes a `reduceMotion`
/// bool and returns `nil` when it's true, so a view can write
/// `.animation(Motion.reveal(reduceMotion), value: foo)` and automatically get a
/// calm, instant state for users who've asked the system to minimize motion.
///
/// Call sites pass `reduceMotion` in (read once from
/// `@Environment(\.accessibilityReduceMotion)`); this type never touches the
/// environment itself, which keeps it usable from anywhere — previews, helpers,
/// `ButtonStyle`s — without a SwiftUI view context.
enum Motion {

    // MARK: - Curated animations

    /// A gentle, settled spring. The everyday choice for layout/state changes.
    /// Returns `nil` under reduce-motion (the change applies instantly).
    static func gentle(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)
    }

    /// A quick, crisp reveal for appearing/disappearing content.
    static func reveal(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.25)
    }

    /// A bouncy pop for tactile, attention-drawing moments (badges, confirmations).
    /// Under reduce-motion this falls back to `nil` (no bounce).
    static func pop(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6)
    }

    /// A slow, looping ease-in-out for ambient "breathing" effects.
    /// Returns `nil` under reduce-motion so nothing loops.
    ///
    /// - Parameter period: full breath cycle length in seconds (one in-and-out).
    static func breathing(_ reduceMotion: Bool, period: Double = 3.2) -> Animation? {
        reduceMotion
            ? nil
            : .easeInOut(duration: period / 2).repeatForever(autoreverses: true)
    }

    // MARK: - Level helpers

    /// Maps a 0...1 input level to a smoothed scale factor in
    /// `[1, 1 + maxBoost]`, with a gentle ease so quiet input barely moves and
    /// loud input approaches the cap without overshooting.
    ///
    /// Under reduce-motion, callers should ignore this and stay at `1`.
    static func scale(forLevel level: Float, maxBoost: CGFloat = 0.18) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        // ease-out (sqrt-like) so low levels are visible but it saturates softly.
        let eased = 1 - pow(1 - clamped, 2)
        return 1 + eased * maxBoost
    }

    /// Maps a 0...1 input level to a glow/opacity strength in `[base, base+range]`,
    /// eased the same way as `scale(forLevel:)` for a consistent feel.
    static func glow(forLevel level: Float, base: CGFloat = 0.25, range: CGFloat = 0.55) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        let eased = 1 - pow(1 - clamped, 2)
        return base + eased * range
    }
}

extension View {
    /// Ergonomic wrapper around `.animation(_:value:)` that respects reduce-motion
    /// by passing the already-resolved (possibly `nil`) animation through.
    ///
    /// Usage: `.motion(Motion.reveal(reduceMotion), value: isOpen)`
    func motion<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        self.animation(animation, value: value)
    }
}
