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
    /// How the waveform presents itself.
    /// - `.meter`: the compact scrolling level meter (headers, list rows).
    /// - `.hero`: a centerpiece — a flowing ribbon of layered sine curves in the
    ///   honey gradient, drifting at different speeds and opacities with a soft
    ///   glow that swells with the voice. Organic and liquid rather than an EQ;
    ///   it settles into a gentle shimmer in a quiet room, so the surface always
    ///   feels alive.
    enum Style { case meter, hero }

    /// Current smoothed audio level, 0...1.
    var level: Float
    /// Number of bars / history depth. Fewer = chunkier, more = finer.
    /// (`.hero` is a continuous ribbon and ignores this.)
    var barCount: Int = 28
    /// Bar tint. Defaults to the recording red. (`.hero` uses the accent
    /// gradient instead and ignores this.)
    var color: Color = Theme.danger
    /// Presentation. Defaults to the compact meter.
    var style: Style = .meter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch (style, reduceMotion) {
        case (.meter, false): liveMeter
        case (.meter, true): staticMeter
        case (.hero, false): liveHero
        case (.hero, true): staticHero
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

    // MARK: - Hero (centerpiece) variant

    /// One curve of the ribbon. The brightest, slowest layer carries the voice;
    /// the fainter ones drift behind it out of phase for the liquid feel.
    private struct RibbonLayer {
        /// Horizontal drift in radians/second (negative = leftward).
        var speed: Double
        /// Full sine periods across the view's width.
        var frequency: Double
        /// Amplitude relative to the brightest layer (0...1).
        var amplitude: CGFloat
        var opacity: CGFloat
        var lineWidth: CGFloat
    }

    private static let ribbonLayers: [RibbonLayer] = [
        RibbonLayer(speed: 1.6, frequency: 2.1, amplitude: 1.00, opacity: 0.95, lineWidth: 2.5),
        RibbonLayer(speed: -1.1, frequency: 3.2, amplitude: 0.72, opacity: 0.45, lineWidth: 2.0),
        RibbonLayer(speed: 2.3, frequency: 4.4, amplitude: 0.50, opacity: 0.25, lineWidth: 1.5),
    ]

    private var liveHero: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawRibbon(into: &ctx, size: size, time: time)
            }
            .drawingGroup(opaque: false)
        }
        .accessibilityHidden(true)
    }

    /// Reduce-motion hero: the same ribbon frozen at a fixed phase — purely
    /// level-driven (the curves swell with the voice) with no continuous drift.
    private var staticHero: some View {
        Canvas { ctx, size in
            drawRibbon(into: &ctx, size: size, time: 0)
        }
        .accessibilityHidden(true)
    }

    /// A sine curve sampled across the width, shaped by a center-weighted
    /// envelope (pow sharpens the taper) so the ribbon pinches to the midline at
    /// both edges. The voice level scales every layer's amplitude: silence
    /// settles into a near-flat shimmer, speech swells the whole ribbon.
    private func ribbonPath(layer: RibbonLayer, size: CGSize, time: Double, level l: CGFloat) -> Path {
        let midY = size.height / 2
        let swell = (0.06 + 0.40 * l) * size.height
        let step: CGFloat = 3
        var path = Path()
        var x: CGFloat = 0
        while true {
            let u = x / size.width
            let envelope = pow(sin(.pi * u), 1.4)
            let angle = Double(u) * .pi * 2 * layer.frequency + time * layer.speed
            let y = midY + CGFloat(sin(angle)) * envelope * layer.amplitude * swell
            if x == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
            if x >= size.width { break }
            x = min(x + step, size.width)
        }
        return path
    }

    private func drawRibbon(into ctx: inout GraphicsContext, size: CGSize, time: Double) {
        guard size.width > 0 else { return }
        let l = CGFloat(min(max(level, 0), 1))
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Theme.accent, Theme.accentDeep]),
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: 0))
        let paths = Self.ribbonLayers.map {
            (path: ribbonPath(layer: $0, size: size, time: time, level: l), layer: $0)
        }

        // Glow pass: the same curves, blurred, behind the sharp ones. Strength
        // tracks the voice level so loud moments feel luminous, quiet ones calm.
        ctx.drawLayer { glow in
            glow.addFilter(.blur(radius: 4))
            glow.opacity = Motion.glow(forLevel: level, base: 0.25, range: 0.55)
            for (path, layer) in paths {
                glow.stroke(path, with: shading,
                            style: StrokeStyle(lineWidth: layer.lineWidth + 1, lineCap: .round))
            }
        }
        for (path, layer) in paths {
            ctx.opacity = layer.opacity
            ctx.stroke(path, with: shading,
                       style: StrokeStyle(lineWidth: layer.lineWidth, lineCap: .round))
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
