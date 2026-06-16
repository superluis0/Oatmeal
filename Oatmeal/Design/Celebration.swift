import SwiftUI

/// A reusable, one-shot celebration overlay: a brief confetti burst for genuinely
/// happy moments (a meeting saved). Self-contained and dependency-free.
///
/// Design contract:
/// - Bounded particle count, drawn in a single `Canvas` driven by a `TimelineView`
///   that **only ticks while the burst is alive**. When the burst finishes the
///   `TimelineView` is removed from the tree entirely, so nothing keeps animating.
/// - Reduce-motion aware: under reduce-motion there are **no particles**. Instead a
///   calm, motion-free checkmark badge fades in and out once, then removes itself.
/// - Fire-once API via `View.celebration(trigger:)`: increment/raise the trigger to
///   play. The modifier auto-resets when the burst completes.
///
/// The colors blend the user's accent/gradient with a few festive hues so it feels
/// on-brand rather than generic.

// MARK: - Particle model

private struct ConfettiParticle {
    var x: CGFloat          // 0...1 normalized horizontal origin
    var vx: CGFloat         // horizontal velocity (points/sec)
    var vy: CGFloat         // initial vertical velocity (points/sec, negative = up)
    var size: CGFloat       // edge length (points)
    var color: Color
    var rotation: Double    // initial rotation (radians)
    var spin: Double        // angular velocity (radians/sec)
    var drift: CGFloat      // sideways sway amplitude (points)
    var driftRate: Double   // sway frequency (radians/sec)
    var isCircle: Bool
}

// MARK: - Burst view (motion path)

/// The actual confetti animation. Only instantiated while a burst is in flight.
private struct ConfettiBurst: View {
    /// Total burst lifetime in seconds; after this the parent tears the view down.
    let duration: Double
    /// Called once when the burst has fully completed (used to remove the view).
    let onComplete: () -> Void

    @State private var start = Date()
    @State private var particles: [ConfettiParticle] = []
    @State private var finished = false

    private let gravity: CGFloat = 820   // points/sec^2

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Canvas { ctx, size in
                guard elapsed >= 0 else { return }
                for p in particles {
                    let t = CGFloat(elapsed)
                    // Position: projectile motion + a gentle horizontal sway.
                    let sway = p.drift * CGFloat(sin(p.driftRate * elapsed))
                    let px = p.x * size.width + p.vx * t + sway
                    let py = size.height * 0.46 + p.vy * t + 0.5 * gravity * t * t

                    // Fade out over the back half of the burst.
                    let progress = min(max(elapsed / duration, 0), 1)
                    let alpha = 1 - pow(progress, 2.2)
                    guard alpha > 0.01, py < size.height + p.size else { continue }

                    let angle = p.rotation + p.spin * elapsed
                    var transform = ctx
                    transform.translateBy(x: px, y: py)
                    transform.rotate(by: .radians(angle))
                    transform.opacity = alpha

                    let rect = CGRect(x: -p.size / 2, y: -p.size / 2,
                                      width: p.size, height: p.size * (p.isCircle ? 1 : 0.62))
                    let shape: Path = p.isCircle
                        ? Path(ellipseIn: rect)
                        : Path(roundedRect: rect, cornerRadius: 1.5)
                    transform.fill(shape, with: .color(p.color))
                }
            }
            .allowsHitTesting(false)
            .onChange(of: timeline.date) { _, now in
                // Mark completion exactly once, then let the parent drop the view.
                if !finished, now.timeIntervalSince(start) >= duration {
                    finished = true
                    onComplete()
                }
            }
        }
        .onAppear {
            start = Date()
            particles = Self.makeParticles()
        }
    }

    /// Build a bounded set of particles (~64) once, at burst start.
    private static func makeParticles() -> [ConfettiParticle] {
        let palette: [Color] = [
            Theme.accent,
            Theme.accentDeep,
            Color(hex: 0xF4B65C),   // honey
            Color(hex: 0xE08A3C),   // amber
            Color(hex: 0x5C9A6B),   // festive green
            Color(hex: 0x6FA8DC),   // sky
            Color(hex: 0xE2654E)    // warm coral
        ]
        let count = 64
        return (0..<count).map { _ in
            ConfettiParticle(
                x: CGFloat.random(in: 0.28...0.72),
                vx: CGFloat.random(in: -260...260),
                vy: CGFloat.random(in: -640 ... -360),
                size: CGFloat.random(in: 6...12),
                color: palette.randomElement() ?? Theme.accent,
                rotation: Double.random(in: 0...(2 * .pi)),
                spin: Double.random(in: -7...7),
                drift: CGFloat.random(in: 6...22),
                driftRate: Double.random(in: 2.2...4.5),
                isCircle: Bool.random()
            )
        }
    }
}

// MARK: - Reduce-motion acknowledgement

/// A calm, motion-free substitute shown under reduce-motion: a soft checkmark
/// badge that fades in then out once, with no particles or springs.
private struct CalmAcknowledgement: View {
    let onComplete: () -> Void
    @State private var shown = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 56, weight: .semibold))
            .foregroundStyle(Theme.success)
            .padding(Theme.Space.lg)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear {
                // Fade in, hold briefly, fade out — no movement, no spring.
                withAnimation(.easeOut(duration: 0.25)) { shown = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeIn(duration: 0.35)) { shown = false }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    onComplete()
                }
            }
    }
}

// MARK: - Overlay + modifier

/// Plays a one-shot celebration whenever `trigger` changes to a new value.
/// Pure overlay — never intercepts hit-testing, never lingers after the burst.
private struct CelebrationModifier: ViewModifier {
    let trigger: Int
    var duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The currently-playing instance, keyed so a re-trigger restarts cleanly.
    @State private var activeID: Int?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let id = activeID {
                    Group {
                        if reduceMotion {
                            CalmAcknowledgement(onComplete: { clear(id) })
                        } else {
                            ConfettiBurst(duration: duration, onComplete: { clear(id) })
                        }
                    }
                    .id(id)
                    .transition(.identity)
                }
            }
            .onChange(of: trigger) { _, newValue in
                // Only fire on a genuine new trigger (skip the initial 0 state).
                guard newValue > 0 else { return }
                activeID = newValue
            }
    }

    private func clear(_ id: Int) {
        // Guard against a stale completion clearing a newer burst.
        if activeID == id { activeID = nil }
    }
}

// MARK: - Update-available attention pulse

/// A gentle, tasteful attention pulse for an "update available" affordance: a soft
/// breathing glow with a barely-there scale, so a new release gets noticed without
/// being jarring. Under reduce-motion it renders fully static (no glow, no scale).
///
/// The pulse is intentionally calm and uses `Motion.breathing` so it shares the
/// app's ambient-motion feel. It runs only while the affordance is on screen.
private struct UpdatePulse: ViewModifier {
    /// Tint for the surrounding glow (usually the accent).
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (pulsing ? 1.04 : 1))
            .shadow(color: reduceMotion ? .clear : tint.opacity(pulsing ? 0.55 : 0.0),
                    radius: pulsing ? 9 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.breathing(false, period: 2.6)) {
                    pulsing = true
                }
            }
    }
}

extension View {
    /// A subtle, reduce-motion-aware breathing glow/scale to draw the eye to an
    /// "update available" badge or label. Static under reduce-motion.
    func updatePulse(tint: Color = Theme.accent) -> some View {
        modifier(UpdatePulse(tint: tint))
    }

    /// Play a one-shot celebration when `trigger` increases.
    ///
    /// Drive it by incrementing an `Int` (`celebrationTick += 1`) at the happy
    /// moment. Under reduce-motion this renders a calm checkmark instead of
    /// confetti. The effect fully tears down when finished.
    ///
    /// - Parameters:
    ///   - trigger: a monotonically increasing counter; each new value plays once.
    ///   - duration: confetti lifetime in seconds (default 1.5).
    func celebration(trigger: Int, duration: Double = 1.5) -> some View {
        modifier(CelebrationModifier(trigger: trigger, duration: duration))
    }
}

// MARK: - Milestones

/// A milestone congratulation shown (with confetti) at meeting-count milestones.
struct MilestoneMessage: Equatable {
    let title: String
    let body: String
}

/// Meeting-count milestones worth celebrating, and their custom messages.
enum Milestone {
    static let counts: Set<Int> = [1, 10, 25, 50, 100, 150, 200, 250, 300]

    static func message(for n: Int) -> MilestoneMessage? {
        switch n {
        case 1:   return .init(title: "Your first meeting! 🥣", body: "Welcome — Oatmeal's got it from here.")
        case 10:  return .init(title: "10 meetings in", body: "You're making this a habit.")
        case 25:  return .init(title: "25 captured", body: "Officially in the groove.")
        case 50:  return .init(title: "50 meetings!", body: "Half a hundred conversations kept safe.")
        case 100: return .init(title: "100 meetings 💯", body: "That's a proper archive you've built.")
        case 150: return .init(title: "150 meetings", body: "You and Oatmeal go way back now.")
        case 200: return .init(title: "200 captured", body: "Quietly unstoppable.")
        case 250: return .init(title: "250 meetings", body: "A quarter of a thousand. Wow.")
        case 300: return .init(title: "300 meetings 🏆", body: "Legendary — thanks for trusting Oatmeal with all of them.")
        default:  return nil
        }
    }
}

/// A brief, centered milestone card shown alongside the confetti. Fades in, holds,
/// fades out, then removes itself — calm (no spring) under reduce-motion.
struct MilestoneToast: View {
    let title: String
    let message: String
    var onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(.title3).weight(.bold)).foregroundStyle(Theme.textPrimary)
            Text(message).font(.system(.subheadline)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
        .scaleEffect(shown || reduceMotion ? 1 : 0.9)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { shown = true } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                withAnimation(.easeIn(duration: 0.4)) { shown = false }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.9) { onDone() }
        }
    }
}
