import SwiftUI

/// A breathing, audio-reactive recording indicator.
///
/// - When **recording**, it gently breathes (a slow ambient pulse) and its scale
///   + glow are modulated by the live input `level`, so it visibly "listens".
/// - When **reduce-motion** is on, it renders a calm, static orb — no looping or
///   large scaling — with only a barely-perceptible level-driven opacity shift.
/// - When **idle**, it shows a quiet resting dot.
///
/// Self-contained and cheap to draw: the per-frame `TimelineView(.animation)` body
/// only computes a couple of trig values and applies transforms — no allocations.
struct RecordOrb: View {
    /// Smoothed input level, 0...1.
    var level: Float
    /// Whether recording is active (drives breathing + reactivity).
    var isActive: Bool
    /// Base diameter of the resting orb, in points.
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isActive {
                if reduceMotion {
                    calmActiveOrb
                } else {
                    animatedOrb
                }
            } else {
                restingOrb
            }
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .accessibilityHidden(true)
    }

    // MARK: - Active (animated)

    private var animatedOrb: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Ambient breathing in [0,1] (full cycle ~3.2s), independent of audio.
            let breath = (sin(t * (2 * .pi / 3.2)) + 1) / 2
            // Audio reactivity on top of the breath.
            let levelScale = Motion.scale(forLevel: level, maxBoost: 0.22)
            let breathScale = 1 + CGFloat(breath) * 0.10
            let scale = breathScale * levelScale
            let glow = Motion.glow(forLevel: level, base: 0.30, range: 0.55)
                + CGFloat(breath) * 0.10

            orbCore
                .scaleEffect(scale)
                .shadow(color: Theme.danger.opacity(glow), radius: size * 0.7 * (1 + CGFloat(breath) * 0.4))
                // A soft outer halo that pulses with the level for the "listening" feel.
                .overlay(
                    Circle()
                        .stroke(Theme.danger.opacity(glow * 0.5), lineWidth: 1.5)
                        .scaleEffect(scale * (1.25 + Motion.scale(forLevel: level, maxBoost: 0.5) - 1))
                        .opacity(Double(0.5 + glow * 0.3))
                )
        }
    }

    /// Reduce-motion active state: static orb with a tiny opacity shift by level
    /// (no scaling, no looping), so it still reads as "live" without motion.
    private var calmActiveOrb: some View {
        orbCore
            .shadow(color: Theme.danger.opacity(0.35), radius: size * 0.5)
            .opacity(0.85 + Double(Motion.glow(forLevel: level, base: 0.0, range: 0.15)))
    }

    // MARK: - Idle

    private var restingOrb: some View {
        Circle()
            .fill(Theme.textTertiary.opacity(0.5))
            .frame(width: size * 0.85, height: size * 0.85)
            .overlay(
                Circle().strokeBorder(Theme.textTertiary.opacity(0.25), lineWidth: 1)
            )
    }

    // MARK: - Shared core

    private var orbCore: some View {
        Circle()
            .fill(Theme.recordGradient)
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            )
    }
}
