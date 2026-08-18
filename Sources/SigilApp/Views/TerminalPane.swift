import AppKit
import SigilKit
import SwiftUI

/// Hosts one tab's live terminal view. The view is owned by the controller and
/// stays alive across tab switches, so switching never restarts the process.
struct TerminalPane: NSViewRepresentable {
    let tab: TerminalTab

    func makeNSView(context: Context) -> NSView {
        let container = ContainerView()
        let terminal = tab.controller.view
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// A plain container that keeps the terminal pinned to its bounds.
    final class ContainerView: NSView {
        override var acceptsFirstResponder: Bool { false }
    }
}
