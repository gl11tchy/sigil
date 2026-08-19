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
    private var escalationTask: Task<Void, Never>?
    private var reportsActivity = true
    private var didReportExit = false

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
        let pid = childPid.withLock { pid in
            let current = pid
            pid = 0
            return current
        }
        Self.signal(SIGTERM, to: pid)
        Self.signal(SIGKILL, to: pid)
    }

    /// Spawns `grok` with `spec`. Does nothing if already running.
    public func start(_ spec: GrokLaunchSpec) {
        if isRunning || terminalView.isProcessRunning { return }
        reportsActivity = true
        didReportExit = false
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

    /// Stops the child: SIGTERM first, then SIGKILL if it is still there.
    ///
    /// A single immediate signal is not enough. `forkpty` returns the child's pid
    /// before the child has run `setsid` and `exec`, and a signal delivered inside
    /// that window can be lost — leaving an orphaned `grok` behind. So the signal
    /// is repeated, then escalated.
    public func terminate() {
        reportsActivity = false
        activityFlushTask?.cancel()
        activityFlushTask = nil
        let pid = childPid.withLock { pid in
            let current = pid
            pid = 0
            return current
        }
        Self.signal(SIGTERM, to: pid)
        terminalView.terminateHosted()
        isRunning = false

        // Only replace a running escalation when there is a new child to chase;
        // a second terminate() must not cancel the first one's escalation.
        // Only replace a running escalation when there is a new child to chase;
        // a second terminate() must not cancel the first one's escalation.
        guard pid > 0 else { return }
        escalationTask?.cancel()
        escalationTask = Task { [weak self] in
            for delay in Self.escalationDelays {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                if Self.reap(pid) { self?.reportExitIfSilent(); return }
                Self.signal(SIGTERM, to: pid)
            }
            try? await Task.sleep(for: Self.killGrace)
            if Task.isCancelled { return }
            if Self.reap(pid) { self?.reportExitIfSilent(); return }
            Self.signal(SIGKILL, to: pid)
            try? await Task.sleep(for: Self.killGrace)
            _ = Self.reap(pid)
            self?.reportExitIfSilent()
        }
    }

    /// Stops the child without returning until it is gone. Used when the app is
    /// quitting, where there is no run loop left to finish an async escalation.
    public func terminateAndWait(timeout: Duration = .milliseconds(1500)) {
        let pid = childPid.withLock { pid in
            let current = pid
            pid = 0
            return current
        }
        reportsActivity = false
        activityFlushTask?.cancel()
        activityFlushTask = nil
        escalationTask?.cancel()
        escalationTask = nil
        Self.signal(SIGTERM, to: pid)
        terminalView.terminateHosted()
        isRunning = false
        guard pid > 0 else { return }

        let deadline = ContinuousClock.now + timeout
        let escalateAt = ContinuousClock.now + timeout / 2
        var escalated = false
        while ContinuousClock.now < deadline {
            if Self.reap(pid) { return }
            if !escalated, ContinuousClock.now >= escalateAt {
                Self.signal(SIGKILL, to: pid)
                escalated = true
            }
            usleep(20_000)
        }
        Self.signal(SIGKILL, to: pid)
        Self.reap(pid)
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

    // MARK: - Find

    private var search = ScrollbackSearch()

    /// Number of hits for the current find query.
    public var findMatchCount: Int { search.matchCount }

    /// One-based index of the current hit, or `0` when there are none.
    public var findMatchIndex: Int { search.current.map { $0 + 1 } ?? 0 }

    /// Sets a plain-text query and selects the first hit, if any.
    public func setFindQuery(_ query: String) {
        search.setQuery(query, in: findBufferLines())
        applyFindSelection()
    }

    /// Drops the query, the hits, and the selection used to show them.
    public func clearFind() {
        search.clear()
        terminalView.selectNone()
    }

    /// Advances to the next hit, wrapping to the first.
    public func findNext() {
        search.updateLines(findBufferLines())
        search.findNext()
        applyFindSelection()
    }

    /// Moves to the previous hit, wrapping to the last.
    public func findPrevious() {
        search.updateLines(findBufferLines())
        search.findPrevious()
        applyFindSelection()
    }

    /// One string per buffer row, using `bufferLine(atRow:)` so row indices
    /// match `SelectionService` / `scrollTo`.
    private func findBufferLines() -> [String] {
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        var row = 0
        while let line = terminal.bufferLine(atRow: row) {
            // Default translate emits one character per cell, so match columns
            // line up with `Position.col` without a separate width map.
            lines.append(line.translateToString(trimRight: true))
            row += 1
        }
        return lines
    }

    private func applyFindSelection() {
        guard let match = search.currentMatch else {
            terminalView.selectNone()
            return
        }
        let cols = terminalView.getTerminal().cols
        let start = Position(col: match.columns.lowerBound, row: match.line)
        // `setSelection` clamps `col` to `cols-1`. A hit that ends on the last
        // cell would lose that cell, so park the exclusive end on the next row.
        let end: Position
        if match.columns.upperBound >= cols {
            end = Position(col: 0, row: match.line + 1)
        } else {
            end = Position(col: match.columns.upperBound, row: match.line)
        }
        terminalView.selection.setSelection(start: start, end: end)
        revealFindMatch(row: match.line)
    }

    /// `scrollTo(row:)` sets `yDisp` (the top of the viewport), not the match.
    private func revealFindMatch(row: Int) {
        let terminal = terminalView.getTerminal()
        let viewport = terminal.rows
        guard viewport > 0 else { return }
        let top = terminal.buffer.yDisp
        let bottom = top + viewport - 1
        if row >= top && row <= bottom { return }
        terminalView.scrollTo(row: max(0, row - viewport / 2))
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

    private static let escalationDelays: [Duration] = [.milliseconds(100), .milliseconds(300)]
    private static let killGrace: Duration = .milliseconds(600)

    /// Signals the child and, when it leads its own process group, that whole
    /// group — so grandchildren the CLI spawned go too.
    ///
    /// The group is read with `getpgid` rather than assumed to equal the pid:
    /// between `forkpty` and the child's `setsid`, the child still sits in *our*
    /// group, and signalling that would kill the app itself.
    nonisolated private static func signal(_ sig: Int32, to pid: pid_t) {
        guard pid > 0 else { return }
        let group = getpgid(pid)
        if group > 0, group != getpgid(getpid()) {
            kill(-group, sig)
        }
        kill(pid, sig)
    }

    /// Whether the child is gone, reaping it if it is waiting to be collected.
    ///
    /// `kill(pid, 0)` cannot answer this: a child that has died but not been
    /// waited on is a zombie, and still answers "alive". Killing our own child
    /// without reaping it is exactly how an orphan-looking process survives a
    /// SIGKILL that in fact already worked.
    @discardableResult
    nonisolated private static func reap(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return true }
        // ECHILD: already collected, by SwiftTerm's own watcher or a earlier pass.
        if result < 0 && errno == ECHILD { return kill(pid, 0) != 0 }
        return false
    }

    nonisolated private static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    /// Reports an exit the terminal view never told us about, so a tab whose
    /// child had to be killed still leaves "running" state.
    private func reportExitIfSilent() {
        guard !didReportExit else { return }
        handleProcessExit(nil)
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
        guard !didReportExit else { return }
        didReportExit = true
        isRunning = false
        escalationTask?.cancel()
        escalationTask = nil
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
