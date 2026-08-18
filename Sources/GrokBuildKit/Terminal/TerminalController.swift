import AppKit
import Foundation
import SwiftTerm

/// Owns one `grok` child process and the view that renders it.
///
/// IMPLEMENTATION PENDING — this file declares the API the app is written against.
@MainActor
public final class TerminalController {

    /// The view to embed in SwiftUI.
    public let view: NSView

    /// False once the child process exits.
    public private(set) var isRunning: Bool = false

    /// Called when the child exits, with its exit code when one is available.
    public var onTerminate: ((Int32?) -> Void)?
    /// Called when the child writes output, coalesced to at most once per ~200 ms.
    public var onActivity: (() -> Void)?
    /// Called when the child sets the terminal title (the CLI reports its state here).
    public var onTitleChange: ((String) -> Void)?

    public init(theme: TerminalTheme = .grokNight, fontSize: CGFloat = 13) {
        self.view = NSView()
    }

    /// Spawns `grok` with `spec`. Does nothing if already running.
    public func start(_ spec: GrokLaunchSpec) {}

    /// Sends SIGTERM to the child and stops rendering.
    public func terminate() {}

    /// Writes `text` to the child's stdin, as if typed.
    public func send(text: String) {}

    public func apply(theme: TerminalTheme) {}
    public func setFontSize(_ size: CGFloat) {}

    /// Copies the current selection, returning false when nothing is selected.
    @discardableResult
    public func copySelection() -> Bool { false }
    public func paste() {}
    public func selectAll() {}

    /// Moves keyboard focus into the terminal.
    public func focus() {}
}
