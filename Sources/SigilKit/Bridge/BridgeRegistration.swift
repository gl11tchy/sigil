import Darwin
import Foundation

/// Registers and unregisters the bundled `sigil-mcp` binary with the Grok CLI.
///
/// Shells out to `grok mcp add` / `remove` / `list`. The CLI writes
/// `~/.grok/config.toml`; there is no `--mcp-config` flag (verified grok 1.0.5).
public struct BridgeRegistration: Sendable {
    /// Runs a command and returns (exitCode, stdout+stderr). Injected so tests never spawn grok.
    public typealias Runner = @Sendable (_ executable: URL, _ arguments: [String]) -> (Int32, String)

    public static let serverName = "sigil"

    public enum Error: Swift.Error, Equatable, LocalizedError {
        /// Non-zero exit, or the process never finished. `output` is stdout+stderr,
        /// or a timeout message when the wait expired.
        case failed(output: String)

        public var output: String {
            switch self {
            case .failed(let output): return output
            }
        }

        public var errorDescription: String? {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "grok mcp failed" : trimmed
        }
    }

    private let executable: URL
    private let runner: Runner

    public init(executable: URL, runner: @escaping Runner = BridgeRegistration.processRunner) {
        self.executable = executable
        self.runner = runner
    }

    /// `sigil-mcp` sitting next to the running app executable, or `nil` if it is not there.
    public static var bundledMCPBinary: URL? {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return nil
        }
        let candidate = directory.appendingPathComponent("sigil-mcp")
        return isUsableMCPBinary(at: candidate) ? candidate : nil
    }

    static func isUsableMCPBinary(at candidate: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            FileManager.default.isExecutableFile(atPath: candidate.path)
        else { return false }
        return true
    }

    /// True when `grok mcp list` reports a server called `sigil`.
    public func isInstalled() -> Bool {
        let (code, output) = runner(executable, ["mcp", "list"])
        guard code == 0 else { return false }
        return Self.listingContainsServer(output)
    }

    /// Registers `mcpBinary` as the `sigil` stdio server. Throws with the CLI's own
    /// output on failure, so the UI can show the user what grok said.
    public func install(mcpBinary: URL) throws {
        try runOrThrow(["mcp", "add", Self.serverName, mcpBinary.path, "-s", "user"])
    }

    public func remove() throws {
        let (listCode, listing) = runner(executable, ["mcp", "list"])
        guard listCode == 0 else { throw Error.failed(output: listing) }
        guard Self.listingContainsServer(listing) else { return }

        let arguments = ["mcp", "remove", Self.serverName, "-s", "user"]
        let (removeCode, output) = runner(executable, arguments)
        guard removeCode != 0 else { return }

        // Another process may remove the entry between our list and remove calls.
        // Confirm the final state before reporting a failure.
        let (verifyCode, verifiedListing) = runner(executable, ["mcp", "list"])
        if verifyCode == 0, !Self.listingContainsServer(verifiedListing) { return }
        throw Error.failed(output: output)
    }

    /// Real runner: `Foundation.Process`, stdout and stderr merged, no shell.
    public static func processRunner(executable: URL, arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
            // The child owns its duplicated writer now. Keeping the parent's
            // copy open can prevent the reader from ever observing EOF.
            try? pipe.fileHandleForWriting.close()
        } catch {
            try? pipe.fileHandleForWriting.close()
            return (127, error.localizedDescription)
        }

        // Drain while the child runs. Waiting first can deadlock when the child
        // fills the pipe buffer before it exits.
        let captured = CapturedOutput()
        let readerFinished = DispatchGroup()
        readerFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            do {
                while let data = try pipe.fileHandleForReading.read(upToCount: 16_384),
                    !data.isEmpty
                {
                    captured.append(data)
                }
            } catch {
                // The bounded wait closes the handle when a descendant keeps it
                // open. Bytes already read still provide the useful CLI error.
            }
            readerFinished.leave()
        }

        let timeoutSeconds: TimeInterval = 15
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut, process.isRunning {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            let note = "grok did not finish within \(Int(timeoutSeconds)) seconds"
            waitForReader(readerFinished, handle: pipe.fileHandleForReading)
            let output = String(decoding: captured.data, as: UTF8.self)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (1, trimmed.isEmpty ? note : output + "\n" + note)
        }

        waitForReader(readerFinished, handle: pipe.fileHandleForReading)
        return (process.terminationStatus, String(decoding: captured.data, as: UTF8.self))
    }

    /// A command can launch a descendant that inherits stdout. Do not let that
    /// unrelated process keep Settings blocked after the command itself exits.
    private static func waitForReader(_ group: DispatchGroup, handle: FileHandle) {
        guard group.wait(timeout: .now() + 1) == .timedOut else { return }
        try? handle.close()
        _ = group.wait(timeout: .now() + 1)
    }

    private func runOrThrow(_ arguments: [String]) throws {
        let (code, output) = runner(executable, arguments)
        guard code == 0 else { throw Error.failed(output: output) }
    }

    /// Server names may contain hyphens, so a word-boundary match would treat
    /// `my-sigil` as a hit. Tokens are letters, digits, hyphens, and underscores.
    private static func listingContainsServer(_ listing: String) -> Bool {
        let tokens = listing.split { character in
            !(character.isLetter || character.isNumber || character == "-" || character == "_")
        }
        return tokens.contains { $0 == serverName[...] }
    }
}

private final class CapturedOutput: @unchecked Sendable {
    private static let limit = 1_048_576
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        let remaining = max(0, Self.limit - storage.count)
        if remaining > 0 { storage.append(data.prefix(remaining)) }
        lock.unlock()
    }
}
