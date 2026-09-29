import Foundation

/// How the workbench window divides its width.
///
/// The terminal comes first and keeps at least `terminalMinimum`. The review
/// region comes next when it is open, then the rail. When all three do not
/// fit, the review region and the rail first shrink to their minimums; then
/// an open review region hides the rail. Nothing overlays the terminal.
public struct WorkbenchColumns: Equatable, Sendable {
    public static let terminalMinimum = 480.0
    public static let railRange = 200.0...320.0
    public static let reviewRange = 300.0...420.0
    public static let railDefault = 248.0
    public static let reviewDefault = 340.0
    /// The window inset between screens and the window edge.
    public static let inset = 10.0

    /// Nil when hidden.
    public let rail: Double?
    public let review: Double?
    /// The screen that holds the context header and the terminal.
    public let screen: Double
    /// True when the user asked for the rail but the open review region took its room.
    public let railYieldedToReview: Bool

    public init(
        width: Double, railWidth: Double = railDefault, reviewWidth: Double = reviewDefault,
        showsRail: Bool, showsReview: Bool
    ) {
        let total = width.isFinite ? max(0, width) : 0
        let railWanted = Self.clamp(railWidth, Self.railRange, default: Self.railDefault)
        let reviewWanted = Self.clamp(reviewWidth, Self.reviewRange, default: Self.reviewDefault)

        func fit(rail: Bool, review: Bool) -> (rail: Double, review: Double)? {
            var railWidth = rail ? railWanted : 0
            var reviewWidth = review ? reviewWanted : 0
            var over = railWidth + reviewWidth - (total - Self.chrome(rail: rail, review: review) - Self.terminalMinimum)
            if over > 0, review {
                let cut = min(over, reviewWidth - Self.reviewRange.lowerBound)
                reviewWidth -= cut
                over -= cut
            }
            if over > 0, rail {
                let cut = min(over, railWidth - Self.railRange.lowerBound)
                railWidth -= cut
                over -= cut
            }
            return over > 0 ? nil : (railWidth, reviewWidth)
        }

        var attempts: [(rail: Bool, review: Bool)] = []
        if showsReview { attempts += [(showsRail, true), (false, true)] }
        attempts += [(showsRail, false), (false, false)]
        var chosen = (rail: false, review: false, widths: (rail: 0.0, review: 0.0))
        for attempt in attempts {
            if let widths = fit(rail: attempt.rail, review: attempt.review) {
                chosen = (attempt.rail, attempt.review, widths)
                break
            }
        }
        rail = chosen.rail ? chosen.widths.rail : nil
        review = chosen.review ? chosen.widths.review : nil
        screen = max(0, total - Self.chrome(rail: chosen.rail, review: chosen.review) - (rail ?? 0) - (review ?? 0))
        railYieldedToReview = showsRail && !chosen.rail && chosen.review
    }

    /// Insets around the screens: the trailing edge, the leading edge when no
    /// rail sits there, and the gap between the screen and the review region.
    static func chrome(rail: Bool, review: Bool) -> Double {
        inset + (rail ? 0 : inset) + (review ? inset : 0)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
