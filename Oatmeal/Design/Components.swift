import SwiftUI

// MARK: - Button styles

/// Filled honey button with tactile press + hover. The primary action everywhere.
struct OatPrimaryButton: ButtonStyle {
    var fullWidth = false
    var destructive = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body).weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(destructive ? Theme.recordGradient : Theme.accentGradient,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: (destructive ? Theme.danger : Theme.accent).opacity(hovering ? 0.45 : 0.30),
                    radius: hovering ? 14 : 9, y: hovering ? 5 : 3)
            .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.015 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}

/// Subtle surface button with a hairline border. Secondary actions.
struct OatSecondaryButton: ButtonStyle {
    var fullWidth = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body).weight(.medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(hovering ? Theme.surfaceAlt : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}

/// Quiet text/icon button that warms on hover.
struct OatGhostButton: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body).weight(.medium))
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 7)
            .background(hovering ? Theme.surfaceAlt : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}

// MARK: - Card

struct OatCard: ViewModifier {
    var padding: CGFloat = Theme.Space.md
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }
}

extension View {
    func oatCard(padding: CGFloat = Theme.Space.md) -> some View { modifier(OatCard(padding: padding)) }
}

// MARK: - Small atoms

/// A small rounded tag/chip.
struct OatPill: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(.caption).weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// An uppercase section label, à la Things/Linear.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2).weight(.bold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// A compact vertical action chip (icon over label) for the sidebar. Stays
/// readable at any column width — the label never wraps or truncates oddly.
struct SidebarChip: View {
    let title: String
    let systemImage: String
    var badge: Int = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24, height: 20)
                        .foregroundStyle(Theme.textPrimary)
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.accent, in: Capsule())
                            .fixedSize()
                            .offset(x: 14, y: -7)
                    }
                }
                Text(title)
                    .font(.system(.caption).weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .background(hovering ? Theme.surfaceAlt : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Warm card styling applied to every GroupBox across the app.
struct OatGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            configuration.label
                .font(.system(.subheadline).weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            configuration.content
        }
        .padding(Theme.Space.md)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }
}

/// A friendly empty state with a soft icon badge.
struct OatEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            IconBadge(systemName: icon, size: 64)
            Text(title).font(.system(.title2).weight(.semibold))
            Text(message)
                .font(.system(.body))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }
}

/// An animated border that "snakes" a bright band of color around a rounded
/// rectangle while active (recording); a static colored border when inactive.
struct SnakeBorder: View {
    var color: Color
    var rainbow: Bool
    var cornerRadius: CGFloat
    var active: Bool
    var lineWidth: CGFloat = 3
    var loopSeconds: Double = 2.2

    var body: some View {
        if active {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let angle = (t.truncatingRemainder(dividingBy: loopSeconds) / loopSeconds) * 360
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(gradient(angle: angle), lineWidth: lineWidth)
                    .shadow(color: (rainbow ? Color(hex: 0x8B5CF6) : color).opacity(0.6), radius: 6)
            }
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color, lineWidth: max(1.5, lineWidth - 1))
        }
    }

    private func gradient(angle: Double) -> AngularGradient {
        if rainbow {
            // Full spectrum, looped, rotating around the border.
            var colors = AccentChoice.rainbowColors
            colors.append(colors.first!)
            return AngularGradient(gradient: Gradient(colors: colors),
                                   center: .center,
                                   startAngle: .degrees(angle),
                                   endAngle: .degrees(angle + 360))
        } else {
            // A single-color comet/snake traveling around an otherwise faint ring.
            let stops: [Gradient.Stop] = [
                .init(color: color.opacity(0.12), location: 0.0),
                .init(color: color.opacity(0.12), location: 0.55),
                .init(color: color, location: 0.80),
                .init(color: .white, location: 0.88),
                .init(color: color, location: 0.95),
                .init(color: color.opacity(0.12), location: 1.0)
            ]
            return AngularGradient(gradient: Gradient(stops: stops),
                                   center: .center,
                                   startAngle: .degrees(angle),
                                   endAngle: .degrees(angle + 360))
        }
    }
}

/// A gently pulsing red dot for the live-recording state.
struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false
    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: 11, height: 11)
            .overlay(
                Circle().stroke(Theme.danger, lineWidth: 2)
                    .scaleEffect(animating ? 2.1 : 1)
                    .opacity(animating ? 0 : 0.7)
            )
            .onAppear {
                // Respect Reduce Motion: leave the ring static instead of looping.
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                    animating = true
                }
            }
    }
}

/// Soft circular icon badge used in onboarding/empty states.
struct IconBadge: View {
    let systemName: String
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}
