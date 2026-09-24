import Testing

@testable import SigilKit

@Suite("Palette")
struct PaletteTests {

    /// Every text colour has to be readable on the panel it actually sits on.
    /// The metadata line is the one that slips: it is small, grey, and on the
    /// sidebar rather than the ground.
    @Test(arguments: TerminalTheme.all)
    func textClearsWCAGAAOnItsPanel(theme: TerminalTheme) {
        let palette = Palette(theme: theme)

        #expect(Palette.contrast(palette.textHex, palette.sidebarHex) >= 4.5)
        #expect(Palette.contrast(palette.textDimHex, palette.sidebarHex) >= 4.5)
        #expect(Palette.contrast(palette.textFaintHex, palette.sidebarHex) >= 4.5)
        // The same three sit on the selected row and on the terminal ground.
        #expect(Palette.contrast(palette.textFaintHex, palette.selectedHex) >= 4.5)
        #expect(Palette.contrast(palette.textDimHex, palette.groundHex) >= 4.5)
        // A background tab's resting close glyph is textFaint on the ground.
        #expect(Palette.contrast(palette.textFaintHex, palette.groundHex) >= 3)
    }

    /// The accent marks state, so it has to be legible as a mark, not just present.
    @Test(arguments: TerminalTheme.all)
    func accentIsVisibleAgainstEveryPanel(theme: TerminalTheme) {
        let palette = Palette(theme: theme)

        #expect(Palette.contrast(palette.accentHex, palette.sidebarHex) >= 3)
        #expect(Palette.contrast(palette.accentHex, palette.selectedHex) >= 3)
    }

    /// Hover, selection, and hairlines have to step off the rail. The terminal
    /// ground may sit close to the rail on a near-black theme; that is intended.
    @Test(arguments: TerminalTheme.all)
    func panelsStepApart(theme: TerminalTheme) {
        let palette = Palette(theme: theme)
        let steps = [
            palette.sidebarHex, palette.raisedHex,
            palette.selectedHex, palette.hairlineHex,
        ]
        let luminances = steps.map(Palette.luminance)

        for (earlier, later) in zip(luminances, luminances.dropFirst()) {
            #expect(abs(later - earlier) > 0.0008)
        }
    }

    @Test(arguments: TerminalTheme.all)
    func accentAndErrorsAreReadableAsText(theme: TerminalTheme) {
        let palette = Palette(theme: theme)
        for background in [palette.groundHex, palette.sidebarHex, palette.raisedHex, palette.selectedHex] {
            #expect(Palette.contrast(palette.accentHex, background) >= 4.5)
            #expect(Palette.contrast(palette.errorHex, background) >= 4.5)
        }
    }

    /// The rail used to be true black on every dark theme, so Discord, Figma,
    /// Ember, and Telegram all looked like the same strip. Each theme's ground
    /// has to show in the chrome.
    @Test func railsFollowTheThemeGround() {
        let neon = Palette(theme: .sigilNeon)
        let discord = Palette(theme: .discord)
        let figma = Palette(theme: .figma)
        let ember = Palette(theme: .grokEmber)
        let telegram = Palette(theme: .telegram)
        let day = Palette(theme: .grokDay)

        #expect(discord.sidebarHex != 0x000000)
        #expect(figma.sidebarHex != 0x000000)
        #expect(ember.sidebarHex != 0x000000)
        #expect(telegram.sidebarHex != 0x000000)
        #expect(
            Set([
                neon.sidebarHex, discord.sidebarHex, figma.sidebarHex,
                ember.sidebarHex, telegram.sidebarHex, day.sidebarHex,
            ]).count == 6
        )
    }

    @Test func emberRailStaysWarm() {
        let hex = Palette(theme: .grokEmber).sidebarHex
        let red = (hex >> 16) & 0xFF
        let blue = hex & 0xFF
        #expect(red > blue)
    }

    @Test func telegramRailStaysCool() {
        let hex = Palette(theme: .telegram).sidebarHex
        let red = (hex >> 16) & 0xFF
        let blue = hex & 0xFF
        #expect(blue > red)
    }
}
