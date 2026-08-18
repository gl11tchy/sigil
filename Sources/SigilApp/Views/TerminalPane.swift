import AppKit
import SigilKit
import SwiftUI

/// Hosts one tab's live terminal view. The view is owned by the controller and
/// stays alive across tab switches, so switching never restarts the process.
struct TerminalPane: NSViewRepresentable {
    let tab: TerminalTab
    /// Painted behind the terminal so the inset below blends into the window.
    let background: NSColor

    func makeNSView(context: Context) -> NSView {
        let container = ContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = background.cgColor
        let terminal = tab.controller.view
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        // Glyphs should not touch the divider or the window edge.
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = background.cgColor
    }

    /// A plain container that keeps the terminal pinned to its bounds.
    final class ContainerView: NSView {
        override var acceptsFirstResponder: Bool { false }
    }
}
