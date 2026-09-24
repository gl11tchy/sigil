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
