import SwiftUI

/// The per-tab state light: working, idle, or exited.
struct StatusDot: View {
    let activity: TerminalTab.Activity

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background {
                if isWorking {
                    // A working session must read from across the desk; the 6pt
                    // dot alone does not carry that. The halo is state, not trim.
                    Circle()
                        .fill(palette.accent.opacity(isWorking && pulse ? 0.05 : 0.18))
                        .frame(width: 12, height: 12)
                }
            }
            .opacity(isWorking && pulse ? 0.45 : 1)
            .animation(
                isWorking && !reduceMotion
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = isWorking && !reduceMotion }
            .onChange(of: isWorking) { _, working in pulse = working && !reduceMotion }
            .accessibilityLabel(label)
    }

    private var isWorking: Bool { activity == .working }

    private var color: Color {
        switch activity {
        case .working: return palette.accent
        case .idle, .starting: return palette.textFaint
        case .exited: return activity.endedInFailure ? .red : palette.textFaint.opacity(0.5)
        }
    }

    private var label: String {
        switch activity {
        case .working: return "Working"
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .exited(let code): return "Exited with code \(code.map(String.init) ?? "unknown")"
        }
    }
}
