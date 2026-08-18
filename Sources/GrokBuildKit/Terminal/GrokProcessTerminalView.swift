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

    var isProcessRunning: Bool { process.running }

    var hostedPid: pid_t { process.running ? process.shellPid : 0 }

    func startHosted(
        executable: String,
        args: [String],
        environment: [String],
        currentDirectory: String?
    ) {
        if isProcessRunning { return }
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
}
