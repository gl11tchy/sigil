import AppKit
import SigilKit

/// The question asked before a close, archive or quit stops sessions that are
/// still running. Its words follow the action, the number of sessions, and
/// whether they are mid-turn or only running. Quit and a shell restart also
/// name a command still running in the panel terminal.
struct StopWorkingPrompt: Equatable {
    enum Action: Equatable {
        case closeTab
        case archive
        case quit
        case restartShell
    }

    let action: Action
    /// Tabs the action stops mid-turn.
    let working: Int
    /// Providers of the other tabs it stops: their CLI runs but shows no turn.
    let running: [CLIProvider]
    /// A command holds the panel terminal. Only quit and a shell restart stop it.
    let panelJob: Bool

    var count: Int { working + running.count }

    /// Nil when the action stops none of `tabs` and no panel command.
    @MainActor
    init?(action: Action, stopping tabs: [TerminalTab], panelJob: Bool = false) {
        let stopping = tabs.filter(\.shouldWarnBeforeStopping)
        guard !stopping.isEmpty || panelJob else { return nil }
        let running = stopping.filter { $0.spec.provider != .grokBuild && $0.activity != .working }
        self.init(
            action: action, working: stopping.count - running.count,
            running: running.map(\.spec.provider), panelJob: panelJob)
    }

    init(action: Action, working: Int, running: [CLIProvider], panelJob: Bool = false) {
        self.action = action
        self.working = working
        self.running = running
        self.panelJob = panelJob
    }

    var messageText: String {
        let subject: String
        if count == 0 {
            subject = "A command is still running in the panel terminal."
        } else if count > 1 {
            subject = "\(count) sessions are"
        } else if let provider = running.first {
            subject = "\(provider.name) is"
        } else {
            subject = action == .closeTab ? "This session is" : "A session is"
        }
        let statement =
            count == 0 ? subject : "\(subject) still \(running.isEmpty ? "working" : "running")."
        switch action {
        case .closeTab: return statement
        case .archive: return "\(statement) Archive anyway?"
        case .quit: return "\(statement) Quit anyway?"
        case .restartShell: return "\(statement) Restart anyway?"
        }
    }

    var informativeText: String {
        guard panelJob else { return sessionsInformativeText }
        if count == 0 { return "The command will stop." }
        return "\(sessionsInformativeText) The command in the panel terminal will stop too."
    }

    private var sessionsInformativeText: String {
        switch (working, running.first) {
        case (0, let provider?) where count == 1: return "\(provider.name) will stop."
        case (0, _): return "Their processes will stop."
        case (1, _): return "The response in progress will stop."
        default: return "The responses in progress will stop."
        }
    }

    var buttonTitle: String {
        switch action {
        case .closeTab: return "Close Tab"
        case .archive: return "Archive"
        case .quit: return "Quit"
        case .restartShell: return "Restart Shell"
        }
    }

    /// Shows the alert and returns true when the user chose to stop the sessions.
    @MainActor
    func runModal() -> Bool {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: buttonTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
