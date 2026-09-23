import AppKit
import Darwin
import Foundation
import SwiftTerm
import os

/// Owns one CLI child process and the view that renders it.
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
    /// Called when the user submits a prompt with Return or a multiline paste.
    public var onUserSubmit: (() -> Void)?
    /// Called when the child sets the terminal title (the CLI reports its state here).
    public var onTitleChange: ((String) -> Void)?

    private let terminalView: GrokProcessTerminalView
    private let childPid = OSAllocatedUnfairLock(initialState: pid_t(0))
    private var lastActivityFire: ContinuousClock.Instant?
    private var activityFlushTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?
    private var reportsActivity = true
    private var didReportExit = false

    /// Off by default, as in Terminal.app, so Option types the layout's characters.
    public var optionAsMetaKey: Bool {
        get { terminalView.optionAsMetaKey }
        set { terminalView.optionAsMetaKey = newValue }
    }

    public init(theme: TerminalTheme = .grokNight, fontSize: CGFloat = 13) {
        var options = TerminalOptions.default
        options.scrollback = 10_000
        options.screenReaderMode = true
        let terminal = GrokProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            font: Self.monospacedFont(size: Self.clampedFontSize(fontSize)),
            options: options
        )
        self.terminalView = terminal
        self.view = terminal
        terminal.optionAsMetaKey = false
        terminal.processDelegate = self
        terminal.onChildOutput = { [weak self] in
            self?.noteActivity()
        }
        terminal.onUserSubmit = { [weak self] in
            self?.onUserSubmit?()
        }
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityRole(.textArea)
        terminal.setAccessibilityLabel("Grok terminal")
        terminal.accessibilityText = { [weak self] in self?.accessibilitySnapshot() ?? "" }
        apply(theme: theme)
    }

    deinit {
        let pid = childPid.withLock { pid in
            let current = pid
            pid = 0
            return current
        }
        if !Self.reap(pid) {
            Self.signal(SIGTERM, to: pid)
            Self.signal(SIGKILL, to: pid)
        }
    }

    /// Spawns the selected CLI with `spec`. Does nothing if already running.
    public func start(_ spec: GrokLaunchSpec) {
        if isRunning || terminalView.isProcessRunning { return }
        terminalView.setAccessibilityLabel("\(spec.provider.name) terminal")
        reportsActivity = true
        didReportExit = false
        lastActivityFire = nil
        activityFlushTask?.cancel()
        activityFlushTask = nil

        let environment = spec.environment().map { "\($0.key)=\($0.value)" }
        let command = spec.hostCommand()
        terminalView.startHosted(
            executable: command.executable.path,
            args: command.arguments,
            environment: environment,
            currentDirectory: spec.workingDirectory.path
        )
        isRunning = terminalView.isProcessRunning
        let pid = terminalView.hostedPid
        childPid.withLock { $0 = pid }
    }

    /// Spawns a plain login shell with `spec`. Does nothing if already running.
    public func startShell(_ spec: ShellLaunchSpec) {
        if isRunning || terminalView.isProcessRunning { return }
        reportsActivity = true
        didReportExit = false
        lastActivityFire = nil
        activityFlushTask?.cancel()
        activityFlushTask = nil

        let environment = spec.environment().map { "\($0.key)=\($0.value)" }
        let command = spec.hostCommand()
        terminalView.startHosted(
            executable: command.executable.path,
            args: command.arguments,
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
        let pid = childPid.withLock { $0 }
        guard escalationTask == nil else { return }
        guard pid > 0 else {
            isRunning = false
            return
        }
        if Self.reap(pid) {
            isRunning = false
            reportExitIfSilent()
            return
        }
        Self.signal(SIGTERM, to: pid)
        terminalView.terminateHosted()
        isRunning = false

        escalationTask = Task { [weak self] in
            for delay in Self.escalationDelays {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                if Self.reap(pid) {
                    self?.reportExitIfSilent()
                    self?.escalationTask = nil
                    return
                }
                Self.signal(SIGTERM, to: pid)
            }
            try? await Task.sleep(for: Self.killGrace)
            if Task.isCancelled { return }
            if Self.reap(pid) {
                self?.reportExitIfSilent()
                self?.escalationTask = nil
                return
            }
            Self.signal(SIGKILL, to: pid)
            try? await Task.sleep(for: Self.killGrace)
            _ = Self.reap(pid)
            self?.reportExitIfSilent()
            self?.escalationTask = nil
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
        guard pid > 0 else {
            isRunning = false
            return
        }
        defer { reportExitIfSilent() }
        if Self.reap(pid) {
            isRunning = false
            reportExitIfSilent()
            return
        }
        Self.signal(SIGTERM, to: pid)
        terminalView.terminateHosted()
        isRunning = false
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

    /// Bounded readable output for an explicitly paired remote controller.
    public func remoteSnapshot() -> String { accessibilitySnapshot(maxCharacters: 12_000) }

    /// The tail of the terminal for a crash report. Shorter than the remote
    /// snapshot: the report has to stay readable, not be complete.
    public func crashSnapshot() -> String { accessibilitySnapshot(maxCharacters: 4_000) }

    /// Readable text immediately before the phone's already loaded window.
    /// One slice is at most 12_000 characters. This does not widen `remoteSnapshot`.
    public func remoteEarlierSlice(
        before startAnchor: String,
        endAnchor: String = "",
        loadedCharacters: Int,
        maxCharacters: Int = 12_000
    ) -> String {
        let limit = min(max(maxCharacters, 0), 12_000)
        let needle = String(startAnchor.prefix(256))
        let loaded = min(max(loadedCharacters, 0), 500_000)
        guard !needle.isEmpty, loaded > 0, limit > 0 else { return "" }
        let budget = min(loaded + limit + 128, 500_000)
        let rendered = untrimmedReadableSuffix(maxCharacters: budget)
        guard
            let start = Self.earlierAnchorStart(
                needle, endAnchor: endAnchor, loadedCharacters: loaded, in: rendered)
        else { return "" }
        return String(rendered[..<start].suffix(limit))
    }

    /// Uses the terminal's negotiated paste mode without changing the clipboard.
    /// Multiline input cannot be pasted safely when that mode is disabled.
    public func pasteRemoteText(_ text: String) -> Bool {
        guard isRunning else { return false }
        let bracketed = terminalView.getTerminal().bracketedPasteMode
        guard bracketed || !text.contains("\n") else { return false }
        if bracketed { terminalView.send(txt: "\u{1b}[200~") }
        terminalView.send(txt: text)
        if bracketed { terminalView.send(txt: "\u{1b}[201~") }
        return true
    }

    /// Reuses local key handling, including application-cursor and enhanced modes.
    public func sendRemoteKey(_ key: String) -> Bool {
        guard isRunning else { return false }
        let selector: Selector
        switch key {
        case "enter": selector = #selector(NSTextView.insertNewline(_:))
        case "escape": selector = #selector(NSTextView.cancelOperation(_:))
        case "up": selector = #selector(NSTextView.moveUp(_:))
        case "down": selector = #selector(NSTextView.moveDown(_:))
        case "left": selector = #selector(NSTextView.moveLeft(_:))
        case "right": selector = #selector(NSTextView.moveRight(_:))
        case "tab": selector = #selector(NSTextView.insertTab(_:))
        case "backspace": selector = #selector(NSTextView.deleteBackward(_:))
        case "interrupt":
            terminalView.send(txt: "\u{3}")
            return true
        default: return false
        }
        terminalView.doCommand(by: selector)
        return true
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

    /// Finder drop or a clipboard image: paste absolute paths into the child.
    @discardableResult
    public func pasteDroppedContent(from pasteboard: NSPasteboard) -> Bool {
        terminalView.pasteDroppedContent(from: pasteboard)
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
        search.setQuery(query, in: findBufferRows())
        applyFindSelection()
    }

    /// Drops the query, the hits, and the selection used to show them.
    public func clearFind() {
        search.clear()
        terminalView.selectNone()
    }

    /// Advances to the next hit, wrapping to the first.
    public func findNext() {
        search.updateRows(findBufferRows())
        search.findNext()
        applyFindSelection()
    }

    /// Moves to the previous hit, wrapping to the last.
    public func findPrevious() {
        search.updateRows(findBufferRows())
        search.findPrevious()
        applyFindSelection()
    }

    /// One searchable row plus a Character-to-cell map. SwiftTerm stores wide
    /// characters and extended graphemes differently from Swift String offsets.
    private func findBufferRows() -> [ScrollbackSearch.Row] {
        var rows: [ScrollbackSearch.Row] = []
        var row = 0
        while let terminalRow = terminalRow(at: row, preserveWrappedWidth: true) {
            rows.append(terminalRow)
            row += 1
        }
        return rows
    }

    /// Converts one terminal row without counting the null continuation cell of
    /// a wide glyph as another Character. A row that wraps into the next one
    /// keeps its full cell width so spaces at the wrap boundary stay searchable.
    private func terminalRow(
        at row: Int,
        preserveWrappedWidth: Bool
    ) -> ScrollbackSearch.Row? {
        let terminal = terminalView.getTerminal()
        guard let line = terminal.bufferLine(atRow: row) else { return nil }
        let nextLine = terminal.bufferLine(atRow: row + 1)
        let wrapsToNext = nextLine?.isWrapped == true
        var limit = preserveWrappedWidth && wrapsToNext ? line.count : line.getTrimmedLength()

        // A wide glyph that does not fit in the final cell is moved to the next
        // row. SwiftTerm leaves a null placeholder behind; it is not a real space.
        if preserveWrappedWidth,
            wrapsToNext,
            limit > 0,
            let nextLine,
            nextLine.count > 0,
            terminal.getCharacter(for: line[limit - 1]) == "\0",
            line[limit - 1].width <= 1,
            nextLine.getWidth(index: 0) == 2
        {
            limit -= 1
        }

        var text = ""
        var columns = [0]
        var column = 0
        while column < limit {
            let cell = line[column]
            let character = terminal.getCharacter(for: cell)
            if character == "\0", column > 0, line[column - 1].width == 2 {
                column += 1
                continue
            }
            text.append(character == "\0" ? " " : character)
            column += max(Int(cell.width), 1)
            columns.append(min(column, limit))
        }
        return ScrollbackSearch.Row(
            text: text,
            cellColumns: columns,
            isWrapped: line.isWrapped
        )
    }

    /// The newest readable terminal text for VoiceOver. It is deliberately
    /// bounded so a full scrollback buffer cannot stall the main thread or make
    /// one accessibility element impractical to navigate.
    func accessibilitySnapshot(maxCharacters: Int = 50_000) -> String {
        guard maxCharacters > 0 else { return "" }
        let count = terminalRowCount()
        guard count > 0 else { return "" }

        var rows: [ScrollbackSearch.Row] = []
        var characterCount = 0
        for index in stride(from: count - 1, through: 0, by: -1) {
            guard let row = terminalRow(at: index, preserveWrappedWidth: false) else { continue }
            rows.append(row)
            characterCount += row.text.count + 1
            if characterCount >= maxCharacters { break }
        }
        rows.reverse()

        let readable = Self.accessibilitySafeText(Self.renderedText(rows))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return readable.count > maxCharacters
            ? String(readable.suffix(maxCharacters)) : readable
    }

    /// Same row walk as `accessibilitySnapshot`, without trimming either end,
    /// so a slice can abut the live tail instead of losing the boundary.
    private func untrimmedReadableSuffix(maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        let count = terminalRowCount()
        guard count > 0 else { return "" }
        var rows: [ScrollbackSearch.Row] = []
        var characterCount = 0
        for index in stride(from: count - 1, through: 0, by: -1) {
            guard let row = terminalRow(at: index, preserveWrappedWidth: false) else { continue }
            rows.append(row)
            characterCount += row.text.count + 1
            if characterCount >= maxCharacters { break }
        }
        rows.reverse()
        let rendered = Self.accessibilitySafeText(Self.renderedText(rows))
        return rendered.count > maxCharacters ? String(rendered.suffix(maxCharacters)) : rendered
    }

    static func earlierAnchorStart(
        _ needle: String,
        endAnchor: String,
        loadedCharacters: Int,
        in rendered: String
    ) -> String.Index? {
        guard !rendered.isEmpty, !needle.isEmpty else { return nil }
        let fromEnd = min(max(loadedCharacters, needle.count), rendered.count)
        let approx = rendered.index(rendered.endIndex, offsetBy: -fromEnd)
        let slack = 2_000
        let before = min(slack, rendered.distance(from: rendered.startIndex, to: approx))
        let after = min(slack + needle.count, rendered.distance(from: approx, to: rendered.endIndex))
        let windowStart = rendered.index(approx, offsetBy: -before)
        let windowEnd = rendered.index(approx, offsetBy: after)
        if windowStart < windowEnd {
            let endOnce =
                endAnchor.isEmpty ? nil : rendered.range(of: endAnchor, options: [.backwards, .literal])
            var best: String.Index?
            var bestDistance = Int.max
            var search = windowStart
            while search < windowEnd,
                let range = rendered.range(of: needle, options: .literal, range: search..<windowEnd)
            {
                let matchesEnd =
                    endAnchor.isEmpty || (endOnce.map { range.lowerBound <= $0.lowerBound } ?? true)
                if matchesEnd {
                    let distance = abs(rendered.distance(from: approx, to: range.lowerBound))
                    if distance < bestDistance {
                        best = range.lowerBound
                        bestDistance = distance
                    }
                }
                let next = rendered.index(after: range.lowerBound)
                if next <= search { break }
                search = next
            }
            if let best { return best }
        }
        guard !endAnchor.isEmpty, let end = rendered.range(of: endAnchor, options: [.backwards, .literal]) else {
            // A stale end anchor proves nothing, so keep the match nearest the loaded window.
            let earlier = rendered.range(
                of: needle, options: [.backwards, .literal], range: rendered.startIndex..<approx)
            let later = rendered.range(of: needle, options: .literal, range: approx..<rendered.endIndex)
            guard let earlier else { return later?.lowerBound }
            guard let later else { return earlier.lowerBound }
            let earlierGap = rendered.distance(from: earlier.lowerBound, to: approx)
            let laterGap = rendered.distance(from: approx, to: later.lowerBound)
            return earlierGap <= laterGap ? earlier.lowerBound : later.lowerBound
        }
        let region = rendered[..<end.upperBound]
        return region.range(of: needle, options: [.backwards, .literal])?.lowerBound
    }

    /// Finds the first missing row in O(log n), rather than walking all 10,000
    /// scrollback rows on every accessibility update.
    private func terminalRowCount() -> Int {
        let terminal = terminalView.getTerminal()
        guard terminal.bufferLine(atRow: 0) != nil else { return 0 }
        var present = 0
        var missing = 1
        while terminal.bufferLine(atRow: missing) != nil {
            present = missing
            missing *= 2
        }
        while missing - present > 1 {
            let candidate = present + (missing - present) / 2
            if terminal.bufferLine(atRow: candidate) == nil {
                missing = candidate
            } else {
                present = candidate
            }
        }
        return missing
    }

    private static func renderedText(_ rows: [ScrollbackSearch.Row]) -> String {
        var result = ""
        for (index, row) in rows.enumerated() {
            if index > 0, !row.isWrapped { result.append("\n") }
            result += row.text
        }
        return result
    }

    private static func accessibilitySafeText(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                scalars.append(scalar)
            } else if scalar.properties.generalCategory == .control {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
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
        if match.endColumn >= cols,
            terminalView.getTerminal().bufferLine(atRow: match.endLine + 1) != nil
        {
            end = Position(col: 0, row: match.endLine + 1)
        } else {
            end = Position(col: min(match.endColumn, max(cols - 1, 0)), row: match.endLine)
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
        Self.renderedText(findBufferRows())
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
    nonisolated static func reap(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return true }
        // ECHILD means SwiftTerm already collected this known child. Never probe
        // or signal the numeric pid again: the OS may already have reused it.
        if result < 0 && errno == ECHILD { return true }
        return false
    }

    /// Reports an exit the terminal view never told us about, so a tab whose
    /// child had to be killed still leaves "running" state.
    private func reportExitIfSilent() {
        guard !didReportExit else { return }
        handleProcessExit(nil)
    }

    private func noteActivity() {
        guard reportsActivity else {
            // SwiftTerm can report process termination before its main-queue
            // output drain has fed the final bytes into the emulator. Keep the
            // final VoiceOver value in step with those late bytes.
            if didReportExit { updateAccessibilitySnapshot() }
            return
        }
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
        updateAccessibilitySnapshot()
        onActivity?()
    }

    private func updateAccessibilitySnapshot() {
        NSAccessibility.post(element: terminalView, notification: .valueChanged)
    }

    private func handleProcessExit(_ rawStatus: Int32?) {
        guard !didReportExit else { return }
        didReportExit = true
        updateAccessibilitySnapshot()
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
