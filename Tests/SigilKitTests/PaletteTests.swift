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
    }

    /// The accent marks state, so it has to be legible as a mark, not just present.
    @Test(arguments: TerminalTheme.all)
    func accentIsVisibleAgainstEveryPanel(theme: TerminalTheme) {
        let palette = Palette(theme: theme)

        #expect(Palette.contrast(palette.accentHex, palette.sidebarHex) >= 3)
        #expect(Palette.contrast(palette.accentHex, palette.selectedHex) >= 3)
    }

    /// The panels have to be distinguishable from each other, or hover and
    /// selection do not read at all.
    @Test(arguments: TerminalTheme.all)
    func panelsStepApart(theme: TerminalTheme) {
        let palette = Palette(theme: theme)
        let steps = [
            palette.groundHex, palette.sidebarHex, palette.raisedHex,
            palette.selectedHex, palette.hairlineHex,
        ]
        let luminances = steps.map(Palette.luminance)

        for (earlier, later) in zip(luminances, luminances.dropFirst()) {
            #expect(abs(later - earlier) > 0.0008)
        }
    }

    /// A tinted terminal theme must not tint the chrome.
    @Test func panelGreysAreNeutral() {
        let palette = Palette(theme: .grokEmber)
        for hex in [palette.sidebarHex, palette.raisedHex, palette.selectedHex, palette.hairlineHex] {
            let red = (hex >> 16) & 0xFF
            let green = (hex >> 8) & 0xFF
            let blue = hex & 0xFF
            #expect(red == green)
            #expect(green == blue)
        }
    }
}
