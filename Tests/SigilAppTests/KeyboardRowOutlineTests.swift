import SwiftUI
import Testing

@testable import SigilApp
@testable import SigilKit

struct KeyboardRowOutlineTests {
    /// The default outline is the quiet hairline.
    @Test func standardContrastKeepsTheHairline() {
        #expect(KeyboardRowOutline.color(.standard) == \Palette.hairline)
        #expect(KeyboardRowOutline.width(.standard) == 1)
    }

    /// With Increase Contrast on, the outline must clear 3:1 on the raised fill
    /// it surrounds (WCAG 1.4.11), in every theme.
    @Test(arguments: TerminalTheme.all)
    func increasedContrastOutlineClearsThreeToOne(theme: TerminalTheme) throws {
        let palette = Palette(theme: theme)
        let hexes: [KeyPath<Palette, Color>: UInt32] = [
            \Palette.hairline: palette.hairlineHex,
            \Palette.textFaint: palette.textFaintHex,
        ]

        let outline = try #require(hexes[KeyboardRowOutline.color(.increased)])

        #expect(Palette.contrast(outline, palette.raisedHex) >= 3)
        #expect(KeyboardRowOutline.width(.increased) >= 1.5)
    }
}
