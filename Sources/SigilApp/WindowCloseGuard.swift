import AppKit
import SwiftUI

/// Asks before the window closes while a session is working.
///
/// Closing the only window quits Sigil. Without this, the quit confirmation
/// appears only after the window is gone, and Cancel leaves the app running
/// with no window. The close button, and `performClose`, which clicks it, go to
/// the quit path instead, so the existing confirmation shows over the window.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldConfirm: @MainActor () -> Bool

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.shouldConfirm = shouldConfirm
        return view
    }

    func updateNSView(_ nsView: GuardView, context: Context) {
        nsView.shouldConfirm = shouldConfirm
        nsView.attach()
    }

    final class GuardView: NSView {
        var shouldConfirm: @MainActor () -> Bool = { false }
        var quit: @MainActor () -> Void = { NSApp.terminate(nil) }

        private weak var originalTarget: AnyObject?
        private var originalAction: Selector?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard let button = window?.standardWindowButton(.closeButton),
                button.target !== self
            else { return }
            originalTarget = button.target
            originalAction = button.action
            button.target = self
            button.action = #selector(closeClicked(_:))
        }

        @objc private func closeClicked(_ sender: Any?) {
            if shouldConfirm() {
                quit()
                return
            }
            guard let originalAction else {
                window?.close()
                return
            }
            NSApp.sendAction(originalAction, to: originalTarget, from: sender)
        }
    }
}
