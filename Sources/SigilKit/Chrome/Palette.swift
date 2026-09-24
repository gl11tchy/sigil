import AppKit
import SwiftUI

/// App chrome colours: Beautiful UI's tokens, one dark set and one light set.
///
/// The chrome no longer borrows from the terminal theme. A theme only chooses
/// the set: a dark theme gets the dark tokens, a light theme the light ones.
/// Views name tokens, never hex, so one table here is the whole colour system.
///
/// Values are Beautiful UI's OKLCH tokens converted to sRGB. The text-only
/// variants (`accentInk`, `redInk`, `greenInk`, `orangeInk`) are moved along
/// OKLCH lightness until they clear WCAG AA on every panel, `hover2` included.
/// `ink3` is moved the same way until an icon clears 3:1, and never sets
/// words. `PaletteTests` holds both floors.
public struct Palette: Equatable, Sendable {
    public let isDark: Bool

    /// The window and the sidebar.
    public let canvasHex: UInt32
    /// The inset screen that holds the tabs and the terminal.
    public let pageHex: UInt32
    /// Cards, popovers, sheets, the selected segment.
    public let surfaceHex: UInt32
    /// Wells inside a card: a segmented track, a code block.
    public let insetHex: UInt32
    /// Pointer or keyboard over a row or control.
    public let hoverHex: UInt32
    /// Selected: the open row, a secondary button.
    public let hover2Hex: UInt32
    /// Text fields and the search box.
    public let fieldHex: UInt32
    public let lineSoftHex: UInt32
    public let lineHex: UInt32
    public let lineStrongHex: UInt32
    public let inkHex: UInt32
    public let ink2Hex: UInt32
    /// Icons at rest and quiet marks, at 3:1 on every panel. Never words.
    public let ink3Hex: UInt32
    public let accentHex: UInt32
    public let accentInkHex: UInt32
    /// The accent behind white text: a primary button. Darker along OKLCH
    /// lightness than `accent`, which is too light to carry white words.
    public let accentFillHex: UInt32
    public let greenHex: UInt32
    public let orangeHex: UInt32
    public let redHex: UInt32
    public let greenInkHex: UInt32
    public let orangeInkHex: UInt32
    public let redInkHex: UInt32
    public let tooltipHex: UInt32

    public init(dark: Bool) {
        isDark = dark
        if dark {
            canvasHex = 0x1C1D1F
            pageHex = 0x17181A
            surfaceHex = 0x232427
            insetHex = 0x1F2022
            hoverHex = 0x2A2B2E
            hover2Hex = 0x313236
            fieldHex = 0x2B2C2F
            lineSoftHex = 0x27282B
            lineHex = 0x2E3033
            lineStrongHex = 0x3A3C40
            inkHex = 0xF2F3F4
            ink2Hex = 0xA5A8AD
            ink3Hex = 0x787B81
            accentHex = 0x3D9AFF
            accentInkHex = 0x7EC0FF
            accentFillHex = 0x006FD0
            greenHex = 0x3CBB72
            orangeHex = 0xF68F3C
            redHex = 0xEE5C61
            greenInkHex = 0x3CBB72
            orangeInkHex = 0xF68F3C
            redInkHex = 0xFC696D
            tooltipHex = 0x111214
        } else {
            canvasHex = 0xF1F2F3
            pageHex = 0xFAFAFB
            surfaceHex = 0xFFFFFF
            insetHex = 0xF7F8F9
            hoverHex = 0xF4F5F6
            hover2Hex = 0xE7E9EB
            fieldHex = 0xF2F2F3
            lineSoftHex = 0xF3F4F5
            lineHex = 0xECEDEF
            lineStrongHex = 0xE0E2E5
            inkHex = 0x1F2124
            ink2Hex = 0x62656B
            ink3Hex = 0x83868B
            accentHex = 0x0285FF
            accentInkHex = 0x0066D2
            accentFillHex = 0x006AE2
            greenHex = 0x199A4D
            orangeHex = 0xEF720D
            redHex = 0xE3474C
            greenInkHex = 0x007A2F
            orangeInkHex = 0xB94000
            redInkHex = 0xC72A35
            tooltipHex = 0x25272B
        }
    }

    /// The set a terminal theme wears: dark or light, nothing else.
    public init(theme: TerminalTheme) {
        self.init(dark: theme.isDark)
    }

    /// Panels text can sit on, darkest-to-lightest in dark mode.
    public var panelHexes: [UInt32] {
        [canvasHex, pageHex, surfaceHex, insetHex, hoverHex, hover2Hex, fieldHex]
    }

    // MARK: - SwiftUI

    public var canvas: Color { Self.color(canvasHex) }
    public var page: Color { Self.color(pageHex) }
    public var surface: Color { Self.color(surfaceHex) }
    public var inset: Color { Self.color(insetHex) }
    public var hover: Color { Self.color(hoverHex) }
    public var hover2: Color { Self.color(hover2Hex) }
    public var field: Color { Self.color(fieldHex) }
    public var lineSoft: Color { Self.color(lineSoftHex) }
    public var line: Color { Self.color(lineHex) }
    public var lineStrong: Color { Self.color(lineStrongHex) }
    public var ink: Color { Self.color(inkHex) }
    public var ink2: Color { Self.color(ink2Hex) }
    public var ink3: Color { Self.color(ink3Hex) }
    public var accent: Color { Self.color(accentHex) }
    public var accentInk: Color { Self.color(accentInkHex) }
    public var accentFill: Color { Self.color(accentFillHex) }
    public var green: Color { Self.color(greenHex) }
    public var orange: Color { Self.color(orangeHex) }
    public var red: Color { Self.color(redHex) }
    public var greenInk: Color { Self.color(greenInkHex) }
    public var orangeInk: Color { Self.color(orangeInkHex) }
    public var redInk: Color { Self.color(redInkHex) }
    public var tooltip: Color { Self.color(tooltipHex) }

    /// Tinted fills: a selection, a status pill. Translucent in dark mode,
    /// solid in light mode, as Beautiful UI has them.
    public var accentTint: Color { isDark ? accent.opacity(0.16) : Self.color(0xE9F3FF) }
    public var greenTint: Color { isDark ? green.opacity(0.14) : Self.color(0xE8F5ED) }
    public var orangeTint: Color { isDark ? orange.opacity(0.14) : Self.color(0xFDF1E5) }
    public var redTint: Color { isDark ? red.opacity(0.14) : Self.color(0xFCECEC) }

    /// The 1px ring that is a card's border. White at low opacity on dark,
    /// `line` on light.
    public var ring: Color { isDark ? .white.opacity(0.11) : line }
    public var ringRaised: Color { isDark ? .white.opacity(0.13) : line }
    public var ringOverlay: Color { isDark ? .white.opacity(0.15) : line }
    public var ringButton: Color { isDark ? .white.opacity(0.10) : lineStrong }

    public var canvasNSColor: NSColor { Self.nsColor(canvasHex) }
    public var pageNSColor: NSColor { Self.nsColor(pageHex) }

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

    // MARK: - Conversion

    private static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    public static func color(_ hex: UInt32) -> Color {
        let c = components(hex)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    public static func nsColor(_ hex: UInt32) -> NSColor {
        let c = components(hex)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

/// Beautiful UI's radius scale. No other values.
public enum Radius {
    /// Tab chips, key caps, small pills.
    public static let chip: CGFloat = 6
    /// Rows, buttons, fields, icon buttons.
    public static let control: CGFloat = 8
    /// Cards, popovers, sheets, banners.
    public static let card: CGFloat = 10
    /// The screen and the right panel.
    public static let window: CGFloat = 14
}

/// Beautiful UI's motion: short ease-out for colour, ease-out-strong for movement.
public enum Motion {
    public static let fade = Animation.easeOut(duration: 0.12)
    /// `cubic-bezier(.23, 1, .32, 1)`.
    public static let glide = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
    public static let slide = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(dark: true)
}

extension EnvironmentValues {
    public var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
