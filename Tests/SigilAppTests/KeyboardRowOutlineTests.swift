import SwiftUI
import Testing

@testable import SigilApp
@testable import SigilKit

struct KeyboardRowOutlineTests {
    /// The default outline is the quiet `lineStrong`.
    @Test func standardContrastKeepsTheQuietLine() {
        #expect(KeyboardRowOutline.color(.standard) == \Palette.lineStrong)
        #expect(KeyboardRowOutline.width(.standard) == 1)
    }

    /// With Increase Contrast on, the outline must clear 3:1 on the canvas and
    /// on the hover fill it surrounds (WCAG 1.4.11), in every theme.
    @Test(arguments: TerminalTheme.all)
    func increasedContrastOutlineClearsThreeToOne(theme: TerminalTheme) throws {
        let palette = Palette(theme: theme)
        let hexes: [KeyPath<Palette, Color>: UInt32] = [
            \Palette.lineStrong: palette.lineStrongHex,
            \Palette.ink3: palette.ink3Hex,
        ]

        let outline = try #require(hexes[KeyboardRowOutline.color(.increased)])
        let hoverFill = palette.isDark ? palette.hoverHex : palette.hover2Hex

        #expect(Palette.contrast(outline, palette.canvasHex) >= 3)
        #expect(Palette.contrast(outline, hoverFill) >= 3)
        #expect(KeyboardRowOutline.width(.increased) >= 1.5)
    }
}
