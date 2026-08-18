import Foundation
import SwiftTerm
import Testing

@testable import GrokBuildKit

struct TerminalThemeTests {

    @Test func allStartsWithGrokNightAndHasAtLeastThreeThemes() {
        #expect(TerminalTheme.all.count >= 3)
        #expect(TerminalTheme.all.first == .grokNight)
        #expect(TerminalTheme.all.contains(.grokDay))
        #expect(TerminalTheme.all.contains(.grokEmber))
    }

    @Test(arguments: TerminalTheme.all)
    func foregroundOnBackgroundMeetsWCAGAA(_ theme: TerminalTheme) {
        let ratio = contrastRatio(theme.foreground, against: theme.background)
        #expect(ratio >= 4.5)
    }

    @Test(arguments: TerminalTheme.all)
    func ansiPaletteHasSixteenUniqueColours(_ theme: TerminalTheme) {
        #expect(theme.ansi.count == 16)
        let keys = theme.ansi.map { colourKey($0) }
        #expect(Set(keys).count == 16)
    }
}

private func colourKey(_ color: SwiftTerm.Color) -> UInt64 {
    (UInt64(color.red) << 32) | (UInt64(color.green) << 16) | UInt64(color.blue)
}

private func contrastRatio(_ a: SwiftTerm.Color, against b: SwiftTerm.Color) -> Double {
    let l1 = relativeLuminance(a)
    let l2 = relativeLuminance(b)
    let lighter = max(l1, l2)
    let darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(_ color: SwiftTerm.Color) -> Double {
    func linear(_ component: UInt16) -> Double {
        let srgb = Double(component) / 65535.0
        return srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
    }
    let r = linear(color.red)
    let g = linear(color.green)
    let b = linear(color.blue)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}
