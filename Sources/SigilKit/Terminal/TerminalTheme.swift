import Foundation
import SwiftTerm

/// A terminal colour scheme.
public struct TerminalTheme: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isDark: Bool
    fileprivate let hex: HexPalette
    fileprivate let cliTheme: String

    /// Looks up a shipping theme by name. An unknown name keeps the night or day
    /// palette, matching the previous public initializer.
    public init(name: String, isDark: Bool) {
        if let existing = Self.all.first(where: { $0.name == name }) {
            self = existing
            return
        }
        let base = isDark ? Self.grokNight : Self.grokDay
        self.init(name: name, isDark: isDark, hex: base.hex, cliTheme: base.cliTheme)
    }

    fileprivate init(name: String, isDark: Bool, hex: HexPalette, cliTheme: String) {
        self.name = name
        self.isDark = isDark
        self.hex = hex
        self.cliTheme = cliTheme
    }

    /// The 16 ANSI colours, in standard order.
    public var ansi: [SwiftTerm.Color] { hex.ansi.map(Self.color) }
    /// Background, foreground, cursor and selection colours.
    public var background: SwiftTerm.Color { Self.color(hex.background) }
    public var foreground: SwiftTerm.Color { Self.color(hex.foreground) }
    public var cursor: SwiftTerm.Color { Self.color(hex.cursor) }
    public var selection: SwiftTerm.Color { Self.color(hex.selection) }

    /// Themes the app offers, `sigilNeon` first — it is what the app ships as.
    public static let all: [TerminalTheme] = [
        .sigilNeon, .grokNight, .grokDay, .grokEmber,
        .githubDark, .linear, .notion, .discord, .slack, .spotify,
        .vsCode, .cursorDark, .xDark, .raycast, .chatGPT, .figma,
        .macOS, .obsidian, .telegram, .twitch,
    ]
    /// The app's own theme: a neutral near-black ground with two neon accents.
    /// The CLI is asked to render in the matching `sigil-neon` TUI theme, so the
    /// window and the program inside it are one design instead of two.
    public static let sigilNeon = make(
        name: "Sigil Neon",
        isDark: true,
        ansi: [
            0x14161A, 0xFF5F9E, 0x4EF0C4, 0xFFC46B,
            0x5AD9FF, 0xA98BFF, 0x5FE0E8, 0xC9CFD9,
            0x505864, 0xFF87B7, 0x7CFFB2, 0xFFD79B,
            0x8AE4FF, 0xC3AEFF, 0x8AEDF2, 0xE6E9EF,
        ],
        background: 0x08090B,
        foreground: 0xC9CFD9,
        cursor: 0x4EF0C4,
        selection: 0x1F242C,
        accent: 0x4EF0C4,
        cliTheme: "sigil-neon"
    )
    public static let grokNight = make(
        name: "Grok Night",
        isDark: true,
        ansi: [
            0x1A1A1A, 0xD16B6B, 0x4FA87A, 0xC9A14A,
            0x5B8FD9, 0xB07CC6, 0x4FA8B8, 0xD2D2D2,
            0x6A6A6A, 0xE08A8A, 0x6FC49A, 0xDCC07A,
            0x82A8E8, 0xC79BDB, 0x73C4D0, 0xF0F0F0,
        ],
        background: 0x0A0A0A,
        foreground: 0xD2D2D2,
        cursor: 0xE8E8E8,
        selection: 0x2E2E2E,
        accent: 0xE8934A
    )
    public static let grokDay = make(
        name: "Grok Day",
        isDark: false,
        ansi: [
            0x1A2332, 0xB4232E, 0x157A3E, 0x8A6200,
            0x1D4ED8, 0x9D2BA0, 0x0E7490, 0x6B7280,
            0x4B5563, 0xDC2626, 0x15803D, 0xA16207,
            0x2563EB, 0xC026D3, 0x0891B2, 0x111827,
        ],
        background: 0xF5F7FB,
        foreground: 0x1A2332,
        cursor: 0x1D4ED8,
        selection: 0xC5D4F0,
        accent: 0x934B11,
        cliTheme: "grokday"
    )
    public static let grokEmber = make(
        name: "Grok Ember",
        isDark: true,
        ansi: [
            0x1C1410, 0xD46A5C, 0x7A9E5C, 0xD4A05C,
            0x5C7A9E, 0xC47A8C, 0x5C9E9E, 0xE8D5C4,
            0x6B5348, 0xE88A7A, 0x9EBE7A, 0xE8C07A,
            0x7A9EBE, 0xD49EAE, 0x7ABEBE, 0xF5EBE3,
        ],
        background: 0x140E0C,
        foreground: 0xE8D5C4,
        cursor: 0xE8A05C,
        selection: 0x3A2A22,
        accent: 0xE8934A
    )

    /// Primer canvas, GitHub blue.
    public static let githubDark = make(
        name: "GitHub",
        isDark: true,
        ansi: [
            0x161B22, 0xFF7B72, 0x3FB950, 0xD29922,
            0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
            0x6E7681, 0xFFA198, 0x56D364, 0xE3B341,
            0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF0F6FC,
        ],
        background: 0x0D1117,
        foreground: 0xE6EDF3,
        cursor: 0x79C0FF,
        selection: 0x1C3A5C,
        accent: 0x58A6FF
    )
    /// Near-black void, Linear indigo.
    public static let linear = make(
        name: "Linear",
        isDark: true,
        ansi: [
            0x1C1C1F, 0xEB5757, 0x4CB782, 0xF2C94C,
            0x5E6AD2, 0xBB87FC, 0x5AC8C8, 0xD0D6E0,
            0x3C3C42, 0xFF7A7A, 0x6FDBA0, 0xFFE08A,
            0x828FFF, 0xD4A8FF, 0x8EDEDE, 0xF7F8F8,
        ],
        background: 0x08090A,
        foreground: 0xF7F8F8,
        cursor: 0x828FFF,
        selection: 0x18182F,
        accent: 0x8281FF
    )
    /// Charcoal paper, Notion blue.
    public static let notion = make(
        name: "Notion",
        isDark: true,
        ansi: [
            0x252525, 0xE03E3E, 0x0F7B6C, 0xD9730D,
            0x2383E2, 0x9065B0, 0x3D8B8B, 0xC9C9C9,
            0x5A5A5A, 0xFF6B6B, 0x2AA396, 0xF5A623,
            0x5BA8F5, 0xB085C9, 0x5EBEBE, 0xF7F6F3,
        ],
        background: 0x191919,
        foreground: 0xEBEBEB,
        cursor: 0x5BA8F5,
        selection: 0x2F3437,
        accent: 0x3C91E6
    )
    /// Discord chrome grey, lifted blurple.
    public static let discord = make(
        name: "Discord",
        isDark: true,
        ansi: [
            0x2B2D31, 0xED4245, 0x23A559, 0xF0B232,
            0x5865F2, 0xEB459E, 0x4EADC7, 0xDBDEE1,
            0x4E5058, 0xF23F42, 0x57F287, 0xFEE75C,
            0x8B95FF, 0xF47FFF, 0x5FE0E8, 0xF2F3F5,
        ],
        background: 0x1E1F22,
        foreground: 0xDBDEE1,
        cursor: 0x8B95FF,
        selection: 0x3C4270,
        accent: 0x7C87F6
    )
    /// Slack charcoal, status green.
    public static let slack = make(
        name: "Slack",
        isDark: true,
        ansi: [
            0x222529, 0xE01E5A, 0x2BAC76, 0xECB22E,
            0x1D9BD1, 0xA32D6F, 0x36C5F0, 0xD1D2D3,
            0x565856, 0xFF5C8A, 0x3DCE8E, 0xF5C84C,
            0x36B8E8, 0xC17B9E, 0x6ED7F5, 0xF8F8F8,
        ],
        background: 0x1A1D21,
        foreground: 0xD1D2D3,
        cursor: 0x3DCE8E,
        selection: 0x2C3136,
        accent: 0x2BAC76
    )
    /// Spotify black, brand green.
    public static let spotify = make(
        name: "Spotify",
        isDark: true,
        ansi: [
            0x181818, 0xF15E6C, 0x1DB954, 0xF0C040,
            0x509BF5, 0xC38EF1, 0x2DCEC8, 0xB3B3B3,
            0x535353, 0xFF7A86, 0x1ED760, 0xFFE066,
            0x7AB8FF, 0xD4A8FF, 0x5EE8E2, 0xFFFFFF,
        ],
        background: 0x121212,
        foreground: 0xFFFFFF,
        cursor: 0x1ED760,
        selection: 0x282828,
        accent: 0x1DB954
    )
    /// VS Code Dark+, lifted activity-bar blue.
    public static let vsCode = make(
        name: "VS Code",
        isDark: true,
        ansi: [
            0x1F1F1F, 0xCD3131, 0x0DBC79, 0xE5E510,
            0x2472C8, 0xBC3FBC, 0x11A8CD, 0xCCCCCC,
            0x666666, 0xF14C4C, 0x23D18B, 0xF5F543,
            0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5,
        ],
        background: 0x1E1E1E,
        foreground: 0xD4D4D4,
        cursor: 0xAEAFAD,
        selection: 0x264F78,
        accent: 0x3898D8
    )
    /// Cursor editor dark, warm orange.
    public static let cursorDark = make(
        name: "Cursor",
        isDark: true,
        ansi: [
            0x1A1A1A, 0xF48771, 0x4EC9B0, 0xDCDCAA,
            0x9CDCFE, 0xC586C0, 0x6FC3DF, 0xCCCCCC,
            0x6A9955, 0xFFA090, 0x7FDBCA, 0xF0C674,
            0xB5DFFF, 0xD7A8D4, 0x88C0D0, 0xF7F7F4,
        ],
        background: 0x181818,
        foreground: 0xE4E4E4,
        cursor: 0xFF8A65,
        selection: 0x2A2520,
        accent: 0xF6590F
    )
    /// X Lights Out, Twitter blue.
    public static let xDark = make(
        name: "X",
        isDark: true,
        ansi: [
            0x16181C, 0xF4212E, 0x00BA7C, 0xFFD400,
            0x1D9BF0, 0xF91880, 0x3DBBFF, 0xE7E9EA,
            0x536471, 0xFF6B73, 0x1AE08A, 0xFFE566,
            0x6CB5F5, 0xFF6BB5, 0x4AB8F5, 0xFFFFFF,
        ],
        background: 0x050508,
        foreground: 0xE7E9EA,
        cursor: 0x1D9BF0,
        selection: 0x1E2732,
        accent: 0x1D9BF0
    )
    /// Raycast near-black, brand red.
    public static let raycast = make(
        name: "Raycast",
        isDark: true,
        ansi: [
            0x101111, 0xFF6363, 0x5FC992, 0xFFBC33,
            0x55B3FF, 0xC084FC, 0x22D3EE, 0xD4D4D8,
            0x3F3F46, 0xFF8A8A, 0x86EFAC, 0xFFD166,
            0x7DD3FC, 0xE9B5FF, 0x67E8F9, 0xFFFFFF,
        ],
        background: 0x07080A,
        foreground: 0xF9F9F9,
        cursor: 0xFF6363,
        selection: 0x1A1C20,
        accent: 0xFF6363
    )
    /// ChatGPT surface, OpenAI green.
    public static let chatGPT = make(
        name: "ChatGPT",
        isDark: true,
        ansi: [
            0x2F2F2F, 0xEF4444, 0x10A37F, 0xF5C518,
            0x3B82F6, 0xA855F7, 0x14B8A6, 0xD1D1D1,
            0x565656, 0xF87171, 0x1FCB9A, 0xFFE066,
            0x60A5FA, 0xC084FC, 0x2DD4BF, 0xF7F7F8,
        ],
        background: 0x212121,
        foreground: 0xECECEC,
        cursor: 0x1FCB9A,
        selection: 0x2F2F2F,
        accent: 0x10A37F
    )
    /// Figma canvas grey, brand blue.
    public static let figma = make(
        name: "Figma",
        isDark: true,
        ansi: [
            0x1E1E1E, 0xF24822, 0x14AE5C, 0xF5CD47,
            0x0D99FF, 0x9747FF, 0x1BC9A0, 0xC0C0C0,
            0x555555, 0xFF6B4A, 0x3DDB7F, 0xFFE08A,
            0x4DB3FF, 0xB57AFF, 0x5EE0C4, 0xFFFFFF,
        ],
        background: 0x2C2C2C,
        foreground: 0xFFFFFF,
        cursor: 0x4DB3FF,
        selection: 0x3A3A3A,
        accent: 0x0D99FF
    )
    /// macOS dark grouped background, system blue.
    public static let macOS = make(
        name: "macOS",
        isDark: true,
        ansi: [
            0x2C2C2E, 0xFF453A, 0x30D158, 0xFFD60A,
            0x0A84FF, 0xBF5AF2, 0x64D2FF, 0xEBEBF0,
            0x636366, 0xFF6961, 0x63E6E2, 0xFFEA4A,
            0x409CFF, 0xD78CFF, 0x40C8E0, 0xFFFFFF,
        ],
        background: 0x1C1C1E,
        foreground: 0xF5F5F7,
        cursor: 0x409CFF,
        selection: 0x2C2C2E,
        accent: 0x2792FF
    )
    /// Obsidian vault grey, purple accent.
    public static let obsidian = make(
        name: "Obsidian",
        isDark: true,
        ansi: [
            0x262626, 0xE16464, 0x44CF6E, 0xE0AC40,
            0x5E8BFF, 0x7F6DF2, 0x4ECBCC, 0xDADADA,
            0x4A4A4A, 0xFF7A7A, 0x6BE08E, 0xF0C56A,
            0x86A8FF, 0xA594FF, 0x7EDEDF, 0xF5F5F5,
        ],
        background: 0x202020,
        foreground: 0xDADADA,
        cursor: 0xA594FF,
        selection: 0x2A2A2A,
        accent: 0x8E7EF4
    )
    /// Telegram night, bubble blue.
    public static let telegram = make(
        name: "Telegram",
        isDark: true,
        ansi: [
            0x0E1621, 0xE53935, 0x4CAF50, 0xF5A623,
            0x2AABEE, 0xC35FD8, 0x26C6DA, 0xC8C8C8,
            0x3E5468, 0xFF6E6A, 0x66BB6A, 0xFFC14D,
            0x6AB3F3, 0xE08AF0, 0x4DD0E1, 0xFFFFFF,
        ],
        background: 0x17212B,
        foreground: 0xF5F5F5,
        cursor: 0x6AB3F3,
        selection: 0x2B5278,
        accent: 0x2AABEE
    )
    /// Twitch dark, purple.
    public static let twitch = make(
        name: "Twitch",
        isDark: true,
        ansi: [
            0x18181B, 0xEB0400, 0x00F593, 0xFFB31A,
            0x1F69FF, 0x9147FF, 0x00D4FF, 0xADADB8,
            0x53535F, 0xFF4D4D, 0x00FFA3, 0xFFD166,
            0x5B8DEF, 0xBF94FF, 0x5CE1FF, 0xEFEFF1,
        ],
        background: 0x0E0E10,
        foreground: 0xEFEFF1,
        cursor: 0xBF94FF,
        selection: 0x2A1F3D,
        accent: 0xBF94FF
    )
}

extension TerminalTheme {
    fileprivate struct HexPalette: Sendable, Hashable {
        var ansi: [UInt32]
        var background: UInt32
        var foreground: UInt32
        var cursor: UInt32
        var selection: UInt32
        var accent: UInt32
    }

    fileprivate static func make(
        name: String,
        isDark: Bool,
        ansi: [UInt32],
        background: UInt32,
        foreground: UInt32,
        cursor: UInt32,
        selection: UInt32,
        accent: UInt32,
        cliTheme: String = "groknight"
    ) -> TerminalTheme {
        TerminalTheme(
            name: name,
            isDark: isDark,
            hex: HexPalette(
                ansi: ansi,
                background: background,
                foreground: foreground,
                cursor: cursor,
                selection: selection,
                accent: accent
            ),
            cliTheme: cliTheme
        )
    }

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
    public var backgroundHex: UInt32 { hex.background }
    public var foregroundHex: UInt32 { hex.foreground }
    public var cursorHex: UInt32 { hex.cursor }
    public var selectionHex: UInt32 { hex.selection }

    /// The one accent the app chrome is allowed. It comes off the sigil mark, and
    /// marks state only: the open conversation, a session doing work, a focused
    /// field. The terminal itself never uses it.
    public var accentHex: UInt32 { hex.accent }

    /// The name of the CLI theme that matches this one. It reaches the CLI as
    /// `GROK_THEME`, which a build that does not know the name simply ignores.
    public var grokThemeName: String { cliTheme }
}
