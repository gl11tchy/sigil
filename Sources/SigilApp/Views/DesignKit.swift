import SigilKit
import SwiftUI

// Beautiful UI's primitives, once. Every surface in the app builds from these
// so a button, a card, or a working mark reads the same everywhere.

// MARK: - Surfaces

/// How far a card sits above what is under it. Each step is Beautiful UI's
/// ring plus its shadow; the ring is the border, never a second one.
enum Elevation {
    case flat, card, raised, overlay
}

extension View {
    /// A filled rounded rectangle with the ring and shadow for `elevation`.
    func surface(
        _ fill: Color, radius: CGFloat = Radius.card, elevation: Elevation = .card
    ) -> some View {
        modifier(SurfaceModifier(fill: fill, radius: radius, elevation: elevation))
    }
}

private struct SurfaceModifier: ViewModifier {
    let fill: Color
    let radius: CGFloat
    let elevation: Elevation
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(fill).shadow(color: shadowColor, radius: blur, y: offset))
            .overlay(shape.strokeBorder(ring, lineWidth: 1))
    }

    private var ring: Color {
        switch elevation {
        case .flat: return palette.line
        case .card: return palette.ring
        case .raised: return palette.ringRaised
        case .overlay: return palette.ringOverlay
        }
    }

    private var shadowColor: Color {
        switch elevation {
        case .flat: return .clear
        case .card: return .black.opacity(palette.isDark ? 0.20 : 0.04)
        case .raised: return .black.opacity(palette.isDark ? 0.22 : 0.06)
        case .overlay: return .black.opacity(palette.isDark ? 0.34 : 0.10)
        }
    }

    private var blur: CGFloat {
        switch elevation {
        case .flat: return 0
        case .card: return 3
        case .raised: return 5
        case .overlay: return 14
        }
    }

    private var offset: CGFloat {
        switch elevation {
        case .flat: return 0
        case .card: return 1
        case .raised: return 2
        case .overlay: return 8
        }
    }
}

// MARK: - Buttons

/// Beautiful UI's buttons: primary is the accent, secondary is `hover2`, ghost
/// is text until hovered, destructive is red on its tint.
struct SigilButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    var kind: Kind = .secondary
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, height: height)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.palette) private var palette
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .ui(13, .medium)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(minHeight: height)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(fill)
                )
                .overlay {
                    if kind == .secondary || kind == .primary {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(kind == .primary ? .white.opacity(0.10) : palette.ringButton, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Motion.fade, value: isHovering)
                .animation(Motion.fade, value: configuration.isPressed)
                .onHover { isHovering = $0 && isEnabled }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return .white
            case .secondary: return palette.ink
            case .ghost: return isHovering ? palette.ink : palette.ink2
            case .destructive: return palette.redInk
            }
        }

        private var fill: Color {
            let lift = isHovering || configuration.isPressed
            switch kind {
            case .primary:
                return lift ? palette.accentFill.blended(with: .white, 0.04) : palette.accentFill
            case .secondary:
                return lift ? palette.hover2.blended(with: palette.ink, 0.05) : palette.hover2
            case .ghost:
                return lift ? palette.hover : .clear
            case .destructive:
                return lift ? palette.red.opacity(palette.isDark ? 0.22 : 0.12) : palette.redTint
            }
        }
    }
}

extension ButtonStyle where Self == SigilButtonStyle {
    static var primary: SigilButtonStyle { SigilButtonStyle(kind: .primary) }
    static var secondary: SigilButtonStyle { SigilButtonStyle(kind: .secondary) }
    static var ghost: SigilButtonStyle { SigilButtonStyle(kind: .ghost) }
    static var destructive: SigilButtonStyle { SigilButtonStyle(kind: .destructive) }
}

extension Color {
    /// Linear sRGB mix, for hover lifts that stay inside the token's hue.
    func blended(with other: Color, _ amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        func lerp(_ x: CGFloat, _ y: CGFloat) -> Double { Double(x + (y - x) * amount) }
        return Color(
            .sRGB,
            red: lerp(a.redComponent, b.redComponent),
            green: lerp(a.greenComponent, b.greenComponent),
            blue: lerp(a.blueComponent, b.blueComponent),
            opacity: Double(a.alphaComponent)
        )
    }
}

/// A 24pt square icon control. Every icon button in the chrome is one of these.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var isOn: Bool = false
    var size: CGFloat = 24
    let action: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(isHovering || isOn ? palette.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(Motion.fade, value: isHovering)
        .onHover { isHovering = $0 && isEnabled }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var foreground: Color {
        if isOn { return palette.accent }
        return isHovering ? palette.ink : palette.ink3
    }
}

// MARK: - Key caps

/// A keyboard shortcut as a small key cap. The app is keyboard-first, so hints
/// name the key instead of burying it in a sentence.
struct KbdChip: View {
    let label: String
    let palette: Palette

    var body: some View {
        Text(label)
            .mono(10.5, .medium)
            .foregroundStyle(palette.ink2)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip - 2, style: .continuous)
                    .fill(palette.hover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip - 2, style: .continuous)
                    .strokeBorder(palette.lineStrong, lineWidth: 1)
            )
            .accessibilityLabel(label)
    }
}

// MARK: - Segmented control

/// Beautiful UI's pill segmented control: an `inset` track and a `surface`
/// thumb that slides to the chosen segment.
struct SegmentedPill<Value: Hashable & Identifiable>: View {
    let items: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var systemImage: ((Value) -> String)? = nil
    var showsTitle: (Value) -> Bool = { _ in true }

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isSelected = item == selection
                Button {
                    withAnimation(reduceMotion ? nil : Motion.slide) { selection = item }
                } label: {
                    HStack(spacing: 5) {
                        if let systemImage {
                            Image(systemName: systemImage(item))
                                .font(.system(size: 11, weight: .medium))
                        }
                        if showsTitle(item) {
                            Text(title(item)).ui(12.5, .medium)
                        }
                    }
                    .foregroundStyle(isSelected ? palette.ink : palette.ink2)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(palette.isDark ? palette.hover2 : palette.surface)
                                .overlay(Capsule(style: .continuous).strokeBorder(palette.ringButton, lineWidth: 1))
                                .shadow(color: .black.opacity(palette.isDark ? 0.3 : 0.06), radius: 1, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(title(item))
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(palette.isDark ? palette.page : palette.hover2.opacity(0.6)))
        .overlay(Capsule(style: .continuous).strokeBorder(palette.lineSoft, lineWidth: 1))
    }
}

// MARK: - State marks

/// Beautiful UI's pixel-grid loader: a 3×3 grid with a highlight that travels
/// around the ring. Reduced motion holds a steady grid with the centre lit.
struct PixelLoader: View {
    var color: Color
    var cell: CGFloat = 2.5
    var gap: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ring order, clockwise from the top-left cell.
    private static let ring = [0, 1, 2, 5, 8, 7, 6, 3]
    private static let period = 0.96

    var body: some View {
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

/// The per-session state mark: a pixel loader while working or starting, an
/// accent dot for an unread finish, a dot for an ended session, and an empty
/// slot when idle, so text beside it never shifts.
struct ActivityMark: View {
    let activity: TerminalTab.Activity
    var hasUnseenActivity: Bool = false

    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch activity {
            case .working:
                PixelLoader(color: palette.accent)
            case .starting:
                PixelLoader(color: palette.ink3)
            case .idle:
                if hasUnseenActivity { dot(palette.accent) } else { Color.clear }
            case .exited:
                dot(activity.endedInFailure ? palette.red : palette.ink3)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }

    private var label: String {
        switch activity {
        case .working: return "Working"
        case .idle: return hasUnseenActivity ? "Finished" : "Idle"
        case .starting: return "Starting"
        case .exited(let code): return "Exited with code \(code.map(String.init) ?? "unknown")"
        }
    }
}

/// A label with a soft highlight band passing over it, for work in flight.
/// Reduced motion shows the plain label.
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 12.5

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let base = Text(text).ui(size, .medium).foregroundStyle(palette.ink2)
        if reduceMotion {
            base
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase =
                    context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.6) / 1.6
                base.overlay {
                    Text(text).ui(size, .medium).foregroundStyle(palette.ink)
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
                }
            }
        }
    }
}

/// Beautiful UI's status pill: short text on its colour's tint.
struct StatusPill: View {
    enum Tone { case neutral, accent, green, orange, red }
    let text: String
    var tone: Tone = .neutral
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .ui(11.5, .medium)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(fill))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return palette.ink2
        case .accent: return palette.accentInk
        case .green: return palette.greenInk
        case .orange: return palette.orangeInk
        case .red: return palette.redInk
        }
    }

    private var fill: Color {
        switch tone {
        case .neutral: return palette.hover2
        case .accent: return palette.accentTint
        case .green: return palette.greenTint
        case .orange: return palette.orangeTint
        case .red: return palette.redTint
        }
    }
}

// MARK: - Field

/// Beautiful UI's text field frame: `field` fill, control radius, an accent
/// ring while focused.
struct FieldFrame<Content: View>: View {
    var isFocused: Bool
    var height: CGFloat = 32
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(palette.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(isFocused ? palette.accent : palette.ring, lineWidth: 1)
            )
            .animation(Motion.fade, value: isFocused)
    }
}
