import SigilKit
import SwiftUI

/// A button for a `WorkbenchAction`. An unavailable action shows disabled,
/// and its reason is the tooltip and what VoiceOver reads.
struct ActionButton: View {
    let title: String
    let action: WorkbenchAction
    var kind: SigilButtonStyle.Kind = .secondary
    var height: CGFloat = 28

    var body: some View {
        Button(title) {
            if case .run(let perform) = action { perform() }
        }
        .buttonStyle(SigilButtonStyle(kind: kind, height: height))
        .disabled(action.reason != nil)
        .help(action.reason ?? title)
        .accessibilityHint(action.reason ?? "")
    }
}

/// The icon form of `ActionButton`, for headers and rows.
struct ActionIconButton: View {
    let systemImage: String
    let help: String
    let action: WorkbenchAction

    var body: some View {
        IconButton(systemImage: systemImage, help: action.reason.map { "\(help): \($0)" } ?? help, label: help) {
            if case .run(let perform) = action { perform() }
        }
        .disabled(action.reason != nil)
    }
}

/// A task's mark in the rail and the header: the lifecycle mark while a
/// process runs, a red ring when the task cannot run, nothing when it is
/// known only from history.
struct TaskMark: View {
    let task: WorkbenchTask
    @Environment(\.palette) private var palette

    var body: some View {
        switch task.process {
        case .live(let state):
            ActivityMark(activity: state, hasUnseenActivity: task.hasUnseenFinish)
        case .notRunning:
            Color.clear
                .frame(width: 10, height: 10)
                .accessibilityElement()
                .accessibilityLabel("Not running")
        case .providerUnavailable, .workspaceMissing:
            Circle()
                .strokeBorder(palette.red, lineWidth: 1.5)
                .frame(width: 7, height: 7)
                .frame(width: 10, height: 10)
                .accessibilityElement()
                .accessibilityLabel("Blocked")
        }
    }
}

/// The state words for a task, as the header and VoiceOver say them.
enum TaskStateText {
    static func label(_ task: WorkbenchTask) -> String {
        switch task.process {
        case .notRunning: return "Not running"
        case .providerUnavailable: return "\(task.provider.name) unavailable"
        case .workspaceMissing: return "Folder missing"
        case .live(let state):
            switch state {
            case .starting: return "Starting"
            case .working: return "Working"
            case .idle: return task.hasUnseenFinish ? "Finished" : "Idle"
            case .waitingForApproval: return "Needs input"
            case .interrupted: return "Stopped"
            case .failed: return "Failed"
            case .disconnected: return "Disconnected"
            case .unknown: return "Status unknown"
            case .exited(let code):
                guard let code, code != 0 else { return "Ended" }
                return "Exited with code \(code)"
            }
        }
    }

    static func tone(_ task: WorkbenchTask) -> StatusPill.Tone {
        switch task.attention {
        case .finished: return .accent
        case .needsInput, .stopped: return .orange
        case .failed, .blocked: return .red
        case .none: return .neutral
        }
    }
}
