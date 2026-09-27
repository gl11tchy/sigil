import SwiftUI
import UIKit

/// The app's visual language: Beautiful UI, as DESIGN.md sets it out for every
/// Sigil surface. The Mac app, the website and the web companion use the same
/// tokens, the same two typefaces, the same radii and the same motion.
///
/// **Quiet chrome, loud content.** Cool near-neutral greys carry the screen.
/// Colour appears only where it carries state.
///
/// **Structure from fill and ring.** A card is an opaque fill with a 1px ring
/// and a short shadow. There is no glass: chrome is an opaque token fill too,
/// so Reduce Transparency changes nothing. Menus, alerts, confirmation dialogs,
/// the share sheet and the scanner stay native.
///
/// Every colour is a named token with a dark and a light value, and a stronger
/// value under Increase Contrast. Views name tokens, never hex. A UIKit view
/// takes the same token through `UIColor(Theme.page)`; the dynamic provider
/// survives the round trip.
enum Theme {

    // MARK: - Surfaces

    /// The frame: the screen's ground, the toolbar, the composer's row.
    static let canvas = token(dark: 0x1C1D1F, light: 0xF1F2F3)
    /// The inset page that holds the terminal.
    static let page = token(dark: 0x17181A, light: 0xFAFAFB)
    /// Cards, popovers, sheets, banners, the find bar, the composer card.
    static let surface = token(dark: 0x232427, light: 0xFFFFFF)
    /// A well inside a card: a segmented track, a code block.
    static let inset = token(dark: 0x1F2022, light: 0xF7F8F9)
    /// A row or control under the finger.
    static let hover = token(dark: 0x2A2B2E, light: 0xF4F5F6)
    /// Selected: the open row, a secondary button, a pressed icon button.
    static let hover2 = token(dark: 0x313236, light: 0xE7E9EB)
    /// Text fields and the search box.
    static let field = token(dark: 0x2B2C2F, light: 0xF2F2F3)

    // MARK: - Lines

    /// Rules inside a card.
    static let lineSoft = token(dark: 0x27282B, light: 0xF3F4F5, darkHigh: 0x3A3C40, lightHigh: 0xE3E5E8)
    /// Region rules, and card rings in light mode.
    static let line = token(dark: 0x2E3033, light: 0xECEDEF, darkHigh: 0x44464B, lightHigh: 0xD5D8DC)
    /// Key caps, focused-but-idle strokes.
    static let lineStrong = token(dark: 0x3A3C40, light: 0xE0E2E5, darkHigh: 0x55585D, lightHigh: 0xBFC3C8)

    // MARK: - Ink

    /// Titles, labels, body text.
    static let ink = token(dark: 0xF2F3F4, light: 0x1F2124, darkHigh: 0xFFFFFF, lightHigh: 0x0E0F11)
    /// Secondary text, metadata, placeholders. Clears 4.5:1 on every panel.
    static let ink2 = token(dark: 0xA5A8AD, light: 0x62656B, darkHigh: 0xC3C6CA, lightHigh: 0x474A4F)
    /// Icons at rest and quiet marks, at 3:1 on every panel. **Never words.**
    static let ink3 = token(dark: 0x787B81, light: 0x83868B, darkHigh: 0x9A9DA3, lightHigh: 0x5F6268)

    // MARK: - Accent

    /// Focus rings, the working mark, selection, icons that carry state. Not
    /// under white text: use ``accentFill``. Not for words: use ``accentInk``.
    static let accent = token(dark: 0x3D9AFF, light: 0x0285FF, darkHigh: 0x7EC0FF, lightHigh: 0x0066D2)
    /// Accent-coloured words: links, search matches.
    static let accentInk = token(dark: 0x7EC0FF, light: 0x0066D2, darkHigh: 0xA8D4FF, lightHigh: 0x0050A8)
    /// The fill behind white text: the primary button, send.
    static let accentFill = token(dark: 0x006FD0, light: 0x006AE2, darkHigh: 0x005BB0, lightHigh: 0x0055B8)
    /// A tinted fill: a selected list item, text selection, the accent pill.
    static let accentTint = tint(0x3D9AFF, opacity: 0.16, light: 0xE9F3FF)

    // MARK: - State

    /// Completed, connected. A mark or a fill; words use ``greenInk``.
    static let green = token(dark: 0x3CBB72, light: 0x199A4D, darkHigh: 0x5BD08A, lightHigh: 0x007A2F)
    /// Waiting, warnings. A mark or a fill; words use ``orangeInk``.
    static let orange = token(dark: 0xF68F3C, light: 0xEF720D, darkHigh: 0xFFA75E, lightHigh: 0xB94000)
    /// Failed, destructive. A mark or a fill; words use ``redInk``.
    static let red = token(dark: 0xEE5C61, light: 0xE3474C, darkHigh: 0xFF8185, lightHigh: 0xC72A35)
    static let greenInk = token(dark: 0x3CBB72, light: 0x007A2F, darkHigh: 0x5BD08A, lightHigh: 0x006326)
    static let orangeInk = token(dark: 0xF68F3C, light: 0xB94000, darkHigh: 0xFFA75E, lightHigh: 0x963400)
    static let redInk = token(dark: 0xFC696D, light: 0xC72A35, darkHigh: 0xFF8185, lightHigh: 0xA8222C)
    /// Status pill fills: the colour at 14% in dark mode, a solid tint in light.
    static let greenTint = tint(0x3CBB72, opacity: 0.14, light: 0xE8F5ED)
    static let orangeTint = tint(0xF68F3C, opacity: 0.14, light: 0xFDF1E5)
    static let redTint = tint(0xEE5C61, opacity: 0.14, light: 0xFCECEC)

    /// Tooltip and toast ground. Text on it is white.
    static let tooltip = token(dark: 0x111214, light: 0x25272B)

    // MARK: - Rings
    //
    // The 1px ring that is a card's border: white at low opacity in dark mode,
    // a line token in light mode. The ring *is* the border; never add another.

    static let ring = ring(dark: 0.11, light: (0xECEDEF, 0xD5D8DC))
    static let ringRaised = ring(dark: 0.13, light: (0xECEDEF, 0xD5D8DC))
    static let ringOverlay = ring(dark: 0.15, light: (0xECEDEF, 0xD5D8DC))
    static let ringButton = ring(dark: 0.10, light: (0xE0E2E5, 0xBFC3C8))

    // MARK: - State marks
    //
    // Each state has a colour and a symbol. Colour alone is not a signal —
    // Increase Contrast and colour blindness still have the shape.

    static let dangerSymbol = "exclamationmark.octagon.fill"
    static let cautionSymbol = "exclamationmark.triangle.fill"

    // MARK: - Metrics

    enum Radius {
        /// Key caps, status pills, small chips.
        static let chip: CGFloat = ThemeMetrics.Radius.chip
        /// Rows, buttons, fields, icon buttons.
        static let control: CGFloat = ThemeMetrics.Radius.control
        /// Cards, popovers, sheets, banners.
        static let card: CGFloat = ThemeMetrics.Radius.card
        /// The inset page that holds the terminal.
        static let window: CGFloat = ThemeMetrics.Radius.window
    }

    enum Space {
        /// The 4pt scale by value. Use these, or the named gaps below.
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32

        static let tight: CGFloat = ThemeMetrics.Space.tight
        static let small: CGFloat = ThemeMetrics.Space.small
        static let medium: CGFloat = ThemeMetrics.Space.medium
        static let large: CGFloat = ThemeMetrics.Space.large

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

    /// Minimum tappable edge. Expanding the hit area must not change the draw.
    static let tapTarget: CGFloat = ThemeMetrics.tapTarget

    // MARK: - Elevation

    /// How far a surface sits above what is under it. Each step is Beautiful
    /// UI's ring plus its shadow, per appearance.
    enum Elevation {
        /// The page: a `line` ring, no shadow.
        case flat
        /// Cards, the composer.
        case card
        /// Banners, the toolbar's controls, anything floating a little.
        case raised
        /// The find bar, popovers, sheets drawn in-app.
        case overlay
        /// A lifted control: the selected segment, a key.
        case button

        var ring: Color {
            switch self {
            case .flat: return Theme.line
            case .card: return Theme.ring
            case .raised: return Theme.ringRaised
            case .overlay: return Theme.ringOverlay
            case .button: return Theme.ringButton
            }
        }

        /// Up to two stacked shadows: black at `opacity`, blurred by `radius`, dropped by `y`.
        func shadows(dark: Bool) -> [Shadow] {
            switch (self, dark) {
            case (.flat, _): return []
            case (.card, true): return [Shadow(0.20, 1, 1), Shadow(0.20, 3, 2)]
            case (.card, false): return [Shadow(0.03, 1, 1), Shadow(0.04, 8, 6)]
            case (.raised, true): return [Shadow(0.22, 5, 2)]
            case (.raised, false): return [Shadow(0.06, 4, 2)]
            case (.overlay, true): return [Shadow(0.34, 14, 8)]
            case (.overlay, false): return [Shadow(0.12, 16, 12)]
            case (.button, true): return [Shadow(0.30, 1, 1)]
            case (.button, false): return [Shadow(0.04, 2, 1)]
            }
        }
    }

    struct Shadow {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat

        init(_ opacity: Double, _ radius: CGFloat, _ y: CGFloat) {
            self.opacity = opacity
            self.radius = radius
            self.y = y
        }
    }

    // MARK: - Type
    //
    // Inter for every human-language string, JetBrains Mono for anything a
    // program wrote. Weights 400, 500 and 600 only. Each step is DESIGN.md's
    // size at the default text size, scaled by Dynamic Type relative to the
    // matching text style. Bold Text moves a step to the next bundled face.

    enum TypeStep: CaseIterable {
        /// 15/20, 600. Sheet and screen titles, the session name.
        case title
        /// 14/20. Rows and list items; 500 when selected.
        case row
        /// 13/18. Buttons, banners, card text, settings rows.
        case body
        /// 12.5/16. Section labels, secondary lines, chips (500).
        case small
        /// 11.5/16, JetBrains Mono. Paths, times, counts.
        case mono
        /// 10.5/14, JetBrains Mono. Key caps.
        case micro
        /// 16/22. Text the user types: the composer, the find field, the
        /// pairing link. 16pt, as the web textarea, so iOS does not zoom.
        case field

        var size: CGFloat {
            switch self {
            case .title: return 15
            case .row: return 14
            case .body: return 13
            case .small: return 12.5
            case .mono: return 11.5
            case .micro: return 10.5
            case .field: return 16
            }
        }

        var lineHeight: CGFloat {
            switch self {
            case .title, .row: return 20
            case .body: return 18
            case .small, .mono: return 16
            case .micro: return 14
            case .field: return 22
            }
        }

        var textStyle: Font.TextStyle {
            switch self {
            case .title: return .headline
            case .row, .field: return .body
            case .body: return .subheadline
            case .small: return .footnote
            case .mono: return .caption
            case .micro: return .caption2
            }
        }

        var isMono: Bool { self == .mono || self == .micro }

        var defaultWeight: Font.Weight { self == .title ? .semibold : .regular }
    }

    /// The font for a type step. Prefer `.typeStep(_:weight:)` on a view, which
    /// adds the tracking and line height too.
    static func font(_ step: TypeStep, weight: Font.Weight? = nil) -> Font {
        let weight = emphasis(weight ?? step.defaultWeight)
        return step.isMono
            ? jetBrainsMono(step.size, weight, relativeTo: step.textStyle)
            : inter(step.size, weight, relativeTo: step.textStyle)
    }

    /// Inter at `size`, scaled with `style`. 400, 500 or 600; heavier asks get 600.
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(interFace(weight), size: size, relativeTo: style)
    }

    /// JetBrains Mono at `size`, scaled with `style`.
    static func jetBrainsMono(
        _ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body
    ) -> Font {
        .custom(monoFace(weight), size: size, relativeTo: style)
    }

    /// An SF Symbol in the chrome: 16pt at the default text size, 500. Callout
    /// is 16pt at the default size, so the glyph follows Dynamic Type live.
    static var glyph: Font {
        .system(.callout, weight: emphasis(.medium))
    }

    /// Machine text: paths, keys, codes. Anything a program wrote is mono.
    static var mono: Font { font(.mono) }

    /// Design weight for emphasis. Bold Text steps it up instead of replacing it.
    static func emphasis(_ weight: Font.Weight) -> Font.Weight {
        .fromThemeIndex(
            ThemeMetrics.emphasisIndex(
                weight.themeIndex,
                boldText: UIAccessibility.isBoldTextEnabled
            )
        )
    }

    static func interFace(_ weight: Font.Weight) -> String {
        switch weight.themeIndex {
        case ..<4: return "Inter-Regular"
        case 4: return "Inter-Medium"
        default: return "Inter-SemiBold"
        }
    }

    static func monoFace(_ weight: Font.Weight) -> String {
        switch weight.themeIndex {
        case ..<4: return "JetBrainsMono-Regular"
        case 4: return "JetBrainsMono-Medium"
        default: return "JetBrainsMono-Bold"
        }
    }

    // MARK: - Motion
    //
    // 120–160ms. Ease-out for colour and opacity; ease-out-strong for anything
    // that moves. Reduce Motion gets the end state.

    enum Motion {
        static let fade = Animation.easeOut(duration: 0.12)
        /// `cubic-bezier(.23, 1, .32, 1)`.
        static let slide = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    }

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

    /// A token: exact sRGB per appearance, and the Increase Contrast value
    /// where DESIGN.md's floor needs one. Values are Palette.swift's.
    private static func token(
        dark: UInt32, light: UInt32, darkHigh: UInt32? = nil, lightHigh: UInt32? = nil
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark {
                return uiColor(high ? darkHigh ?? dark : dark)
            }
            return uiColor(high ? lightHigh ?? light : light)
        })
    }

    /// Translucent in dark mode, solid in light, as Beautiful UI has its tints.
    private static func tint(_ dark: UInt32, opacity: CGFloat, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? uiColor(dark).withAlphaComponent(opacity)
                : uiColor(light)
        })
    }

    /// White at `dark` opacity in dark mode; a line token in light mode.
    /// Increase Contrast adds 12 points of opacity, or takes the stronger line.
    private static func ring(dark: CGFloat, light: (UInt32, UInt32)) -> Color {
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark {
                return UIColor.white.withAlphaComponent(high ? dark + 0.12 : dark)
            }
            return uiColor(high ? light.1 : light.0)
        })
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Surfaces

extension View {
    /// A filled shape with the ring and shadow for `elevation`. Every card,
    /// banner, bar and floating control is one of these.
    func surface<S: InsettableShape>(
        _ fill: Color = Theme.surface, in shape: S, elevation: Theme.Elevation = .card
    ) -> some View {
        modifier(SurfaceModifier(fill: fill, shape: shape, elevation: elevation))
    }

    /// A filled rounded rectangle with the ring and shadow for `elevation`.
    func surface(
        _ fill: Color = Theme.surface, radius: CGFloat = Theme.Radius.card, elevation: Theme.Elevation = .card
    ) -> some View {
        surface(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous), elevation: elevation)
    }

    /// The standard card: padding, a `surface` fill, the `card` ring and shadow.
    func contentCard(padding: CGFloat = Theme.Space.medium, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(ContentCard(padding: padding, radius: radius))
    }

    /// Beautiful UI's text field frame: `field` fill, `control` radius, and a
    /// 1px `accent` ring while focused.
    func fieldBackground(isFocused: Bool, radius: CGFloat = Theme.Radius.control) -> some View {
        modifier(FieldBackground(isFocused: isFocused, radius: radius))
    }

    /// The small label that titles a group of content: 12.5pt 500, `ink2`, sentence case.
    func sectionLabelStyle() -> some View {
        typeStep(.small, weight: .medium)
            .foregroundStyle(Theme.ink2)
    }

    /// A type step with its tracking and line height: -0.01em from 13pt up for
    /// Inter, none for mono. Follows Dynamic Type and Bold Text live.
    func typeStep(_ step: Theme.TypeStep, weight: Font.Weight? = nil) -> some View {
        modifier(TypeStepModifier(step: step, weight: weight))
    }

    /// Lets a scroll view's content run under the navigation bar with a soft edge.
    func flowsUnderChrome() -> some View {
        scrollEdgeEffectStyle(.soft, for: .all)
    }

    /// Expands the tappable area to 44pt without changing the drawn size.
    func minTappableArea(_ length: CGFloat = Theme.tapTarget) -> some View {
        modifier(MinTappableArea(length: length))
    }

    func themeAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ThemeAnimation(animation: animation, value: value))
    }
}

private struct SurfaceModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let fill: Color
    let shape: S
    let elevation: Theme.Elevation

    func body(content: Content) -> some View {
        let shadows = elevation.shadows(dark: colorScheme == .dark)
        content
            .background {
                shape.fill(fill)
                    .shadow(
                        color: .black.opacity(shadows.first?.opacity ?? 0),
                        radius: shadows.first?.radius ?? 0, y: shadows.first?.y ?? 0)
                    .shadow(
                        color: .black.opacity(shadows.dropFirst().first?.opacity ?? 0),
                        radius: shadows.dropFirst().first?.radius ?? 0, y: shadows.dropFirst().first?.y ?? 0)
            }
            .overlay { shape.strokeBorder(elevation.ring, lineWidth: 1) }
    }
}

/// An opaque card: `surface`, the `card` ring and its short shadow.
struct ContentCard: ViewModifier {
    var padding: CGFloat = Theme.Space.medium
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .surface(Theme.surface, radius: radius, elevation: .card)
    }
}

private struct FieldBackground: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isFocused: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Theme.field, in: shape)
            .overlay { shape.strokeBorder(isFocused ? Theme.accent : .clear, lineWidth: 1) }
            .animation(Theme.animation(Theme.Motion.fade, reduceMotion: reduceMotion), value: isFocused)
    }
}

private struct TypeStepModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    let step: Theme.TypeStep
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        let base = weight ?? step.defaultWeight
        let weight = Font.Weight.fromThemeIndex(
            ThemeMetrics.emphasisIndex(base.themeIndex, boldText: legibilityWeight == .bold))
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let metrics = UIFontMetrics(forTextStyle: step.textStyle.uiTextStyle)
        let size = metrics.scaledValue(for: step.size, compatibleWith: traits)
        let lineHeight = metrics.scaledValue(for: step.lineHeight, compatibleWith: traits)
        let face = step.isMono ? Theme.monoFace(weight) : Theme.interFace(weight)
        let natural = UIFont(name: face, size: size)?.lineHeight ?? size * 1.2
        content
            .font(.custom(face, size: step.size, relativeTo: step.textStyle))
            .tracking(!step.isMono && step.size >= 13 ? -0.01 * size : 0)
            .lineSpacing(max(0, lineHeight - natural))
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

// MARK: - Buttons

/// Beautiful UI's buttons. Primary is `accentFill` under white 500 text;
/// secondary is `hover2` under `ink` with the `button` ring; ghost is `ink2`
/// text that fills with `hover` while pressed; destructive is `redInk` on the
/// red tint, ringed in red while pressed. All take the `control` radius and a
/// 44pt height. Disabled, secondary and ghost dim to 40%; a filled kind turns
/// `hover2` under `ink2`, because white on a 40% fill washes out on a light page.
/// A label keeps to one line until the accessibility text sizes, where it wraps.
struct SigilButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    var kind: Kind = .secondary
    var height: CGFloat = Theme.tapTarget

    func makeBody(configuration: Configuration) -> some View {
        SigilButton(configuration: configuration, kind: kind, height: height)
    }
}

private struct SigilButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let configuration: ButtonStyleConfiguration
    let kind: SigilButtonStyle.Kind
    let height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        let pressed = configuration.isPressed
        let filled = kind == .primary || kind == .destructive
        configuration.label
            .typeStep(.body, weight: .medium)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Space.large)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? Theme.Space.small : 0)
            .frame(minHeight: height)
            .background {
                shape.fill(background)
                    // Pressed deepens the fill a step, the way the web companion's :active does.
                    .overlay(shape.fill(pressedLayer.opacity(pressed ? 1 : 0)))
            }
            .overlay {
                // The Mac's ring: white 10% on the primary fill, `ringButton` on a secondary.
                // A destructive button rings in red while pressed, as the web's does.
                switch kind {
                case .primary where isEnabled: shape.strokeBorder(.white.opacity(0.10), lineWidth: 1)
                case .secondary: shape.strokeBorder(Theme.ringButton, lineWidth: 1)
                case .destructive: shape.strokeBorder(Theme.red.opacity(0.6), lineWidth: 1).opacity(pressed ? 1 : 0)
                default: EmptyView()
                }
            }
            .contentShape(shape)
            .opacity(isEnabled || filled ? 1 : 0.4)
            .scaleEffect(reduceMotion || !pressed ? 1 : 0.98)
            .animation(Theme.animation(Theme.Motion.fade, reduceMotion: reduceMotion), value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary where !isEnabled, .destructive where !isEnabled: return Theme.ink2
        case .primary: return .white
        case .secondary: return Theme.ink
        case .ghost: return configuration.isPressed ? Theme.ink : Theme.ink2
        case .destructive: return Theme.redInk
        }
    }

    private var background: Color {
        switch kind {
        case .primary where !isEnabled, .destructive where !isEnabled: return Theme.hover2
        case .primary: return Theme.accentFill
        case .secondary: return Theme.hover2
        case .ghost: return .clear
        case .destructive: return Theme.redTint
        }
    }

    private var pressedLayer: Color {
        switch kind {
        case .primary: return .black.opacity(0.06)
        case .secondary: return Theme.ink.opacity(0.08)
        case .ghost: return Theme.hover
        // Deepening the tint would drop the red text under 4.5:1; the ring shows the press.
        case .destructive: return .clear
        }
    }
}

extension ButtonStyle where Self == SigilButtonStyle {
    /// `accentFill`, white 500 text, 44pt. One per screen.
    static var primary: SigilButtonStyle { SigilButtonStyle(kind: .primary) }
    /// `hover2`, `ink` text, the `button` ring, 44pt.
    static var secondary: SigilButtonStyle { SigilButtonStyle(kind: .secondary) }
    /// `redInk` on the red tint, 44pt.
    static var destructive: SigilButtonStyle { SigilButtonStyle(kind: .destructive) }
    /// `ink2` text, a `hover` fill while pressed, 44pt.
    static var ghost: SigilButtonStyle { SigilButtonStyle(kind: .ghost) }
}

/// A word button in a sheet's navigation bar, as the web companion's sheet
/// heading draws Done and Cancel: Inter 500 in `accentInk`, 10pt side padding,
/// the `hover` fill while pressed, no glass. Prominent is the compact primary
/// button, for the sheet's one confirming action; disabled, it is a disabled primary.
struct BarButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        BarButton(configuration: configuration, prominent: prominent)
    }
}

private struct BarButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration
    let prominent: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        let pressed = configuration.isPressed
        configuration.label
            .typeStep(.body, weight: .medium)
            .lineLimit(1)
            // The bar proposes a narrow width to a custom item; the word keeps its own.
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(prominent ? (isEnabled ? Color.white : Theme.ink2) : Theme.accentInk)
            .padding(.horizontal, prominent ? Theme.Space.s12 : 10)
            .frame(minHeight: 32)
            .background {
                if prominent, isEnabled {
                    shape.fill(Theme.accentFill)
                        .overlay(shape.fill(Color.black.opacity(pressed ? 0.06 : 0)))
                        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 1))
                } else if prominent {
                    shape.fill(Theme.hover2)
                } else {
                    shape.fill(Theme.hover).opacity(pressed ? 1 : 0)
                }
            }
            .contentShape(shape)
            .frame(minHeight: Theme.tapTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled || prominent ? 1 : 0.4)
            .animation(Theme.animation(Theme.Motion.fade, reduceMotion: reduceMotion), value: pressed)
    }
}

extension ButtonStyle where Self == BarButtonStyle {
    /// A navigation bar word: `accentInk`, no glass.
    static var bar: BarButtonStyle { BarButtonStyle() }
    /// The sheet's confirming action in its navigation bar: a compact primary button.
    static var barProminent: BarButtonStyle { BarButtonStyle(prominent: true) }
}

/// An icon control: the glyph in `ink3` at rest (a label that sets its own
/// colour keeps it), a 44pt hit area, and a 32pt `hover2` fill while pressed.
/// A label with its own opaque fill hides the pressed fill behind it.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }
}

private struct IconButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.ink : Theme.ink3)
            .minTappableArea()
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.hover2)
                    .padding(Theme.Space.s6)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .animation(
                Theme.animation(Theme.Motion.fade, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

// MARK: - Marks

/// Beautiful UI's pixel-grid loader: a 3×3 grid of 2.5pt squares with a
/// highlight that travels around the ring. Reduce Motion holds a steady grid
/// with the centre lit.
struct PixelLoader: View {
    var color: Color = Theme.accent
    var cell: CGFloat = 2.5
    var gap: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ring order, clockwise from the top-left cell.
    private static let ring = [0, 1, 2, 5, 8, 7, 6, 3]
    private static let period = 0.96

    var body: some View {
        Group {
            if reduceMotion {
                grid { index in index == 4 ? 1 : 0.35 }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let phase =
                        context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.period) / Self.period
                    grid { index in Self.brightness(of: index, phase: phase) }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func grid(_ brightness: @escaping (Int) -> Double) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 0.6)
                            .fill(color.opacity(brightness(row * 3 + column)))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: cell * 3 + gap * 2, height: cell * 3 + gap * 2)
    }

    /// The head of the highlight is at full strength; the two cells behind it
    /// fade; everything else rests.
    static func brightness(of index: Int, phase: Double) -> Double {
        if index == 4 { return 0.55 }
        guard let slot = ring.firstIndex(of: index) else { return 0.25 }
        let head = phase * Double(ring.count)
        var behind = head - Double(slot)
        if behind < 0 { behind += Double(ring.count) }
        switch behind {
        case ..<1: return 1
        case ..<2: return 0.6
        case ..<3: return 0.4
        default: return 0.22
        }
    }
}

/// A 6pt state dot. ``UnreadDot`` is the accent one.
struct StatusDot: View {
    var color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

/// A finished session the owner has not looked at yet: a 6pt `accent` dot.
struct UnreadDot: View {
    var body: some View { StatusDot(color: Theme.accent) }
}

/// DESIGN.md's state vocabulary in a 10pt slot, so text beside it never
/// shifts: the pixel loader in `accent` while working and in `ink3` while
/// starting, an unread dot for a finish not yet seen, nothing when idle, and
/// an `ink3` dot once ended. Decorative; the row carries the words.
struct ActivityMark: View {
    let status: TabStatus
    var hasUnseenActivity = false

    var body: some View {
        Group {
            switch status {
            case .working: PixelLoader(color: Theme.accent)
            case .starting: PixelLoader(color: Theme.ink3)
            case .idle: if hasUnseenActivity { UnreadDot() } else { Color.clear }
            case .waitingForApproval: StatusDot(color: Theme.orange)
            case .failed: StatusDot(color: Theme.red)
            case .interrupted, .disconnected, .exited, .unknown: StatusDot(color: Theme.ink3)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

/// A label with a soft highlight band passing over it, 1.6s a pass, while a
/// turn is in flight. Reduce Motion shows the plain label.
struct ShimmerText: View {
    let text: String
    var step: Theme.TypeStep = .small

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let base = Text(text).font(Theme.font(step, weight: .medium)).foregroundStyle(Theme.ink2)
        if reduceMotion {
            base
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase =
                    context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.6) / 1.6
                base.overlay {
                    Text(text).font(Theme.font(step, weight: .medium)).foregroundStyle(Theme.ink)
                        .mask {
                            GeometryReader { geo in
                                let band = geo.size.width * 0.5
                                LinearGradient(
                                    colors: [.clear, .white, .clear],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .frame(width: band)
                                .offset(x: -band + (geo.size.width + band) * phase)
                            }
                        }
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

// MARK: - Helpers

extension Font.TextStyle {
    fileprivate var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
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
