import SigilKit
import SwiftUI
import Testing

@testable import SigilApp

struct SearchHighlightedTextTests {
    private let runs = [
        SearchMatchHighlight.Run(text: "Fix ", isMatch: false),
        SearchMatchHighlight.Run(text: "auth", isMatch: true),
        SearchMatchHighlight.Run(text: " flow", isMatch: false),
    ]

    private func underlined(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run.underlineStyle == nil ? nil : String(text[run.range].characters)
        }
    }

    /// With Differentiate Without Color on, a match must not be marked by hue alone.
    @Test func matchesAreUnderlinedWhenColorCannotCarryThem() {
        let text = SearchHighlightedText.attributed(
            runs, match: .green, rest: .gray, underlineMatches: true)

        #expect(underlined(text) == ["auth"])
    }

    /// The default look stays the accent alone.
    @Test func matchesKeepTheirPlainLookByDefault() {
        let text = SearchHighlightedText.attributed(
            runs, match: .green, rest: .gray, underlineMatches: false)

        #expect(underlined(text).isEmpty)
    }
}
