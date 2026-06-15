import SwiftUI
import AppKit

// MARK: - Color utilities

extension NSColor {
    convenience init(hex: UInt) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt) { self.init(nsColor: NSColor(hex: hex)) }

    /// Light/dark adaptive color from two hex values.
    static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

// MARK: - Theme

/// Oatmeal's design language: a warm, calm palette with honey accents,
/// rounded typography, generous spacing, and soft surfaces. Fully adaptive.
enum Theme {
    // Surfaces
    static let bg = Color.adaptive(light: 0xFAF6EF, dark: 0x16130F)
    static let bgElevated = Color.adaptive(light: 0xF1E9DB, dark: 0x1E1A14)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x232019)
    static let surfaceAlt = Color.adaptive(light: 0xF6EFE2, dark: 0x2B261D)

    // Text
    static let textPrimary = Color.adaptive(light: 0x2B2620, dark: 0xF3EDE3)
    static let textSecondary = Color.adaptive(light: 0x8C8170, dark: 0xA79C8B)
    static let textTertiary = Color.adaptive(light: 0xB3A998, dark: 0x6F6757)

    // Brand — driven by the user's chosen accent (live-updating).
    static var accent: Color { Appearance.shared.accent.color }
    static var accentDeep: Color { Appearance.shared.accent.deep }
    static var accentSoft: Color { Appearance.shared.accent.soft }
    static let onAccent = Color.white

    // Lines & states
    static let border = Color.adaptive(light: 0xEADFce, dark: 0x342E24)
    static let hairline = Color.adaptive(light: 0xEFE7D8, dark: 0x2A251D)
    static let danger = Color.adaptive(light: 0xCB5A48, dark: 0xE27B6B)
    static let success = Color.adaptive(light: 0x5C9A6B, dark: 0x79B889)

    // Gradients
    static var accentGradient: LinearGradient { Appearance.shared.accent.gradient }
    static let recordGradient = LinearGradient(
        colors: [Color(hex: 0xE2654E), Color(hex: 0xC9463A)],
        startPoint: .top, endPoint: .bottom
    )

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
        static let pill: CGFloat = 999
    }
}
