import SwiftUI

/// Reusable, reduce-motion-aware *reveal* building blocks for streaming content
/// (transcripts, notes, summaries, action items).
///
/// Everything here is driven through the shared `Motion` toolkit and honors the
/// user's reduce-motion preference. The chosen API convention mirrors `Motion`:
/// **call sites pass `reduceMotion` in** (read once from
/// `@Environment(\.accessibilityReduceMotion)`). These helpers never read the
/// environment themselves, so they stay usable from previews, helpers, and
/// non-view contexts — and a single environment read at the call site keeps the
/// reduce-motion contract obvious and centralized.
///
/// When `reduceMotion` is true, every helper collapses to an instant, motionless
/// render: zero stagger delay, no offset, no fade — content simply appears.
enum Reveal {

    // MARK: - Tuning

    /// How far newly-arriving content slides up as it fades in (points). Subtle
    /// on purpose — a hint of motion, not a swoop.
    static let riseOffset: CGFloat = 6

    /// Base delay before the first item in a staggered group appears.
    static let staggerBase: Double = 0.0

    /// Per-item incremental delay in a staggered cascade.
    static let staggerStep: Double = 0.04

    /// Cap on total stagger delay so long lists don't take forever to settle.
    static let staggerCap: Double = 0.5

    // MARK: - Transitions

    /// Insertion transition for newly-arriving content: a gentle fade combined
    /// with a small upward move. Use on rows added to a `ForEach` so they ease
    /// in rather than pop.
    ///
    /// Under reduce-motion, callers should gate the *animation* (pass
    /// `Motion.reveal(reduceMotion)` to `.animation`/`withAnimation`, which is
    /// `nil` when reduce-motion is on) so the transition applies with no visible
    /// movement.
    static var insertion: AnyTransition {
        .move(edge: .top)
            .combined(with: .opacity)
    }

    /// A pure fade insertion — for places where vertical movement would fight
    /// surrounding layout (e.g. inside a scrolling, programmatically-driven list).
    static var fade: AnyTransition { .opacity }

    // MARK: - Stagger helper

    /// Per-item delay for a cascading appearance.
    ///
    /// - Parameters:
    ///   - index: zero-based position of the item in its group.
    ///   - reduceMotion: when `true`, returns `0` (instant, no cascade).
    /// - Returns: `base + index * step`, capped at `staggerCap`.
    static func staggerDelay(_ index: Int, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        return min(staggerBase + Double(max(index, 0)) * staggerStep, staggerCap)
    }
}

// MARK: - One-shot appear modifier

/// Animates a view in on its *first render only*. An internal `@State` flag
/// guards re-runs, so the reveal won't re-trigger on scroll, tab switches, or
/// unrelated state churn.
///
/// Honors reduce-motion: when on, the view starts fully visible and no animation
/// or offset is ever applied.
private struct AppearReveal: ViewModifier {
    /// Per-item delay (use `Reveal.staggerDelay` for cascades; `0` for a single
    /// element). Ignored under reduce-motion.
    var delay: Double
    /// Whether to add a subtle upward rise in addition to the fade.
    var rise: Bool
    let reduceMotion: Bool

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || shown ? 1 : 0)
            .offset(y: (reduceMotion || shown || !rise) ? 0 : Reveal.riseOffset)
            .onAppear {
                // First render only — guarded so it never re-runs.
                guard !shown else { return }
                if reduceMotion {
                    // Instant, motionless: no animation, no transient state.
                    shown = true
                } else {
                    withAnimation(Motion.reveal(false)?.delay(delay)) {
                        shown = true
                    }
                }
            }
    }
}

extension View {
    /// Reveal this view once, on first appearance, with a subtle fade (and
    /// optional upward rise). Safe to attach to list rows: the reveal fires a
    /// single time and won't replay on scroll or state changes.
    ///
    /// - Parameters:
    ///   - reduceMotion: pass `@Environment(\.accessibilityReduceMotion)`.
    ///   - delay: stagger delay; use `Reveal.staggerDelay(index:reduceMotion:)`.
    ///   - rise: include a small upward move (default `true`).
    func appearReveal(reduceMotion: Bool, delay: Double = 0, rise: Bool = true) -> some View {
        modifier(AppearReveal(delay: delay, rise: rise, reduceMotion: reduceMotion))
    }

    /// Convenience for staggered list rows: computes the per-index delay and
    /// applies a one-shot reveal. Collapses to an instant render under
    /// reduce-motion.
    func staggeredReveal(index: Int, reduceMotion: Bool, rise: Bool = true) -> some View {
        appearReveal(
            reduceMotion: reduceMotion,
            delay: Reveal.staggerDelay(index, reduceMotion: reduceMotion),
            rise: rise
        )
    }
}
