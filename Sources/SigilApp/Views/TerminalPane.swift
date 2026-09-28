import AppKit
import SigilKit
import SwiftUI

/// Hosts one tab's live terminal view. The view is owned by the controller and
/// stays alive across tab switches, so switching never restarts the process.
struct TerminalPane: NSViewRepresentable {
    /// Matches the window inset, so glyphs sit off the screen's edge by the
    /// same step the screen sits off the window's.
    static let gutter: CGFloat = 10

    let controller: TerminalController
    /// Painted behind the terminal so the inset below blends into the window.
    let background: NSColor
    /// Rounds the screen to the frame it sits in. Zero leaves it square.
    var cornerRadius: CGFloat = 0
    /// False rounds only the bottom corners, for a pane under a tab bar.
    var roundsTopCorners = true
    var onWindowAttachment: (() -> Void)?

    init(
        tab: TerminalTab, background: NSColor, cornerRadius: CGFloat = 0,
        roundsTopCorners: Bool = true, onWindowAttachment: (() -> Void)? = nil
    ) {
        self.init(
            controller: tab.controller, background: background, cornerRadius: cornerRadius,
            roundsTopCorners: roundsTopCorners, onWindowAttachment: onWindowAttachment)
    }

    init(
        controller: TerminalController, background: NSColor, cornerRadius: CGFloat = 0,
        roundsTopCorners: Bool = true, onWindowAttachment: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.background = background
        self.cornerRadius = cornerRadius
        self.roundsTopCorners = roundsTopCorners
        self.onWindowAttachment = onWindowAttachment
    }

    /// Layer corners are in unflipped coordinates: `MinY` is the bottom edge.
    private var maskedCorners: CACornerMask {
        let bottom: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        return roundsTopCorners ? bottom.union([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) : bottom
    }

    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = background.cgColor
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.maskedCorners = maskedCorners
        container.layer?.masksToBounds = cornerRadius > 0
        container.pasteDroppedContent = { [weak controller] pasteboard in
            controller?.pasteDroppedContent(from: pasteboard) ?? false
        }
        container.onWindowAttachment = onWindowAttachment
        container.install(controller.view)
        return container
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        nsView.layer?.backgroundColor = background.cgColor
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.maskedCorners = maskedCorners
        nsView.layer?.masksToBounds = cornerRadius > 0
        nsView.pasteDroppedContent = { [weak controller] pasteboard in
            controller?.pasteDroppedContent(from: pasteboard) ?? false
        }
        nsView.onWindowAttachment = onWindowAttachment
        nsView.install(controller.view)
    }

    /// A plain container that keeps the terminal pinned to its bounds.
    final class ContainerView: NSView {
        override var acceptsFirstResponder: Bool { false }
        var pasteDroppedContent: ((NSPasteboard) -> Bool)?
        var onWindowAttachment: (() -> Void)?

        private(set) var hostedTerminal: NSView?
        private var terminalConstraints: [NSLayoutConstraint] = []

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes(TerminalDrop.pasteboardTypes)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerForDraggedTypes(TerminalDrop.pasteboardTypes)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onWindowAttachment?() }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            TerminalDrop.canAccept(sender.draggingPasteboard) ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            draggingEntered(sender)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            TerminalDrop.canAccept(sender.draggingPasteboard)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            pasteDroppedContent?(sender.draggingPasteboard) ?? false
        }

        func install(_ terminal: NSView) {
            guard hostedTerminal !== terminal else { return }
            NSLayoutConstraint.deactivate(terminalConstraints)
            hostedTerminal?.removeFromSuperview()
            hostedTerminal = terminal
            terminal.translatesAutoresizingMaskIntoConstraints = false
            addSubview(terminal)
            // The same gutter the sidebar uses, on all four sides. Glyphs should sit
            // off the divider and the window edge by the same amount the list does.
            terminalConstraints = [
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TerminalPane.gutter),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TerminalPane.gutter),
                terminal.topAnchor.constraint(equalTo: topAnchor, constant: TerminalPane.gutter),
                terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -TerminalPane.gutter),
            ]
            NSLayoutConstraint.activate(terminalConstraints)
            // SwiftTerm's scroller draws a pale track against a black ground. The
            // list on the left is the navigation surface; the terminal scrolls itself.
            for scroller in terminal.subviews.compactMap({ $0 as? NSScroller }) {
                scroller.isHidden = true
            }
            if window != nil { onWindowAttachment?() }
        }
    }
}
