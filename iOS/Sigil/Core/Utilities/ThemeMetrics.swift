import Foundation

/// Numbers the theme and the tests share. Views live in `Theme.swift`; this file
/// is the part `scripts/test.sh` can compile on macOS.
enum ThemeMetrics {
    static let tapTarget: Double = 44

    /// Beautiful UI's 4pt scale: 2, 4, 6, 8, 12, 16, 20, 24, 32.
    enum Space {
        static let scale: [Double] = [2, 4, 6, 8, 12, 16, 20, 24, 32]

        static let tight: Double = 4
        static let small: Double = 8
        static let medium: Double = 12
        static let large: Double = 16
        static let huge: Double = 24
    }

    /// Beautiful UI's radius scale. No other values.
    enum Radius {
        /// Tab chips, key caps, status pills.
        static let chip: Double = 6
        /// Rows, buttons, fields, icon buttons.
        static let control: Double = 8
        /// Cards, popovers, sheets, banners.
        static let card: Double = 10
        /// The screen: the inset page that holds the terminal.
        static let window: Double = 14
    }

    /// Whether a terminal ground, as `RRGGBB`, is a dark theme: white text reads
    /// better on it than black, the point where relative luminance is 0.179.
    /// `nil` when there is no theme yet. The chrome follows the answer, as the
    /// Mac's appearance follows its terminal theme.
    static func isDark(ground hex: String) -> Bool? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(value >> 16) + 0.7152 * linear(value >> 8) + 0.0722 * linear(value)
        return luminance < 0.179
    }

    /// Weight index 0...8 (ultraLight...black). Bold Text steps one level up.
    static func emphasisIndex(_ index: Int, boldText: Bool) -> Int {
        let clamped = min(max(index, 0), 8)
        guard boldText else { return clamped }
        return min(clamped + 1, 8)
    }
}
