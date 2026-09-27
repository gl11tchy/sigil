#if canImport(Sigil)
@testable import Sigil
#endif
import Foundation

enum ThemeTests {
    static func tapTargetIs44() throws {
        try Expect.equal(ThemeMetrics.tapTarget, 44.0, "minimum tap target")
    }

    static func spaceScaleIsOrdered() throws {
        try Expect.true(
            ThemeMetrics.Space.tight < ThemeMetrics.Space.small,
            "tight < small"
        )
        try Expect.true(
            ThemeMetrics.Space.small < ThemeMetrics.Space.medium,
            "small < medium"
        )
        try Expect.true(
            ThemeMetrics.Space.medium < ThemeMetrics.Space.large,
            "medium < large"
        )
        try Expect.true(
            ThemeMetrics.Space.large < ThemeMetrics.Space.huge,
            "large < huge"
        )
        try Expect.true(
            ThemeMetrics.Radius.control < ThemeMetrics.Radius.card,
            "control radius < card radius"
        )
    }

    /// DESIGN.md: radii are chip 6, control 8, card 10, window 14, and every
    /// named gap sits on the 4pt scale.
    static func metricsMatchBeautifulUI() throws {
        try Expect.equal(ThemeMetrics.Radius.chip, 6.0, "chip radius")
        try Expect.equal(ThemeMetrics.Radius.control, 8.0, "control radius")
        try Expect.equal(ThemeMetrics.Radius.card, 10.0, "card radius")
        try Expect.equal(ThemeMetrics.Radius.window, 14.0, "window radius")
        try Expect.equal(ThemeMetrics.Space.scale, [2, 4, 6, 8, 12, 16, 20, 24, 32], "space scale")
        let named = [
            ThemeMetrics.Space.tight, ThemeMetrics.Space.small, ThemeMetrics.Space.medium,
            ThemeMetrics.Space.large, ThemeMetrics.Space.huge,
        ]
        for gap in named {
            try Expect.true(ThemeMetrics.Space.scale.contains(gap), "\(gap) is on the 4pt scale")
        }
    }

    /// The chrome follows the terminal theme: Sigil Dark and Sigil Light, a
    /// few others, and no theme at all.
    static func appearanceFollowsTheGround() throws {
        let table: [(String, Bool?)] = [
            ("17181a", true),
            ("FAFAFB", false),
            ("002b36", true),
            ("fdf6e3", false),
            ("777777", false),
            ("", nil),
            ("zzzzzz", nil),
            ("fff", nil),
        ]
        for (ground, expected) in table {
            try Expect.equal(ThemeMetrics.isDark(ground: ground), expected, "isDark(ground: \(ground))")
        }
    }

    static func emphasisStepsUp() throws {
        let table: [(Int, Bool, Int)] = [
            (0, false, 0),
            (0, true, 1),
            (3, false, 3),
            (3, true, 4),
            (8, false, 8),
            (8, true, 8),
            (-1, false, 0),
            (99, true, 8),
        ]
        for (index, bold, expected) in table {
            try Expect.equal(
                ThemeMetrics.emphasisIndex(index, boldText: bold),
                expected,
                "emphasisIndex(\(index), boldText: \(bold))"
            )
        }
    }
}
