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
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
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
        try runOrThrow(["mcp", "remove", Self.serverName, "-s", "user"])
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
        } catch {
            return (127, error.localizedDescription)
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
            if process.isRunning {
                let partial = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
                let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
                return (1, trimmed.isEmpty ? note : partial + "\n" + note)
            }
            let output = readMerged(pipe)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (1, trimmed.isEmpty ? note : output + "\n" + note)
        }

        return (process.terminationStatus, readMerged(pipe))
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

    private static func readMerged(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
