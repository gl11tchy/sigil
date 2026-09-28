import Testing

@testable import SigilKit

@Suite("Palette")
struct PaletteTests {
    static let sets = [Palette(dark: true), Palette(dark: false)]

    /// Words use `ink` and `ink2`, and both have to read on every panel,
    /// the selected `hover2` fill included.
    @Test(arguments: sets)
    func wordsClearWCAGAAOnEveryPanel(palette: Palette) {
        for panel in palette.panelHexes {
            #expect(Palette.contrast(palette.inkHex, panel) >= 4.5)
            #expect(Palette.contrast(palette.ink2Hex, panel) >= 4.5)
        }
    }

    /// The text-only variants were moved along lightness until they cleared
    /// AA; this is the floor that move promised.
    @Test(arguments: sets)
    func accentAndStatusWordsClearWCAGAA(palette: Palette) {
        for panel in palette.panelHexes {
            #expect(Palette.contrast(palette.accentInkHex, panel) >= 4.5)
            #expect(Palette.contrast(palette.redInkHex, panel) >= 4.5)
            #expect(Palette.contrast(palette.greenInkHex, panel) >= 4.5)
            #expect(Palette.contrast(palette.orangeInkHex, panel) >= 4.5)
        }
    }

    /// Icons at rest — a tab's close glyph, the search magnifier — are `ink3`,
    /// and a control has to clear the 3:1 of a UI component everywhere it sits.
    @Test(arguments: sets)
    func iconsClearTheUIComponentFloor(palette: Palette) {
        for panel in palette.panelHexes {
            #expect(Palette.contrast(palette.ink3Hex, panel) >= 3)
        }
    }

    /// White button text sits on `accentFill`, never on `accent`.
    @Test(arguments: sets)
    func primaryButtonTextClearsWCAGAA(palette: Palette) {
        #expect(Palette.contrast(0xFFFFFF, palette.accentFillHex) >= 4.5)
    }

    /// The accent is a mark — a working light, a focus ring — so it needs the
    /// 3:1 of a UI component on the surfaces marks sit on.
    @Test(arguments: sets)
    func accentIsVisibleAsAMark(palette: Palette) {
        for panel in [palette.canvasHex, palette.pageHex, palette.surfaceHex, palette.fieldHex] {
            #expect(Palette.contrast(palette.accentHex, panel) >= 3)
        }
    }

    /// Hover and selection have to step off the surface under them, in the
    /// order they stack, or a selected row reads as a hovered one.
    @Test(arguments: sets)
    func fillsStepApartInOrder(palette: Palette) {
        let base = palette.isDark ? palette.canvasHex : palette.surfaceHex
        let steps = [base, palette.hoverHex, palette.hover2Hex].map(Palette.luminance)
        for (earlier, later) in zip(steps, steps.dropFirst()) {
            #expect(abs(later - earlier) > 0.003)
        }
    }

    /// Beautiful UI's values, kept exactly: the chrome is theirs, not derived.
    @Test func tokensAreBeautifulUIs() {
        let dark = Palette(dark: true)
        #expect(dark.canvasHex == 0x1C1D1F)
        #expect(dark.pageHex == 0x17181A)
        #expect(dark.inkHex == 0xF2F3F4)
        // ink3 is Beautiful UI's hue and chroma, lifted to the 3:1 icon floor.
        #expect(dark.ink3Hex == 0x787B81)
        #expect(dark.accentHex == 0x3D9AFF)
        let light = Palette(dark: false)
        #expect(light.canvasHex == 0xF1F2F3)
        #expect(light.pageHex == 0xFAFAFB)
        #expect(light.surfaceHex == 0xFFFFFF)
        #expect(light.accentHex == 0x0285FF)
    }

    /// A theme only picks the set.
    @Test func themesChooseTheSetByAppearance() {
        #expect(Palette(theme: .discord) == Palette(dark: true))
        #expect(Palette(theme: .grokDay) == Palette(dark: false))
        #expect(Palette(theme: .sigilLight) == Palette(dark: false))
    }
}
