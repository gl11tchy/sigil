import SwiftUI
import UIKit

/// The app's visual language, built on the two layers Liquid Glass assumes.
///
/// **Content layer** — lists, rows, cards. Opaque, built from the system's own
/// semantic colours so the app matches the OS. Content scrolls.
///
/// **Chrome layer** — the navigation bar, the tab bar, toolbars, sheets and any
/// control that floats above the content. This layer is glass, and it is glass
/// *because* opaque content passes underneath and gets lensed by it.
///
/// The rule that keeps the app looking native: **never put glass on content, and
/// never put an opaque background on chrome.** Glass over a static wallpaper has
/// nothing to refract.
///
/// Reduce Transparency is the one chrome exception: when the user has turned
/// transparency off, chrome uses an opaque palette surface of the same shape
/// so the control does not move. Content stays opaque either way.
enum Theme {

    // MARK: - Content surfaces
    //
    // System semantic colours, so the app is exactly as dark as the OS is.

    /// Behind a grouped list or a stack of cards.
    static let groupedBackground = Color(.systemGroupedBackground)
    /// A card or a list row on ``groupedBackground``.
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    /// A control inside a card — a field, a track.
    static let controlBackground = Color(.tertiarySystemFill)
    /// A plain screen with no grouping.
    static let background = Color(.systemBackground)

    static let separator = Color(.separator)

    // MARK: - Text

    static let primaryText = Color(.label)
    static let secondaryText = Color(.secondaryLabel)
    static let tertiaryText = Color(.tertiaryLabel)

    // MARK: - Accent

    /// The one accent colour. Used on the primary action and selection —
    /// never as a surface fill.
    static let accent = adaptiveColor(
        standard: (0.24, 0.60, 1.00),
        increased: (0.49, 0.75, 1.00)
    )
    /// Sigil's `accentFill`: the fill behind white text, because white on `accent` is under 3:1.
    static let accentDeep = adaptiveColor(
        standard: (0.00, 0.44, 0.82),
        increased: (0.00, 0.38, 0.72)
    )

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - State
    //
    // Each state has a colour and a symbol. Colour alone is not a signal —
    // Increase Contrast and colour blindness still have the shape.

    static let success = adaptiveColor(
        standard: (0.20, 0.78, 0.35),
        increased: (0.18, 0.90, 0.40)
    )
    static let successSymbol = "checkmark.circle.fill"
    static let danger = adaptiveColor(
        standard: (1.00, 0.27, 0.23),
        increased: (1.00, 0.40, 0.36)
    )
    static let dangerSymbol = "exclamationmark.octagon.fill"
    static let caution = adaptiveColor(
        standard: (1.00, 0.80, 0.00),
        increased: (1.00, 0.86, 0.20)
    )
    static let cautionSymbol = "exclamationmark.triangle.fill"

    static func color(for status: TabStatus) -> Color {
        switch status {
        case .working: return accent
        case .idle: return success
        case .starting: return caution
        case .exited, .unknown: return tertiaryText
        }
    }

    // MARK: - Metrics

    enum Radius {
        static let card: CGFloat = ThemeMetrics.Radius.card
        static let control: CGFloat = ThemeMetrics.Radius.control
        static let bubble: CGFloat = ThemeMetrics.Radius.bubble
    }

    enum Space {
        static let tight: CGFloat = ThemeMetrics.Space.tight
        static let small: CGFloat = ThemeMetrics.Space.small
        static let medium: CGFloat = ThemeMetrics.Space.medium
        static let large: CGFloat = ThemeMetrics.Space.large
        static let huge: CGFloat = ThemeMetrics.Space.huge

        /// Gaps that sit next to text. Scales with Dynamic Type.
        /// Structural gaps (`tight` / `small` / …) stay fixed on purpose.
        static var tightText: CGFloat { scaled(tight) }
        static var smallText: CGFloat { scaled(small) }
        static var mediumText: CGFloat { scaled(medium) }
        static var largeText: CGFloat { scaled(large) }

        static func scaled(_ value: CGFloat) -> CGFloat {
            UIFontMetrics(forTextStyle: .body).scaledValue(for: value)
        }
    }

    enum Avatar {
        static let compact: CGFloat = 36
        static let regular: CGFloat = 44
        static let profile: CGFloat = 56

        static func scaled(_ size: CGFloat) -> CGFloat {
            UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
        }
    }

    /// Minimum tappable edge. Expanding the hit area must not change the draw.
    static let tapTarget: CGFloat = ThemeMetrics.tapTarget

    // MARK: - Type

    /// Big numerals. Rounded, so the digits read as a figure.
    ///
    /// `UIFontMetrics` is the system relative scaler, not a hand-rolled
    /// multiplier. Growth is capped at 72pt so a hero figure cannot overflow
    /// its container at Accessibility sizes.
    static func display(_ size: CGFloat) -> Font {
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        let scaled = metrics.scaledValue(for: size)
        let capped = min(scaled, 72)
        return .system(size: capped, weight: emphasis(.semibold), design: .rounded)
            .monospacedDigit()
    }

    static var heading: Font {
        Font.system(.title3, design: .rounded).weight(emphasis(.semibold))
    }

    static var sectionLabel: Font {
        Font.footnote.weight(emphasis(.medium))
    }

    /// Machine text: terminal output, paths, keys. Sigil's rule is that anything a program wrote is mono.
    static var mono: Font {
        Font.system(.footnote, design: .monospaced)
    }

    static var numeric: Font {
        Font.system(.subheadline, design: .rounded).weight(emphasis(.semibold)).monospacedDigit()
    }

    /// Design weight for emphasis. Bold Text steps it up instead of replacing it.
    static func emphasis(_ weight: Font.Weight) -> Font.Weight {
        .fromThemeIndex(
            ThemeMetrics.emphasisIndex(
                weight.themeIndex,
                boldText: UIAccessibility.isBoldTextEnabled
            )
        )
    }

    // MARK: - Motion

    static func animation(_ animation: Animation) -> Animation? {
        self.animation(animation, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func withMotion(_ animation: Animation = .snappy, _ body: () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            body()
        } else {
            withAnimation(animation, body)
        }
    }

    // MARK: - Adaptive colour

    private static func adaptiveColor(
        standard: (CGFloat, CGFloat, CGFloat),
        increased: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.accessibilityContrast == .high ? increased : standard
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

// MARK: - Content layer

/// An opaque card on the grouped background. This is the content treatment —
/// it is deliberately *not* glass.
struct ContentCard: ViewModifier {
    var padding: CGFloat = Theme.Space.medium
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    /// The standard opaque content card.
    func contentCard(padding: CGFloat = Theme.Space.medium, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(ContentCard(padding: padding, radius: radius))
    }

    /// The small label that titles a group of content.
    func sectionLabelStyle() -> some View {
        font(Theme.sectionLabel)
            .foregroundStyle(Theme.secondaryText)
    }

    /// Lets a scroll view's content run under the navigation and tab bars, which
    /// is what gives those bars something to lens. Without this the glass has
    /// nothing underneath it and the whole effect disappears.
    func flowsUnderChrome() -> some View {
        scrollEdgeEffectStyle(.soft, for: .all)
    }

    /// Chrome-layer surface. Glass when transparency is allowed; an opaque
    /// palette colour of the same shape when Reduce Transparency is on.
    func chromeGlass<S: Shape>(
        _ glass: Glass = .regular,
        in shape: S,
        fallback: Color = Theme.cardBackground
    ) -> some View {
        modifier(ChromeGlass(glass: glass, shape: shape, fallback: fallback))
    }

    /// Expands the tappable area to 44pt without changing the drawn size.
    func minTappableArea(_ length: CGFloat = Theme.tapTarget) -> some View {
        modifier(MinTappableArea(length: length))
    }

    func themeAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ThemeAnimation(animation: animation, value: value))
    }
}

private struct ChromeGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var glass: Glass
    var shape: S
    var fallback: Color

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(fallback, in: shape)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

private struct MinTappableArea: ViewModifier {
    var length: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(minWidth: length, minHeight: length)
            .contentShape(Rectangle())
    }
}

private struct ThemeAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(Theme.animation(animation, reduceMotion: reduceMotion), value: value)
    }
}

// MARK: - Chrome layer

/// A control that floats above scrolling content — the only place glass belongs.
///
/// Use for a primary action pinned over a scroll view, or a small cluster of
/// controls in the corner of a screen. Everything else gets glass from the
/// system by simply not overriding the bar backgrounds.
struct FloatingGlassButtonStyle: ButtonStyle {
    var tint: Color?
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        FloatingGlassButton(configuration: configuration, tint: tint, prominent: prominent)
    }
}

private struct FloatingGlassButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration
    var tint: Color?
    var prominent: Bool

    var body: some View {
        configuration.label
            .font(.body.weight(Theme.emphasis(.semibold)))
            .foregroundStyle(prominent ? Color.white : (tint ?? Theme.primaryText))
            .padding(.horizontal, Theme.Space.large)
            .padding(.vertical, Theme.Space.medium)
            .chromeGlass(glass, in: .capsule, fallback: opaqueChrome)
            .minTappableArea()
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(
                Theme.animation(.snappy(duration: 0.2), reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }

    private var glass: Glass {
        var base: Glass = .regular
        if prominent, let tint { base = base.tint(tint) }
        return base.interactive()
    }

    private var opaqueChrome: Color {
        if prominent {
            return tint ?? Theme.accent
        }
        return Theme.cardBackground
    }
}

extension ButtonStyle where Self == FloatingGlassButtonStyle {
    /// A floating glass action. Prominent tints the material with the accent.
    static func floatingGlass(tint: Color? = nil, prominent: Bool = false) -> FloatingGlassButtonStyle {
        FloatingGlassButtonStyle(tint: tint, prominent: prominent)
    }
}

/// Compact icon control. The glyph stays small; the hit area is 44pt.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }
}

private struct IconButtonBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .minTappableArea()
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(
                Theme.animation(.snappy(duration: 0.15), reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

extension Font.Weight {
    fileprivate var themeIndex: Int {
        if self == .ultraLight { return 0 }
        if self == .thin { return 1 }
        if self == .light { return 2 }
        if self == .regular { return 3 }
        if self == .medium { return 4 }
        if self == .semibold { return 5 }
        if self == .bold { return 6 }
        if self == .heavy { return 7 }
        if self == .black { return 8 }
        return 3
    }

    fileprivate static func fromThemeIndex(_ index: Int) -> Font.Weight {
        switch index {
        case 0: return .ultraLight
        case 1: return .thin
        case 2: return .light
        case 3: return .regular
        case 4: return .medium
        case 5: return .semibold
        case 6: return .bold
        case 7: return .heavy
        default: return .black
        }
    }
}
