import AppKit
import SwiftUI

/// App chrome colours, derived from the active terminal theme.
///
/// The window has to read as one surface, so every value here is mixed from the
/// terminal's own background and foreground. Three rules keep it honest:
///
/// 1. The rail is a darkened step of the terminal ground, hue kept, so Discord
///    is Discord and Ember is Ember. True black made every dark theme identical.
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
    /// The rail on the left. A darkened step of the terminal ground, so the list
    /// sits below the screen without flattening every theme to the same black.
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
    public let errorHex: UInt32

    public init(theme: TerminalTheme) {
        let background = theme.backgroundHex
        let foreground = theme.foregroundHex
        let isDark = theme.isDark
        // Dark themes lift toward white, light themes settle toward black.
        let step: UInt32 = isDark ? 0xFFFFFF : 0x000000
        // Text dims toward the surface it sits on, never toward transparency.
        let ink: UInt32 = isDark ? 0x000000 : 0xFFFFFF
        groundHex = background
        // The rail sits below the terminal. Hue stays with the ground so a theme
        // change is visible in the chrome, not only inside the program.
        // A light theme cannot take the same step: its panels darken away from the
        // ground, and text that dims toward white loses AA on them fast. These
        // numbers are the darkest the light rail can go and still pass.
        let rail = Self.mix(background, 0x000000, isDark ? 0.18 : 0.04)
        sidebarHex = rail
        raisedHex = Self.mix(rail, step, isDark ? 0.10 : 0.035)
        selectedHex = Self.mix(rail, step, isDark ? 0.15 : 0.060)
        hairlineHex = Self.mix(rail, step, isDark ? 0.17 : 0.090)
        let pole: UInt32 = isDark ? 0xFFFFFF : 0x000000
        let panels = [background, rail, raisedHex, selectedHex]
        let hardest = Self.hardestPanel(in: panels, forLightText: isDark)
        textHex = Self.ensureContrast(
            Self.mix(foreground, step, isDark ? 0.22 : 0.0),
            against: hardest, minimum: 4.5, toward: pole)
        // Dimmed toward the ink, then lifted if the selected row is too light.
        textDimHex = Self.ensureContrast(
            Self.mix(foreground, ink, isDark ? 0.15 : 0.13),
            against: hardest, minimum: 4.5, toward: foreground)
        textFaintHex = Self.ensureContrast(
            Self.mix(foreground, ink, isDark ? 0.30 : 0.28),
            against: hardest, minimum: 4.5, toward: foreground)
        accentHex = Self.ensureContrast(
            theme.accentHex, against: hardest, minimum: 4.5, toward: pole)
        errorHex = Self.ensureContrast(
            isDark ? 0xFF5F9E : 0xB4232E, against: hardest, minimum: 4.5, toward: pole)
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
    public var error: Color { Self.color(errorHex) }
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

    /// Dark text is hardest on the darkest panel; light text on the lightest.
    private static func hardestPanel(in panels: [UInt32], forLightText: Bool) -> UInt32 {
        if forLightText {
            return panels.max(by: { luminance($0) < luminance($1) }) ?? 0
        }
        return panels.min(by: { luminance($0) < luminance($1) }) ?? 0
    }

    /// Mix `color` toward `toward` until contrast against `background` clears.
    private static func ensureContrast(
        _ color: UInt32, against background: UInt32, minimum: Double, toward: UInt32
    ) -> UInt32 {
        if contrast(color, background) >= minimum { return color }
        var lo = 0.0
        var hi = 1.0
        var best = mix(color, toward, 1)
        for _ in 0..<16 {
            let mid = (lo + hi) / 2
            let candidate = mix(color, toward, mid)
            if contrast(candidate, background) >= minimum {
                best = candidate
                hi = mid
            } else {
                lo = mid
            }
        }
        return best
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
