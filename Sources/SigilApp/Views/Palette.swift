import AppKit
import SigilKit
import SwiftUI

/// App chrome colours, derived from the active terminal theme.
///
/// The window has to read as one surface. Every panel, hairline and label here is
/// mixed from the terminal's own background and foreground, so the chrome can never
/// drift away from the thing it wraps.
struct Palette: Equatable {
    /// The terminal's own background: the detail column and the window itself.
    let ground: Color
    /// One step off the ground, for the sidebar.
    let sidebar: Color
    /// Two steps off, for fields, hovered rows and the selected tab.
    let raised: Color
    /// Separator lines. The only borders in the app.
    let hairline: Color
    /// The chrome is monochrome, so "accent" is simply the brightest text colour.
    /// It marks state (an open conversation, a live session), never decoration.
    let text: Color
    let textDim: Color
    let textFaint: Color
    let accent: Color
    let groundNSColor: NSColor

    init(theme: TerminalTheme) {
        let background = theme.backgroundHex
        let foreground = theme.foregroundHex
        // Dark themes lift toward white, light themes settle toward black.
        let step: UInt32 = theme.isDark ? 0xFFFFFF : 0x000000
        // Panels step off a neutral grey of the same brightness as the terminal
        // ground, so a tinted theme can never leak colour into the chrome.
        let neutral = Self.desaturated(background)

        ground = Self.color(background)
        sidebar = Self.mix(neutral, step, theme.isDark ? 0.035 : 0.030)
        raised = Self.mix(neutral, step, theme.isDark ? 0.085 : 0.065)
        hairline = Self.mix(neutral, step, theme.isDark ? 0.13 : 0.11)
        text = Self.color(foreground)
        textDim = Self.color(foreground, 0.62)
        textFaint = Self.color(foreground, 0.38)
        accent = Self.mix(foreground, step, theme.isDark ? 0.45 : 0.0)
        groundNSColor = Self.nsColor(background)
    }

    // MARK: - Mixing

    private static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    private static func color(_ hex: UInt32, _ opacity: Double = 1) -> Color {
        let c = components(hex)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        let c = components(hex)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// The same brightness, with the hue taken out.
    private static func desaturated(_ hex: UInt32) -> UInt32 {
        let c = components(hex)
        let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        let level = UInt32((luminance * 255).rounded())
        return level << 16 | level << 8 | level
    }

    private static func mix(_ from: UInt32, _ to: UInt32, _ amount: Double) -> Color {
        let a = components(from)
        let b = components(to)
        return Color(
            .sRGB,
            red: a.r + (b.r - a.r) * amount,
            green: a.g + (b.g - a.g) * amount,
            blue: a.b + (b.b - a.b) * amount,
            opacity: 1
        )
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(theme: .grokNight)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
