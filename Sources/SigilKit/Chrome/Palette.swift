import AppKit
import SwiftUI

/// App chrome colours, derived from the active terminal theme.
///
/// The window has to read as one surface, so every value here is mixed from the
/// terminal's own background and foreground. Three rules keep it honest:
///
/// 1. The panel greys take their brightness from the terminal ground but not its
///    hue, so a tinted theme cannot leak colour into the chrome.
/// 2. The text ramp is three discrete colours, not one colour at three opacities.
///    Opacity ramps mush together over a near-black ground; that is what makes
///    grey-on-black read as unfinished.
/// 3. Every text colour clears WCAG AA against the panel it sits on. `PaletteTests`
///    holds the ramp to it.
///
/// Values are stored as `0xRRGGBB` so the ratios can be tested.
public struct Palette: Equatable, Sendable {
    /// The terminal's own background: the detail column and the window itself.
    public let groundHex: UInt32
    /// The rail on the left. On a dark theme this is true black, so the list reads
    /// as a separate surface from the terminal rather than a lighter copy of it.
    public let sidebarHex: UInt32
    /// Hover fills, the search field, the selected tab.
    public let raisedHex: UInt32
    /// The row whose conversation is on screen.
    public let selectedHex: UInt32
    /// Separator lines. The only borders in the app.
    public let hairlineHex: UInt32
    public let textHex: UInt32
    public let textDimHex: UInt32
    public let textFaintHex: UInt32
    /// State only — the open conversation, a working session, a focused field.
    public let accentHex: UInt32

    public init(theme: TerminalTheme) {
        let background = theme.backgroundHex
        let foreground = theme.foregroundHex
        let isDark = theme.isDark
        // Dark themes lift toward white, light themes settle toward black.
        let step: UInt32 = isDark ? 0xFFFFFF : 0x000000
        // Text dims toward the surface it sits on, never toward transparency.
        let ink: UInt32 = isDark ? 0x000000 : 0xFFFFFF
        // Panels step off a neutral grey of the same brightness as the terminal
        // ground, so a tinted theme cannot leak colour into the chrome.
        let neutral = Self.desaturated(background)

        groundHex = background
        // The rail is the darkest surface, and every panel steps up off the rail —
        // not off the terminal ground, which sits above it.
        // A light theme cannot take the same step: its panels darken away from the
        // ground, and text that dims toward white loses AA on them fast. These
        // numbers are the darkest the light rail can go and still pass.
        let rail = isDark ? 0x000000 : Self.mix(neutral, 0x000000, 0.04)
        sidebarHex = rail
        raisedHex = Self.mix(rail, step, isDark ? 0.10 : 0.035)
        selectedHex = Self.mix(rail, step, isDark ? 0.15 : 0.060)
        hairlineHex = Self.mix(rail, step, isDark ? 0.17 : 0.090)
        textHex = Self.mix(foreground, step, isDark ? 0.22 : 0.0)
        // These two are floored by contrast, not by taste: dimming them further
        // fails AA on the selected row. Hierarchy below this point is carried by
        // size and by the switch to mono, not by more grey.
        textDimHex = Self.mix(foreground, ink, isDark ? 0.15 : 0.13)
        textFaintHex = Self.mix(foreground, ink, isDark ? 0.30 : 0.28)
        accentHex = theme.accentHex
    }

    // MARK: - SwiftUI

    public var ground: Color { Self.color(groundHex) }
    public var sidebar: Color { Self.color(sidebarHex) }
    public var raised: Color { Self.color(raisedHex) }
    public var selected: Color { Self.color(selectedHex) }
    public var hairline: Color { Self.color(hairlineHex) }
    public var text: Color { Self.color(textHex) }
    public var textDim: Color { Self.color(textDimHex) }
    public var textFaint: Color { Self.color(textFaintHex) }
    public var accent: Color { Self.color(accentHex) }
    public var groundNSColor: NSColor { Self.nsColor(groundHex) }

    // MARK: - Contrast

    /// WCAG 2.1 relative luminance.
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let c = components(hex)
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    /// WCAG 2.1 contrast ratio, 1...21.
    public static func contrast(_ lhs: UInt32, _ rhs: UInt32) -> Double {
        let a = luminance(lhs)
        let b = luminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: - Mixing

    private static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    private static func color(_ hex: UInt32) -> Color {
        let c = components(hex)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        let c = components(hex)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// The same brightness, with the hue taken out.
    private static func desaturated(_ hex: UInt32) -> UInt32 {
        let c = components(hex)
        let brightness = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        let level = UInt32((brightness * 255).rounded())
        return level << 16 | level << 8 | level
    }

    private static func mix(_ from: UInt32, _ to: UInt32, _ amount: Double) -> UInt32 {
        let a = components(from)
        let b = components(to)
        func channel(_ x: Double, _ y: Double) -> UInt32 {
            UInt32(((x + (y - x) * amount) * 255).rounded().clamped(to: 0...255))
        }
        return channel(a.r, b.r) << 16 | channel(a.g, b.g) << 8 | channel(a.b, b.b)
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(theme: .grokNight)
}

extension EnvironmentValues {
    public var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
