import SwiftUI
import AppKit

/// User-customizable appearance: accent color, light/dark preference, font, and
/// small delights. Observable singleton — reading any property inside a view
/// body makes that view update live when the user changes a setting.
@Observable
final class Appearance {
    static let shared = Appearance()

    var accent: AccentChoice
    var colorSchemePreference: ColorSchemePreference
    var fontChoice: FontChoice
    var textSize: TextSize
    var recordingChime: Bool
    /// Record-button border color (sRGB hex).
    var recordBorderHex: UInt
    /// When on, the recording border animates as a rainbow snake.
    var recordBorderRainbow: Bool

    var colorScheme: ColorScheme? { colorSchemePreference.colorScheme }
    var fontDesign: Font.Design { fontChoice.design }
    var dynamicTypeSize: DynamicTypeSize { textSize.dynamicTypeSize }
    /// Explicit multiplier used to scale fonts on macOS, where Dynamic Type alone
    /// doesn't reliably resize standard text.
    var fontScale: CGFloat { textSize.scale }
    /// Scale a base point size by the current text-size setting.
    func scaled(_ size: CGFloat) -> CGFloat { size * fontScale }
    var recordBorderColor: Color { Color(hex: recordBorderHex) }

    /// Curated in-app border colors that pair well with the app palette.
    static let recordBorderPalette: [UInt] = [
        0xE2654E, // ember
        0xF4795B, // coral
        0xE3B341, // gold
        0x57D977, // mint
        0x33B6A6, // teal
        0x4FB0F7, // sky
        0x6C7BE0, // indigo
        0x8B5CF6, // violet
        0xE05AC0, // pink
        0xF2EDE4, // ivory
        0x8A94A6  // slate
    ]

    private enum Keys {
        static let accent = "accentChoice"
        static let scheme = "colorSchemePreference"
        static let font = "fontChoice"
        static let textSize = "textSize"
        static let chime = "recordingChime"
        static let borderHex = "recordBorderHex"
        static let borderRainbow = "recordBorderRainbow"
    }

    private init() {
        let d = UserDefaults.standard
        accent = AccentChoice(rawValue: d.string(forKey: Keys.accent) ?? "") ?? .honey
        colorSchemePreference = ColorSchemePreference(rawValue: d.string(forKey: Keys.scheme) ?? "") ?? .system
        fontChoice = FontChoice(rawValue: d.string(forKey: Keys.font) ?? "") ?? .rounded
        textSize = TextSize(rawValue: d.string(forKey: Keys.textSize) ?? "") ?? .standard
        recordingChime = (d.object(forKey: Keys.chime) as? Bool) ?? true
        recordBorderHex = (d.object(forKey: Keys.borderHex) as? NSNumber)?.uintValue ?? 0xE2654E
        recordBorderRainbow = (d.object(forKey: Keys.borderRainbow) as? Bool) ?? false
    }

    /// Persist current appearance. Call after any change (didSet is unreliable on
    /// @Observable stored properties, so we persist explicitly).
    func save() {
        let d = UserDefaults.standard
        d.set(accent.rawValue, forKey: Keys.accent)
        d.set(colorSchemePreference.rawValue, forKey: Keys.scheme)
        d.set(fontChoice.rawValue, forKey: Keys.font)
        d.set(textSize.rawValue, forKey: Keys.textSize)
        d.set(recordingChime, forKey: Keys.chime)
        d.set(NSNumber(value: UInt64(recordBorderHex)), forKey: Keys.borderHex)
        d.set(recordBorderRainbow, forKey: Keys.borderRainbow)
    }
}

extension Color {
    /// sRGB hex (RGB) of this color, for persistence.
    var hexValue: UInt {
        let ns = (NSColor(self).usingColorSpace(.sRGB)) ?? NSColor(self)
        // Clamp to [0,1] — wide-gamut (P3) colors can report components outside
        // that range, which would otherwise overflow the 24-bit RGB packing.
        func channel(_ v: CGFloat) -> UInt { UInt((min(max(v, 0), 1) * 255).rounded()) }
        return (channel(ns.redComponent) << 16) | (channel(ns.greenComponent) << 8) | channel(ns.blueComponent)
    }
}

enum ColorSchemePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum FontChoice: String, CaseIterable, Identifiable {
    case rounded, standard, serif, monospaced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rounded: return "Rounded"
        case .standard: return "System"
        case .serif: return "Serif"
        case .monospaced: return "Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .standard: return .default
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

enum TextSize: String, CaseIterable, Identifiable {
    case small, standard, large, xLarge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Default"
        case .large: return "Large"
        case .xLarge: return "Extra Large"
        }
    }
    /// Maps to SwiftUI Dynamic Type so semantic fonts (and `@ScaledMetric`-driven
    /// fixed sizes) scale app-wide. Capped below the accessibility sizes to keep
    /// the layout intact.
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .standard: return .medium
        case .large: return .xLarge
        case .xLarge: return .xxxLarge
        }
    }
    /// Explicit point-size multiplier (macOS-reliable, unlike Dynamic Type).
    var scale: CGFloat {
        switch self {
        case .small: return 0.88
        case .standard: return 1.0
        case .large: return 1.18
        case .xLarge: return 1.36
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case honey, berry, forest, ocean, lavender, graphite
    // Creative multi-color accents:
    case sunset, aurora, rainbow
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Single representative color (for text, icons, pills).
    var color: Color {
        switch self {
        case .honey: return .adaptive(light: 0xD98A3D, dark: 0xEDA75A)
        case .berry: return .adaptive(light: 0xC65574, dark: 0xE0789A)
        case .forest: return .adaptive(light: 0x4E8D5B, dark: 0x6FB87E)
        case .ocean: return .adaptive(light: 0x3E82B8, dark: 0x5BA0D6)
        case .lavender: return .adaptive(light: 0x8268C4, dark: 0xA48FDC)
        case .graphite: return .adaptive(light: 0x6B7280, dark: 0x9AA2AD)
        case .sunset: return .adaptive(light: 0xE8714E, dark: 0xF0926E)
        case .aurora: return .adaptive(light: 0x3FA9C9, dark: 0x5BC4DD)
        case .rainbow: return .adaptive(light: 0x8B5CF6, dark: 0xA98BF0)
        }
    }

    var deep: Color {
        switch self {
        case .honey: return .adaptive(light: 0xC2752C, dark: 0xE49B45)
        case .berry: return .adaptive(light: 0xAE3F5E, dark: 0xCB6080)
        case .forest: return .adaptive(light: 0x3C7449, dark: 0x589E68)
        case .ocean: return .adaptive(light: 0x2E6A9B, dark: 0x4488C0)
        case .lavender: return .adaptive(light: 0x6B52AC, dark: 0x8E76C9)
        case .graphite: return .adaptive(light: 0x565D68, dark: 0x828A95)
        case .sunset: return .adaptive(light: 0xCE4F6E, dark: 0xDE6E8E)
        case .aurora: return .adaptive(light: 0x5566D6, dark: 0x7E8BE6)
        case .rainbow: return .adaptive(light: 0x7340D0, dark: 0x9070E0)
        }
    }

    var soft: Color {
        switch self {
        case .honey: return .adaptive(light: 0xF7E8D2, dark: 0x3A2D1C)
        case .berry: return .adaptive(light: 0xF6E0E7, dark: 0x3A2630)
        case .forest: return .adaptive(light: 0xDCEBDD, dark: 0x223026)
        case .ocean: return .adaptive(light: 0xD9E8F4, dark: 0x1E2E3C)
        case .lavender: return .adaptive(light: 0xE9E2F6, dark: 0x2C2640)
        case .graphite: return .adaptive(light: 0xE5E7EA, dark: 0x2A2D33)
        case .sunset: return .adaptive(light: 0xFBE3D5, dark: 0x3A2620)
        case .aurora: return .adaptive(light: 0xD9EEF4, dark: 0x1E2E38)
        case .rainbow: return .adaptive(light: 0xEDE6FA, dark: 0x2C2640)
        }
    }

    /// The showcase gradient — fancy multi-stop for creative accents, a subtle
    /// color→deep for the solid ones.
    var gradient: LinearGradient {
        switch self {
        case .sunset:
            return LinearGradient(colors: [Color(hex: 0xF7B267), Color(hex: 0xF4795B), Color(hex: 0xE0568A)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .aurora:
            return LinearGradient(colors: [Color(hex: 0x4FD1C5), Color(hex: 0x4F8DF7), Color(hex: 0x8B5CF6)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .rainbow:
            return LinearGradient(colors: [Color(hex: 0xFF5E5E), Color(hex: 0xFFA63D), Color(hex: 0xFFE03D),
                                           Color(hex: 0x57D977), Color(hex: 0x4FB0F7), Color(hex: 0x8B5CF6),
                                           Color(hex: 0xE05AC0)],
                                  startPoint: .leading, endPoint: .trailing)
        default:
            return LinearGradient(colors: [color, deep], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Spectrum colors used by the animated record-button snake when rainbow mode is on.
    static let rainbowColors: [Color] = [
        Color(hex: 0xFF5E5E), Color(hex: 0xFFA63D), Color(hex: 0xFFE03D),
        Color(hex: 0x57D977), Color(hex: 0x4FB0F7), Color(hex: 0x8B5CF6), Color(hex: 0xE05AC0)
    ]
}
