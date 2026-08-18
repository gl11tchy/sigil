import Foundation
import SwiftTerm

/// A terminal colour scheme.
public struct TerminalTheme: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isDark: Bool

    public init(name: String, isDark: Bool) {
        self.name = name
        self.isDark = isDark
    }

    /// The 16 ANSI colours, in standard order.
    public var ansi: [SwiftTerm.Color] { resolved.ansi.map(Self.color) }
    /// Background, foreground, cursor and selection colours.
    public var background: SwiftTerm.Color { Self.color(resolved.background) }
    public var foreground: SwiftTerm.Color { Self.color(resolved.foreground) }
    public var cursor: SwiftTerm.Color { Self.color(resolved.cursor) }
    public var selection: SwiftTerm.Color { Self.color(resolved.selection) }

    /// Themes the app offers, `grokNight` first.
    public static let all: [TerminalTheme] = [.grokNight, .grokDay, .grokEmber]
    public static let grokNight = TerminalTheme(name: "Grok Night", isDark: true)
    public static let grokDay = TerminalTheme(name: "Grok Day", isDark: false)
    public static let grokEmber = TerminalTheme(name: "Grok Ember", isDark: true)
}

extension TerminalTheme {
    fileprivate struct HexPalette: Sendable {
        var ansi: [UInt32]
        var background: UInt32
        var foreground: UInt32
        var cursor: UInt32
        var selection: UInt32
    }

    fileprivate var resolved: HexPalette {
        switch name {
        case Self.grokDay.name:
            return Self.dayPalette
        case Self.grokEmber.name:
            return Self.emberPalette
        default:
            return isDark ? Self.nightPalette : Self.dayPalette
        }
    }

    /// Neutral black ground and grey foreground. The syntax hues stay saturated;
    /// nothing else in the theme carries a tint, so the app reads as black.
    fileprivate static let nightPalette = HexPalette(
        ansi: [
            0x1A1A1A, 0xD16B6B, 0x4FA87A, 0xC9A14A,
            0x5B8FD9, 0xB07CC6, 0x4FA8B8, 0xD2D2D2,
            0x6A6A6A, 0xE08A8A, 0x6FC49A, 0xDCC07A,
            0x82A8E8, 0xC79BDB, 0x73C4D0, 0xF0F0F0,
        ],
        background: 0x0A0A0A,
        foreground: 0xD2D2D2,
        cursor: 0xE8E8E8,
        selection: 0x2E2E2E
    )

    /// Light, high-contrast counterpart that keeps the same hues.
    fileprivate static let dayPalette = HexPalette(
        ansi: [
            0x1A2332, 0xB4232E, 0x157A3E, 0x8A6200,
            0x1D4ED8, 0x9D2BA0, 0x0E7490, 0x6B7280,
            0x4B5563, 0xDC2626, 0x15803D, 0xA16207,
            0x2563EB, 0xC026D3, 0x0891B2, 0x111827,
        ],
        background: 0xF5F7FB,
        foreground: 0x1A2332,
        cursor: 0x1D4ED8,
        selection: 0xC5D4F0
    )

    /// Warm dark theme: charcoal-ember background, parchment foreground.
    fileprivate static let emberPalette = HexPalette(
        ansi: [
            0x1C1410, 0xD46A5C, 0x7A9E5C, 0xD4A05C,
            0x5C7A9E, 0xC47A8C, 0x5C9E9E, 0xE8D5C4,
            0x6B5348, 0xE88A7A, 0x9EBE7A, 0xE8C07A,
            0x7A9EBE, 0xD49EAE, 0x7ABEBE, 0xF5EBE3,
        ],
        background: 0x140E0C,
        foreground: 0xE8D5C4,
        cursor: 0xE8A05C,
        selection: 0x3A2A22
    )

    fileprivate static func color(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red8: UInt16((hex >> 16) & 0xFF),
            green8: UInt16((hex >> 8) & 0xFF),
            blue8: UInt16(hex & 0xFF)
        )
    }
}

extension TerminalTheme {
    /// Raw `0xRRGGBB` values. The app chrome derives its colours from these so the
    /// window reads as one surface instead of a sidebar bolted onto a terminal.
    public var backgroundHex: UInt32 { resolved.background }
    public var foregroundHex: UInt32 { resolved.foreground }
    public var cursorHex: UInt32 { resolved.cursor }
    public var selectionHex: UInt32 { resolved.selection }
}
