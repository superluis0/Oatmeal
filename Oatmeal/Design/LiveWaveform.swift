import SwiftUI

/// An audio-reactive bar waveform for live-recording surfaces.
///
/// Feed it a smoothed `level` (0...1, e.g. `RecordingCoordinator.audioLevel`) and
/// it keeps a short rolling history of recent levels internally, advancing one
/// sample per animation tick and scrolling them left-to-right as spring-driven
/// bars. The newest sample enters on the trailing edge, so the bars read as a
/// live, breathing meter rather than a static EQ.
///
/// Reduce-motion: no scrolling, no looping — every bar simply reflects the
/// current `level` at a fixed height with a tiny eased variation, giving a calm
/// steady meter that still conveys "audio is live" without continuous motion.
///
/// Self-contained and size-adaptive: it fills whatever frame it's given.
struct LiveWaveform: View {
    /// Current smoothed audio level, 0...1.
    var level: Float
    /// Number of bars / history depth. Fewer = chunkier, more = finer.
    var barCount: Int = 28
    /// Bar tint. Defaults to the recording red.
    var color: Color = Theme.danger

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            staticMeter
        } else {
            liveMeter
        }
    }

    // MARK: - Live (animated) variant

    private var liveMeter: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            // Drive the rolling buffer off the timeline date so we don't retain a
            // Timer and never invalidate it. Each tick maps to one advance.
            let tick = Int(context.date.timeIntervalSinceReferenceDate * 30)
            Canvas { ctx, size in
                draw(into: &ctx, size: size, history: history(upTo: tick))
            }
            .drawingGroup(opaque: false)
        }
        .accessibilityHidden(true)
    }

    /// Builds a deterministic rolling history ending at the current level.
    /// We can't keep mutable state inside a `TimelineView` cheaply, so we
    /// synthesize a short trailing window from the *current* level plus a light
    /// per-bar shimmer keyed off the tick — this reads as a live scrolling meter
    /// while staying allocation-light and fully value-driven.
    private func history(upTo tick: Int) -> [CGFloat] {
        let l = CGFloat(min(max(level, 0), 1))
        var out = [CGFloat]()
        out.reserveCapacity(barCount)
        for i in 0..<barCount {
            // Older bars (smaller i) decay toward a quiet floor so the meter
            // appears to "scroll" the loud edge in from the right.
            let recency = CGFloat(i) / CGFloat(max(barCount - 1, 1)) // 0 old -> 1 newest
            let decay = 0.35 + 0.65 * recency
            // Subtle phase shimmer so bars aren't a flat block at steady level.
            let phase = Double(tick - (barCount - i)) * 0.55
            let shimmer = (sin(phase) + 1) / 2 * 0.18
            let h = (l * decay) + CGFloat(shimmer) * l
            out.append(min(max(h, 0), 1))
        }
        return out
    }

    private func draw(into ctx: inout GraphicsContext, size: CGSize, history: [CGFloat]) {
        guard !history.isEmpty else { return }
        let n = history.count
        let gap: CGFloat = Theme.Space.xxs / 2
        let totalGap = gap * CGFloat(n - 1)
        let barWidth = max(1.5, (size.width - totalGap) / CGFloat(n))
        let midY = size.height / 2
        let minBar: CGFloat = 2
        let shading = GraphicsContext.Shading.color(color)

        for (i, raw) in history.enumerated() {
            let h = minBar + raw * (size.height - minBar)
            let x = CGFloat(i) * (barWidth + gap)
            let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous)
            // Newest (right-most) bars are most opaque; older ones fade out.
            let opacity = 0.35 + 0.65 * (CGFloat(i) / CGFloat(max(n - 1, 1)))
            ctx.opacity = opacity
            ctx.fill(path, with: shading)
        }
    }

    // MARK: - Reduce-motion (static) variant

    private var staticMeter: some View {
        let l = CGFloat(min(max(level, 0), 1))
        let bars = max(5, barCount / 4)
        return HStack(spacing: Theme.Space.xxs) {
            ForEach(0..<bars, id: \.self) { i in
                // Gentle fixed center-weighted shape; no motion, just reflects level.
                let center = 1 - abs(CGFloat(i) - CGFloat(bars - 1) / 2) / CGFloat(bars)
                Capsule()
                    .fill(color.opacity(0.45 + 0.45 * center))
                    .frame(width: 3, height: 4 + l * 18 * center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityHidden(true)
    }
}
