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
    private var isForwardingBracketedPaste = false

    var isProcessRunning: Bool { process.running }

    var hostedPid: pid_t { process.running ? process.shellPid : 0 }

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

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onChildOutput?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if data.elementsEqual(Self.bracketedPasteStart) {
            isForwardingBracketedPaste = true
        } else if data.elementsEqual(Self.bracketedPasteEnd) {
            isForwardingBracketedPaste = false
        } else if !isForwardingBracketedPaste,
            data.contains(0x0A) || data.contains(0x0D)
        {
            // Capture the journal offset before Return reaches the child. A fast
            // response can otherwise append its completion event first.
            onUserSubmit?()
        }
        super.send(source: source, data: data)
    }

    private static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    private static let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
}
