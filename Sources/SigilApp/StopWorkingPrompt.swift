import AppKit

/// The question asked before a close or archive stops sessions that are still
/// working. Its words follow the action and the number of sessions.
struct StopWorkingPrompt: Equatable {
    enum Action: Equatable {
        case closeTab
        case archive
    }

    let action: Action
    /// How many of the tabs the action closes are still working.
    let count: Int

    /// Nil when none of `tabs` would be stopped mid-turn.
    @MainActor
    init?(action: Action, stopping tabs: [TerminalTab]) {
        let count = tabs.filter(\.shouldWarnBeforeStopping).count
        guard count > 0 else { return nil }
        self.init(action: action, count: count)
    }

    init(action: Action, count: Int) {
        self.action = action
        self.count = count
    }

    var messageText: String {
        switch action {
        case .closeTab:
            return "This session is still working."
        case .archive:
            let subject = count == 1 ? "A session is" : "\(count) sessions are"
            return "\(subject) still working. Archive anyway?"
        }
    }

    var informativeText: String {
        count == 1
            ? "The response in progress will stop."
            : "The responses in progress will stop."
    }

    var buttonTitle: String {
        switch action {
        case .closeTab: return "Close Tab"
        case .archive: return "Archive"
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
