import Darwin
import Foundation

public struct ProviderInstallation: Sendable, Equatable {
    public let executable: URL?
    public let version: String?
    public let problem: String?
    public var isAvailable: Bool { executable != nil && problem == nil }

    /// Run off the main actor. This invokes only --version, never a model call.
    /// Login-shell lookup matches terminal launch, including user PATH settings.
    public static func detect(
        provider: CLIProvider, configuredExecutable: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 2
    ) -> ProviderInstallation {
        let requested = environment["SHELL"] ?? "/bin/zsh"
        let supported = ["zsh", "bash", "sh", "fish"].contains(URL(fileURLWithPath: requested).lastPathComponent)
        let shell = supported && FileManager.default.isExecutableFile(atPath: requested) ? requested : "/bin/zsh"
        let command =
            configuredExecutable?.path ?? (provider == .grokBuild ? GrokPaths.defaultExecutable.path : provider.command)
        let marker = "__SIGIL_EXECUTABLE__="
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        if URL(fileURLWithPath: shell).lastPathComponent == "fish" {
            process.arguments = [
                "-lic",
                "set -gx PATH $PATH (string split : -- $argv[1]); set executable (command -s -- $argv[2]); or exit 127; printf '\\n%s%s\\n' $argv[3] $executable; exec $executable --version",
                CLIProvider.fallbackPath, command, marker,
            ]
        } else {
            process.arguments = [
                "-lic",
                "export PATH=\"$PATH:$1\"; executable=$(command -v -- \"$2\") || exit 127; test -x \"$executable\" || exit 126; printf '\\n%s%s\\n' \"$3\" \"$executable\"; exec \"$executable\" --version",
                "sigil-provider-check", CLIProvider.fallbackPath, command, marker,
            ]
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return ProviderInstallation(
                executable: nil, version: nil, problem: "\(provider.name) could not be started.")
        }
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { try? pipe.fileHandleForReading.close() }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        func drain() {
            // Bound each drain as well as memory: a continuous writer must not
            // prevent the outer loop from checking its deadline.
            for _ in 0..<16 {
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { break }
                output.append(contentsOf: chunk.prefix(count))
                // A noisy shell must not consume unbounded memory.
                if output.count > 65_536 { output.removeFirst(output.count - 65_536) }
            }
        }
        let deadline = DispatchTime.now() + max(0.01, timeout)
        while exited.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            drain()
            if DispatchTime.now() >= deadline {
                kill(process.processIdentifier, SIGKILL)
                return ProviderInstallation(
                    executable: nil, version: nil, problem: "\(provider.name) did not answer its version check.")
            }
        }
        drain()
        guard process.terminationStatus == 0 else {
            return ProviderInstallation(
                executable: nil, version: nil, problem: "Install \(provider.name) or check its executable path.")
        }
        let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let index = lines.lastIndex(where: { $0.hasPrefix(marker) }) else {
            return ProviderInstallation(
                executable: nil, version: nil, problem: "\(provider.name) did not report its executable.")
        }
        let path = String(lines[index].dropFirst(marker.count))
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            return ProviderInstallation(
                executable: nil, version: nil, problem: "\(provider.name) executable is unavailable.")
        }
        let version = lines.dropFirst(index + 1).first.map { String($0.prefix(160)) }
        return ProviderInstallation(executable: URL(fileURLWithPath: path), version: version, problem: nil)
    }
}
