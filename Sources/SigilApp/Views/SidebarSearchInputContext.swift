import AppKit
import SwiftUI

/// Reads the native editor at key dispatch without caching its composition state
/// or consulting another window's first responder.
@MainActor
final class SidebarSearchInputContext {
    private weak var anchor: NSView?

    func attach(_ view: NSView) {
        anchor = view
    }

    func detach(_ view: NSView) {
        if anchor === view { anchor = nil }
    }

    var hasMarkedText: Bool {
        (anchor?.window?.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true
    }

    func canNavigate(modifiers: EventModifiers, isRenaming: Bool) -> Bool {
        Self.allowsNavigation(
            modifiers: modifiers, isRenaming: isRenaming, responder: anchor?.window?.firstResponder)
    }

    static func allowsNavigation(modifiers: EventModifiers, isRenaming: Bool, responder: NSResponder?) -> Bool {
        guard !isRenaming, modifiers.intersection([.shift, .control, .option, .command]).isEmpty,
            let input = responder as? any NSTextInputClient
        else { return false }
        return !input.hasMarkedText()
    }
}

/// A hidden per-field anchor. SwiftUI still owns the TextField, value and focus;
/// this bridge only identifies its live AppKit window and editor.
struct SidebarSearchInputAnchor: NSViewRepresentable {
    let input: SidebarSearchInputContext

    func makeCoordinator() -> SidebarSearchInputContext { input }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        input.attach(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        input.attach(nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: SidebarSearchInputContext) {
        coordinator.detach(nsView)
    }
}
