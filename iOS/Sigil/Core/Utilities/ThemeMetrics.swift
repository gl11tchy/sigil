import Foundation

/// Numbers the theme and the tests share. Views live in `Theme.swift`; this file
/// is the part `scripts/test.sh` can compile on macOS.
enum ThemeMetrics {
    static let tapTarget: Double = 44

    enum Space {
        static let tight: Double = 6
        static let small: Double = 10
        static let medium: Double = 16
        static let large: Double = 24
        static let huge: Double = 36
    }

    enum Radius {
        static let card: Double = 20
        static let control: Double = 12
        static let bubble: Double = 20
    }

    /// Weight index 0...8 (ultraLight...black). Bold Text steps one level up.
    static func emphasisIndex(_ index: Int, boldText: Bool) -> Int {
        let clamped = min(max(index, 0), 8)
        guard boldText else { return clamped }
        return min(clamped + 1, 8)
    }
}
