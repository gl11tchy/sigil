import AppKit
import SigilKit
import SwiftUI

/// Hosts one tab's live terminal view. The view is owned by the controller and
/// stays alive across tab switches, so switching never restarts the process.
struct TerminalPane: NSViewRepresentable {
    /// Matches the sidebar's outer gutter, so both columns breathe the same.
    static let gutter: CGFloat = 8

    let controller: TerminalController
    /// Painted behind the terminal so the inset below blends into the window.
    let background: NSColor
    /// Rounds the screen to the frame it sits in. Zero leaves it square.
    var cornerRadius: CGFloat = 0

    init(tab: TerminalTab, background: NSColor, cornerRadius: CGFloat = 0) {
        self.init(controller: tab.controller, background: background, cornerRadius: cornerRadius)
    }

    init(controller: TerminalController, background: NSColor, cornerRadius: CGFloat = 0) {
        self.controller = controller
        self.background = background
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> NSView {
        let container = ContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = background.cgColor
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = cornerRadius > 0
        let terminal = controller.view
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        // The same gutter the sidebar uses, on all four sides. Glyphs should sit
        // off the divider and the window edge by the same amount the list does.
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.gutter),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.gutter),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.gutter),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.gutter),
        ])
        // SwiftTerm's scroller draws a pale track against a black ground. The
        // list on the left is the navigation surface; the terminal scrolls itself.
        for scroller in terminal.subviews.compactMap({ $0 as? NSScroller }) {
            scroller.isHidden = true
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = background.cgColor
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.masksToBounds = cornerRadius > 0
    }

    /// A plain container that keeps the terminal pinned to its bounds.
    final class ContainerView: NSView {
        override var acceptsFirstResponder: Bool { false }
    }
}
