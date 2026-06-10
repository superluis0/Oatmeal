import SwiftUI

/// A reusable, reduce-motion-aware *shimmer / skeleton* toolkit.
///
/// The shimmer sweeps a soft highlight across whatever it's attached to while
/// `active` is true, and cleanly stops the moment `active` flips false — no
/// looping `TimelineView` or retained timer is left running once content loads.
///
/// Reduce-motion contract: instead of sweeping, the modifier renders a calm,
/// static tinted wash. No motion, nothing looping. The preference is read once,
/// inside the modifier, via `@Environment(\.accessibilityReduceMotion)` (a
/// `ViewModifier` legitimately holds environment), so call sites stay terse:
/// just `.shimmering(active: isLoading)`.
///
/// Pair `SkeletonBlock` placeholders with `.shimmering(active:)` to build a
/// living skeleton while real content is generated.
struct ShimmerModifier: ViewModifier {
    /// Drives the sweep. When false, the animation stops and the view renders
    /// with no overlay at all (so the modifier is invisible once loaded).
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if !active {
            // Loaded / idle: no overlay, no animation, no cost.
            content
        } else if reduceMotion {
            // Calm, motionless placeholder: a soft static tinted wash, no sweep.
            content.overlay(
                Theme.accent.opacity(0.06)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
        } else {
            // Sweeping highlight, driven only while active.
            content.overlay(sweep.allowsHitTesting(false))
                .clipped()
        }
    }

    /// A bright, soft band that travels left→right across the content, masked to
    /// the content's own shape so the highlight only paints where there's a view.
    private var sweep: some View {
        TimelineView(.animation) { context in
            // 0…1 progress through a steady ~1.4s cycle.
            let period = 1.4
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: period)) / period

            GeometryReader { geo in
                let w = geo.size.width
                // Travel a band from fully off the leading edge to fully past the
                // trailing edge, so the highlight enters and exits cleanly.
                let bandWidth = max(w * 0.6, 80)
                let travel = w + bandWidth
                let x = -bandWidth + travel * phase

                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.55), location: 0.5),
                        .init(color: .white.opacity(0), location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: bandWidth)
                .offset(x: x)
                .blendMode(.plusLighter)
            }
        }
    }
}

extension View {
    /// Sweep a soft shimmer highlight across this view while `active` is true.
    ///
    /// Stops cleanly (and drops the overlay entirely) when `active` is false.
    /// Under reduce-motion this becomes a calm static tinted wash with no motion.
    ///
    /// - Parameter active: whether the shimmer should animate right now.
    func shimmering(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

// MARK: - Skeleton placeholder

/// A rounded-rectangle placeholder block for building skeleton layouts while
/// real content loads. Tinted with Theme surface tokens so it reads as an empty
/// slot; combine with `.shimmering(active:)` on the *container* for the sweep.
///
/// Width defaults to flexible (`nil` → fills available width) so skeleton lines
/// can mimic paragraph ragged-right text by varying only the explicit widths.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var cornerRadius: CGFloat = Theme.Radius.sm

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.surfaceAlt)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.border.opacity(0.5), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}

/// A ready-made multi-line skeleton that reads like a paragraph of notes being
/// generated. Drop it where real content will appear and wrap with
/// `.shimmering(active:)`; it ships its own shimmer so call sites stay tidy.
///
/// Honors reduce-motion automatically (via `shimmering`): the lines render as a
/// calm static placeholder with no sweep.
struct SkeletonLines: View {
    /// Relative widths (0…1 of available width) for each placeholder line; the
    /// ragged right edge mimics natural prose.
    var lineWidths: [CGFloat] = [1.0, 0.92, 0.96, 0.7]
    var lineHeight: CGFloat = 12
    var spacing: CGFloat = Theme.Space.sm

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, fraction in
                GeometryReader { geo in
                    SkeletonBlock(width: geo.size.width * fraction, height: lineHeight)
                }
                .frame(height: lineHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmering(active: true)
        .accessibilityLabel("Generating…")
    }
}
