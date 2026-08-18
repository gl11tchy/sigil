import AppKit
import Darwin
import Foundation
import os
import SwiftTerm

/// Owns one `grok` child process and the view that renders it.
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

    private let terminalView: GrokProcessTerminalView
    private let childPid = OSAllocatedUnfairLock(initialState: pid_t(0))
    private var lastActivityFire: ContinuousClock.Instant?
    private var activityFlushTask: Task<Void, Never>?
    private var reportsActivity = true

    public init(theme: TerminalTheme = .grokNight, fontSize: CGFloat = 13) {
        let terminal = GrokProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            font: Self.monospacedFont(size: Self.clampedFontSize(fontSize)),
            options: TerminalOptions.default
        )
        self.terminalView = terminal
        self.view = terminal
        terminal.processDelegate = self
        terminal.onChildOutput = { [weak self] in
            self?.noteActivity()
        }
        apply(theme: theme)
    }

    deinit {
        Self.signalProcessGroup(pid: childPid.withLock { pid in
            let current = pid
            pid = 0
            return current
        })
    }

    /// Spawns `grok` with `spec`. Does nothing if already running.
    public func start(_ spec: GrokLaunchSpec) {
        if isRunning || terminalView.isProcessRunning { return }
        reportsActivity = true
        lastActivityFire = nil
        activityFlushTask?.cancel()
        activityFlushTask = nil

        let environment = spec.environment().map { "\($0.key)=\($0.value)" }
        terminalView.startHosted(
            executable: spec.executable.path,
            args: spec.arguments(),
            environment: environment,
            currentDirectory: spec.workingDirectory.path
        )
        isRunning = terminalView.isProcessRunning
        let pid = terminalView.hostedPid
        childPid.withLock { $0 = pid }
    }

    /// Sends SIGTERM to the child and stops rendering.
    public func terminate() {
        reportsActivity = false
        activityFlushTask?.cancel()
        activityFlushTask = nil
        let pid = childPid.withLock { pid in
            let current = pid
            pid = 0
            return current
        }
        Self.signalProcessGroup(pid: pid)
        terminalView.terminateHosted()
        isRunning = false
    }

    /// Writes `text` to the child's stdin, as if typed.
    public func send(text: String) {
        terminalView.send(txt: text)
    }

    public func apply(theme: TerminalTheme) {
        terminalView.installColors(theme.ansi)
        terminalView.nativeBackgroundColor = Self.nsColor(theme.background)
        terminalView.nativeForegroundColor = Self.nsColor(theme.foreground)
        terminalView.caretColor = Self.nsColor(theme.cursor)
        terminalView.selectedTextBackgroundColor = Self.nsColor(theme.selection)
    }

    public func setFontSize(_ size: CGFloat) {
        terminalView.font = Self.monospacedFont(size: Self.clampedFontSize(size))
    }

    /// Copies the current selection, returning false when nothing is selected.
    @discardableResult
    public func copySelection() -> Bool {
        guard terminalView.selectionActive,
              let text = terminalView.getSelection(),
              !text.isEmpty
        else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    public func paste() {
        terminalView.paste(self)
    }

    public func selectAll() {
        terminalView.selectAll()
    }

    /// Moves keyboard focus into the terminal.
    public func focus() {
        view.window?.makeFirstResponder(view)
    }

    var processID: pid_t { terminalView.hostedPid }

    func bufferText() -> String {
        String(data: terminalView.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
    }
}

extension TerminalController {
    private static let minFontSize: CGFloat = 8
    private static let maxFontSize: CGFloat = 32
    private static let activityInterval: Duration = .milliseconds(200)

    private static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, minFontSize), maxFontSize)
    }

    private static func monospacedFont(size: CGFloat) -> NSFont {
        if let font = NSFont(name: "SF Mono", size: size) { return font }
        if let font = NSFont(name: "SFMono-Regular", size: size) { return font }
        if let font = NSFont(name: "Menlo", size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func nsColor(_ color: SwiftTerm.Color) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 65535.0,
            green: CGFloat(color.green) / 65535.0,
            blue: CGFloat(color.blue) / 65535.0,
            alpha: 1
        )
    }

    /// SIGTERM the child's process group when it is a group leader, then the pid.
    /// `forkpty`/`login_tty` makes the child a session leader, so grandchildren
    /// (e.g. `sh -c 'sleep 30'`) share that group.
    nonisolated private static func signalProcessGroup(pid: pid_t) {
        guard pid > 0 else { return }
        if getpgid(pid) == pid {
            kill(-pid, SIGTERM)
        }
        kill(pid, SIGTERM)
    }

    private func noteActivity() {
        guard reportsActivity else { return }
        let now = ContinuousClock.now
        if let last = lastActivityFire, now - last < Self.activityInterval {
            if activityFlushTask == nil {
                let wait = Self.activityInterval - (now - last)
                activityFlushTask = Task { [weak self] in
                    try? await Task.sleep(for: wait)
                    guard let self, !Task.isCancelled else { return }
                    self.activityFlushTask = nil
                    self.fireActivity()
                }
            }
            return
        }
        fireActivity()
    }

    private func fireActivity() {
        guard reportsActivity else { return }
        lastActivityFire = .now
        onActivity?()
    }

    private func handleProcessExit(_ rawStatus: Int32?) {
        isRunning = false
        childPid.withLock { $0 = 0 }
        reportsActivity = false
        activityFlushTask?.cancel()
        activityFlushTask = nil
        onTerminate?(Self.decodeExitStatus(rawStatus))
    }

    private static func decodeExitStatus(_ raw: Int32?) -> Int32? {
        guard let raw else { return nil }
        let status = raw & 0x7f
        if status == 0 { return (raw >> 8) & 0xff }
        if status != 0x7f { return 128 + status }
        return raw
    }
}

extension TerminalController: LocalProcessTerminalViewDelegate {
    public nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    public nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.onTitleChange?(title)
        }
    }

    public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.handleProcessExit(exitCode)
        }
    }
}
