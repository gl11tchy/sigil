import Foundation
import SwiftTerm
import Testing

@testable import SigilKit

struct TerminalThemeTests {

    @Test func allStartsWithTheAppsOwnPairAndHasAtLeastThreeThemes() {
        #expect(TerminalTheme.all.count >= 3)
        #expect(Array(TerminalTheme.all.prefix(2)) == [.sigilDark, .sigilLight])
        #expect(TerminalTheme.sigilDark.isDark)
        #expect(!TerminalTheme.sigilLight.isDark)
        #expect(TerminalTheme.all.contains(.grokNight))
        #expect(TerminalTheme.all.contains(.grokDay))
        #expect(TerminalTheme.all.contains(.grokEmber))
    }

    /// App-inspired dark themes sit in the picker after the shipping four.
    @Test func appDarkThemesAreListedAndDark() throws {
        #expect(TerminalTheme.all.count >= 20)
        for name in Self.appDarkThemeNames {
            let theme = try #require(TerminalTheme.all.first { $0.name == name })
            #expect(theme.isDark)
            #expect(theme.grokThemeName == "sigil-host")
            #expect(theme.grokThemeEnvironment["GROK_THEME_BG"] != nil)
            #expect(theme.grokThemeEnvironment["GROK_THEME_ACCENT"] != nil)
        }
    }

    @Test func themeNamesAndGroundsAreUnique() {
        let names = TerminalTheme.all.map(\.name)
        #expect(Set(names).count == names.count)
        let grounds = TerminalTheme.all.map(\.backgroundHex)
        #expect(Set(grounds).count == grounds.count)
    }

    @Test func namedInitResolvesKnownThemesAndFallsBackByAppearance() {
        #expect(TerminalTheme(name: "GitHub", isDark: true) == .githubDark)
        let dark = TerminalTheme(name: "Custom Dark", isDark: true)
        #expect(dark.name == "Custom Dark")
        #expect(dark.backgroundHex == TerminalTheme.grokNight.backgroundHex)
        let light = TerminalTheme(name: "Custom Light", isDark: false)
        #expect(light.name == "Custom Light")
        #expect(light.backgroundHex == TerminalTheme.grokDay.backgroundHex)
    }

    /// Every theme names a CLI theme, so the program and its window match.
    @Test func everyThemeNamesACLITheme() {
        #expect(TerminalTheme.sigilDark.grokThemeName == "sigil-host")
        #expect(TerminalTheme.grokDay.grokThemeName == "grokday")
        #expect(TerminalTheme.grokNight.grokThemeName == "groknight")
        #expect(TerminalTheme.grokEmber.grokThemeName == "sigil-host")
        #expect(TerminalTheme.grokNight.grokThemeEnvironment.isEmpty)
        #expect(TerminalTheme.githubDark.grokThemeEnvironment["GROK_THEME_BG"] == "0D1117")
    }

    /// The app's own themes paint the terminal in the window's tokens: the
    /// ground is `page`, the cursor is the accent, and the TUI's human turn and
    /// links use `ink2` and `accentInk` instead of the ANSI magenta and cyan.
    @Test func sigilThemesUseTheWindowTokens() {
        let dark = Palette(dark: true)
        let light = Palette(dark: false)
        #expect(TerminalTheme.sigilDark.backgroundHex == dark.pageHex)
        #expect(TerminalTheme.sigilLight.backgroundHex == light.pageHex)
        #expect(TerminalTheme.sigilDark.foregroundHex == dark.inkHex)
        #expect(TerminalTheme.sigilLight.foregroundHex == light.inkHex)
        #expect(TerminalTheme.sigilDark.cursorHex == dark.accentHex)
        let env = TerminalTheme.sigilDark.grokThemeEnvironment
        #expect(env["GROK_THEME_BG"] == "17181A")
        #expect(env["GROK_THEME_USER"] == "A5A8AD")
        #expect(env["GROK_THEME_LINK"] == "7EC0FF")
        #expect(env["GROK_THEME_DARK"] == "1")
        #expect(TerminalTheme.sigilLight.grokThemeEnvironment["GROK_THEME_DARK"] == "0")
    }

    private static let appDarkThemeNames = [
        "GitHub", "Linear", "Notion", "Discord", "Slack", "Spotify",
        "VS Code", "Cursor", "X", "Raycast", "ChatGPT", "Figma",
        "macOS", "Obsidian", "Telegram", "Twitch",
    ]

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
