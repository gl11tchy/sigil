import SwiftUI

/// The per-tab state light: working, idle, or exited.
struct StatusDot: View {
    let activity: TerminalTab.Activity
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(isWorking && pulse ? 0.35 : 1)
            .animation(
                isWorking
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = isWorking }
            .onChange(of: isWorking) { _, working in pulse = working }
            .accessibilityLabel(label)
    }

    private var isWorking: Bool { activity == .working }

    private var color: Color {
        switch activity {
        case .working: return .green
        case .idle, .starting: return .secondary.opacity(0.5)
        case let .exited(code): return (code ?? 1) == 0 ? .secondary.opacity(0.3) : .red
        }
    }

    private var label: String {
        switch activity {
        case .working: return "Working"
        case .idle: return "Idle"
        case .starting: return "Starting"
        case let .exited(code): return "Exited with code \(code.map(String.init) ?? "unknown")"
        }
    }
}
