import AppKit

/// Where keyboard focus sits in the main window, as far as hiding a column
/// is concerned.
enum KeyboardFocus: Equatable {
    /// The selected session's terminal.
    case sessionTerminal
    /// The right panel: its shell, or the notes editor.
    case panel
    /// Nothing, or only the window itself.
    case lost
    /// Anything else, such as the sidebar list or a search field.
    case elsewhere

    /// A column the user can hide.
    enum Column {
        case sidebar
        case panel
    }

    @MainActor
    static func classify(
        _ responder: NSResponder?,
        in window: NSWindow?,
        sessionView: NSView?,
        panelShellView: NSView?
    ) -> KeyboardFocus {
        guard let responder, responder !== window, responder !== window?.contentView else {
            return .lost
        }
        guard let view = responder as? NSView else { return .elsewhere }
        if let sessionView, view.isDescendant(of: sessionView) { return .sessionTerminal }
        if let panelShellView, view.isDescendant(of: panelShellView) { return .panel }
        // The notes editor is the one text view in the window that is not a
        // field editor. Search, rename and find fields all edit through one.
        if let text = view as? NSTextView, !text.isFieldEditor { return .panel }
        return .elsewhere
    }

    /// Hiding a column hands focus back to the session terminal when focus
    /// was in that column, or nowhere at all.
    func needsTerminalAfterHiding(_ column: Column) -> Bool {
        switch (self, column) {
        case (.lost, _), (.elsewhere, .sidebar), (.panel, .panel): return true
        default: return false
        }
    }
}
