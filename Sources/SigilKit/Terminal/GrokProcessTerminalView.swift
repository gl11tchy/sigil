import AppKit
import Darwin
import Foundation
import SwiftTerm

/// `LocalProcessTerminalView` that reports child output, so the controller can
/// coalesce it into an "is the agent working" signal.
///
/// The CLI is a full-screen terminal program: it needs a real pseudo-terminal,
/// not pipes. If `forkpty` ever fails there is nothing useful to fall back to —
/// the view reports the failure and stays empty rather than running the CLI in a
/// mode where its interface would not work.
final class GrokProcessTerminalView: LocalProcessTerminalView {
    /// Invoked on the main queue when the child writes output.
    var onChildOutput: (() -> Void)?
    /// Invoked when the user submits the current prompt with Return.
    var onUserSubmit: (() -> Void)?
    /// Every byte sent, including menu digits, paste, and non-Return keys.
    var onInput: (() -> Void)?
    /// Builds the VoiceOver value when an assistive client asks, not on every output tick.
    var accessibilityText: (() -> String)?
    /// Moves on every child write and every resize, the only ways Sigil changes
    /// the buffer. Find reuses its last read of the rows while this is unchanged.
    fileprivate(set) var contentGeneration = 0
    private var isForwardingBracketedPaste = false
    /// Held strongly here: `terminalDelegate` is weak.
    private lazy var clipboardGuard = ClipboardGuard(view: self)

    var isProcessRunning: Bool { process.running }

    var hostedPid: pid_t { process.running ? process.shellPid : 0 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes(TerminalDrop.pasteboardTypes)
        terminalDelegate = clipboardGuard
    }

    override init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        registerForDraggedTypes(TerminalDrop.pasteboardTypes)
        terminalDelegate = clipboardGuard
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(TerminalDrop.pasteboardTypes)
        terminalDelegate = clipboardGuard
    }

    override func paste(_ sender: Any) {
        paste(from: NSPasteboard.general)
    }

    /// Cmd-V. Takes the pasteboard so tests do not touch the user's clipboard.
    func paste(from pasteboard: NSPasteboard) {
        let text = pasteboard.string(forType: .string) ?? ""
        // A Finder copy pastes paths; copied text wins over its picture rendition.
        let hasFiles = !TerminalDrop.filesToPaste(from: TerminalDrop.fileURLs(from: pasteboard)).isEmpty
        if hasFiles || text.isEmpty, pasteDroppedContent(from: pasteboard) { return }
        // Finder also puts a refused file's name on the pasteboard as text.
        if TerminalDrop.hasUnsafeFileName(TerminalDrop.fileURLs(from: pasteboard)) {
            NSSound.beep()
            return
        }
        guard !text.isEmpty else { return }
        unmarkText()
        sendPaste(text)
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
        pasteDroppedContent(from: sender.draggingPasteboard)
    }

    @discardableResult
    func pasteDroppedContent(from pasteboard: NSPasteboard) -> Bool {
        guard process.running else { return false }
        guard let paths = try? TerminalDrop.pathsToPaste(from: pasteboard), !paths.isEmpty else {
            return false
        }
        sendPaste(TerminalDrop.pasteText(for: paths))
        return true
    }

    /// Pasted text cannot carry ESC or other controls: an embedded ESC[201~
    /// would end bracketed paste early and run the rest as typed keys.
    private func sendPaste(_ text: String) {
        let safe = TerminalDrop.sanitizedPasteText(text)
        let bracketed = getTerminal().bracketedPasteMode
        if bracketed { send(txt: "\u{1b}[200~") }
        send(txt: safe)
        if bracketed { send(txt: "\u{1b}[201~") }
    }

    func startHosted(
        executable: String,
        args: [String],
        environment: [String],
        currentDirectory: String?
    ) {
        if isProcessRunning { return }
        isForwardingBracketedPaste = false
        startProcess(
            executable: executable,
            args: args,
            environment: environment,
            currentDirectory: currentDirectory
        )
        guard process.running else {
            processDelegate?.processTerminated(source: self, exitCode: nil)
            return
        }
    }

    func terminateHosted() {
        let pid = hostedPid
        if pid > 0 {
            if getpgid(pid) == pid {
                kill(-pid, SIGTERM)
            }
            kill(pid, SIGTERM)
        }
        process.terminate()
    }

    override func accessibilityValue() -> Any? {
        accessibilityText?() ?? super.accessibilityValue()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        contentGeneration &+= 1
        onChildOutput?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !data.isEmpty { onInput?() }
        if data.elementsEqual(Self.bracketedPasteStart) {
            isForwardingBracketedPaste = true
        } else if data.elementsEqual(Self.bracketedPasteEnd) {
            isForwardingBracketedPaste = false
        } else if !isForwardingBracketedPaste,
            data.contains(0x0A) || data.contains(0x0D) || Self.isEnhancedReturnPress(data)
        {
            // Report input before Return reaches the child. The tab decides
            // whether a validated lifecycle journal can observe work.
            onUserSubmit?()
        }
        super.send(source: source, data: data)
    }

    private static func isEnhancedReturnPress(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count >= 5,
            data.first == 0x1B,
            data[data.index(after: data.startIndex)] == 0x5B,
            data.last == 0x75,
            let body = String(bytes: data.dropFirst(2).dropLast(), encoding: .ascii)
        else { return false }
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        guard fields[0].split(separator: ":").first == "13" else { return false }
        guard fields.count > 1 else { return true }
        let eventField = fields[1].split(separator: ":")
        return eventField.count < 2 || eventField[1] != "3"
    }

    private static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    private static let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
}

/// Stands in as the view's `terminalDelegate` so OSC 52 cannot reach the Mac
/// clipboard. Child output could otherwise read it back into the pty (a remote
/// host over ssh gets the user's last copy) or replace it silently.
/// `LocalProcessTerminalView` implements both calls as `public`, not `open`, so
/// a subclass cannot override them. Everything else goes to the view.
/// SwiftTerm is built in Swift 5 mode, so its delegate protocol is nonisolated;
/// the view only calls it on the main thread.
@MainActor
private final class ClipboardGuard: @preconcurrency TerminalViewDelegate {
    unowned let view: GrokProcessTerminalView

    init(view: GrokProcessTerminalView) {
        self.view = view
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func clipboardCopy(source: TerminalView, content: Data) {}

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // A resize reflows wrapped rows. Every resize path in SwiftTerm ends here.
        view.contentGeneration &+= 1
        view.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        view.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        view.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        view.scrolled(source: source, position: position)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        view.requestOpenLink(source: source, link: link, params: params)
    }

    func bell(source: TerminalView) {
        view.bell(source: source)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        view.iTermContent(source: source, content: content)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        view.rangeChanged(source: source, startY: startY, endY: endY)
    }
}
