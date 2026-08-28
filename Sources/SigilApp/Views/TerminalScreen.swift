import SigilKit
import SwiftUI

/// The frame the CLI is drawn inside.
///
/// The program in the tab draws its own interface, so the app's job here is a
/// surface, not decoration: one hairline rectangle with the same 10pt radius the
/// rest of the chrome uses, and a neon edge that appears only while the session
/// is working. Idle is a plain hairline; there is no glow to look at when there
/// is nothing happening.
struct TerminalScreen: View {
    let tab: TerminalTab

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    /// One radius for the screen. It matches the 6pt row radius stepped up for a
    /// container this large; anything rounder reads as a widget, not a display.
    static let radius: CGFloat = 10

    var body: some View {
        TerminalPane(tab: tab, background: palette.groundNSColor, cornerRadius: Self.radius)
            .background(
                RoundedRectangle(cornerRadius: Self.radius)
                    .fill(palette.ground)
                    // The glow is state: it says a turn is in flight, from across
                    // the desk, and it is absent every other moment.
                    .shadow(color: palette.accent.opacity(glowOpacity), radius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.radius)
                    .strokeBorder(edgeColor, lineWidth: 1)
            )
            .animation(
                isWorking && !reduceMotion
                    ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: isPulsing
            )
            .onAppear { isPulsing = isWorking && !reduceMotion }
            .onChange(of: isWorking) { _, working in isPulsing = working && !reduceMotion }
            // The same 8pt gutter the sidebar and the screen's own inset use, so
            // the frame sits off the window edge by one consistent step.
            .padding(8)
    }

    private var isWorking: Bool { tab.activity == .working }

    private var edgeColor: Color {
        guard isWorking else { return palette.hairline }
        return palette.accent.opacity(isPulsing ? 0.22 : 0.42)
    }

    private var glowOpacity: Double {
        guard isWorking else { return 0 }
        return isPulsing ? 0.10 : 0.22
    }
}
