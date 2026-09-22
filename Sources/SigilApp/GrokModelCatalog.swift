import Darwin
import Foundation

/// Model ids `grok models` prints, plus the names the menus show.
enum GrokModelCatalog: Sendable {
    /// Used when the CLI is missing or its list cannot be read.
    static let fallback = ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"]

    /// Bullet rows from `grok models`. Prose and the "(default)" note are dropped.
    static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == "*" || first == "-" else { return nil }
            var name = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let note = name.firstIndex(of: "(") {
                name = String(name[..<note]).trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty, name.count <= 64, !name.contains(where: \.isWhitespace) else {
                return nil
            }
            return String(name)
        }
    }

    /// The value a model menu can select. The old text field stored padding.
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Menu rows. A saved name that the CLI does not list stays selectable.
    static func choices(listed: [String], saved: String) -> [String] {
        var result = listed.isEmpty ? fallback : listed
        let saved = normalized(saved)
        if !saved.isEmpty, !result.contains(saved) {
            result.append(saved)
        }
        return result
    }

    /// Runs `grok models`. Empty when the CLI is missing, slow, or prints no rows.
    static func load(executable: URL) async -> [String] {
        let path = executable.path
        return await Task.detached(priority: .utility) {
            runModels(at: path)
        }.value
    }

    /// Same login-shell launch a Grok tab uses, so Finder-started Sigil sees
    /// the shell's credentials when it asks for the model list.
    static func launch(executable: String, shellPath: String) -> (executable: String, arguments: [String]) {
        let fallback = "/bin/zsh"
        let shell = FileManager.default.isExecutableFile(atPath: shellPath) ? shellPath : fallback
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh", "bash", "sh":
            return (
                shell,
                ["-lic", "exec \"$@\"", "sigil-grok-models", executable, "models"]
            )
        case "fish":
            return (shell, ["-lic", "exec $argv", executable, "models"])
        default:
            return (executable, ["models"])
        }
    }

    /// SIGTERM, then SIGKILL if the process is still alive.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let grace = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < grace {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        let killed = Date().addingTimeInterval(1)
        while process.isRunning, Date() < killed {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func runModels(at path: String) -> [String] {
        guard FileManager.default.isExecutableFile(atPath: path) else { return [] }
        let command = launch(
            executable: path,
            shellPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            stop(process)
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
