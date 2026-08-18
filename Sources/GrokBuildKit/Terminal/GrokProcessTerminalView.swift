import AppKit
import Darwin
import Foundation
import SwiftTerm

/// `LocalProcessTerminalView` that reports child output so activity can be coalesced.
///
/// Uses SwiftTerm's PTY when the host allows `forkpty`. When the sandbox
/// refuses a PTY slave, falls back to a session-leader pipe host so tests and
/// headless environments still see real child I/O.
final class GrokProcessTerminalView: LocalProcessTerminalView {
    /// Invoked on the main queue when the child writes output.
    var onChildOutput: (() -> Void)?

    private var fallback: HostedProcess?

    var isProcessRunning: Bool {
        process.running || (fallback?.isRunning ?? false)
    }

    var hostedPid: pid_t {
        if process.running { return process.shellPid }
        return fallback?.pid ?? 0
    }

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
        if process.running { return }
        let host = HostedProcess()
        host.windowSize = { [weak self] in
            self?.getWindowSize() ?? winsize()
        }
        host.onData = { [weak self] bytes in
            MainActor.assumeIsolated {
                self?.feed(byteArray: bytes[...])
                self?.onChildOutput?()
            }
        }
        host.onExit = { [weak self] code in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fallback = nil
                self.processDelegate?.processTerminated(source: self, exitCode: code)
            }
        }
        fallback = host
        host.start(
            executable: executable,
            args: args,
            environment: environment,
            currentDirectory: currentDirectory
        )
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
        fallback?.terminate()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if process.running {
            super.send(source: source, data: data)
        } else {
            fallback?.send(data)
        }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onChildOutput?()
    }
}
