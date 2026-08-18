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

    /// Near-black background, cool grey-blue foreground, saturated but not neon accents.
    fileprivate static let nightPalette = HexPalette(
        ansi: [
            0x161B24, 0xD16B6B, 0x4FA87A, 0xC9A14A,
            0x5B8FD9, 0xB07CC6, 0x4FA8B8, 0xC5D0DE,
            0x5C6575, 0xE08A8A, 0x6FC49A, 0xDCC07A,
            0x82A8E8, 0xC79BDB, 0x73C4D0, 0xE8EEF5,
        ],
        background: 0x0C1017,
        foreground: 0xC5D0DE,
        cursor: 0x7AA2F7,
        selection: 0x2A3A55
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
