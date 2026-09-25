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

    /// The list a model menu shows for `executable`: the CLI's rows, or the
    /// fallback when it lists none. Nil when the caller was cancelled (the path
    /// changed), so a late list never replaces the one for the current path.
    static func menuModels(
        executable: URL,
        loader: @Sendable (URL) async -> [String] = { await GrokModelCatalog.load(executable: $0) }
    ) async -> [String]? {
        let found = await loader(executable)
        guard !Task.isCancelled else { return nil }
        return found.isEmpty ? fallback : found
    }

    /// Runs `grok models`. Empty when the CLI is missing, slow, or prints no rows.
    static func load(
        executable: URL,
        shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) async -> [String] {
        let path = executable.path
        let task = Task.detached(priority: .utility) {
            await runModels(at: path, shellPath: shellPath)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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
            return (fallback, ["-lic", "exec \"$@\"", "sigil-grok-models", executable, "models"])
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

    /// Never blocks a cooperative thread: stdout drains on its own reader,
    /// exit arrives through the termination handler, and a profile helper
    /// that inherited stdout cannot hold the result past a short grace.
    private static func runModels(at path: String, shellPath: String) async -> [String] {
        guard FileManager.default.isExecutableFile(atPath: path) else { return [] }
        let command = launch(executable: path, shellPath: shellPath)
        guard let output = await output(of: command.executable, arguments: command.arguments) else { return [] }
        return parse(output)
    }

    /// Standard output of a short list command. Nil when it fails, runs past
    /// three seconds, or the caller is cancelled.
    static func output(of executable: String, arguments: [String]) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let captured = CapturedOutput()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { reader.leave() }
            captured.drain(output.fileHandleForReading)
        }
        let exit = OnceSignal()
        process.terminationHandler = { _ in exit.finish(true) }
        do {
            try process.run()
            try? output.fileHandleForWriting.close()
        } catch {
            try? output.fileHandleForWriting.close()
            captured.stop()
            return nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { exit.finish(false) }
        let exited = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            exit.finish(false)
        }
        guard exited else {
            captured.stop()
            DispatchQueue.global(qos: .utility).async { stop(process) }
            return nil
        }
        let drained = OnceSignal()
        reader.notify(queue: .global(qos: .utility)) { drained.finish(true) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { drained.finish(false) }
        _ = await drained.wait()
        captured.stop()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: captured.data, as: UTF8.self)
    }
}

/// Resolves once, with the first value any caller reports.
private final class OnceSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// Reads stdout as it arrives. `stop()` ends the read even when a child
/// that inherited the pipe keeps it open; the reader then closes the handle.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var stopped = false

    func drain(_ handle: FileHandle) {
        defer { try? handle.close() }
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while !isStopped {
            let ready = poll(&descriptor, 1, 50)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { return }
            let count = read(handle.fileDescriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return }
            lock.lock()
            buffer.append(contentsOf: chunk[0..<count])
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
