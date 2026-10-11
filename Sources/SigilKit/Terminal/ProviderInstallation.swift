import Darwin
import Foundation

public struct ProviderInstallation: Sendable, Equatable {
    public enum Failure: Sendable, Equatable {
        case notInstalled
        case probeFailed
    }

    public let failure: Failure?
    public let executable: URL?
    public let version: String?
    public let problem: String?
    public let timedOut: Bool
    public var isAvailable: Bool { executable != nil && problem == nil && !timedOut && failure == nil }

    public init(
        executable: URL?, version: String?, problem: String?, timedOut: Bool = false, failure: Failure? = nil
    ) {
        self.executable = executable
        self.version = version
        self.problem = problem
        self.timedOut = timedOut
        self.failure = failure
    }

    /// The blocking process wait belongs on dispatch threads, not Swift's
    /// cooperative executor. Cancellation is fenced by the caller's generation.
    public static func detectAsync(
        provider: CLIProvider, configuredExecutable: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 2
    ) async -> ProviderInstallation {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: detect(
                        provider: provider, configuredExecutable: configuredExecutable,
                        environment: environment, timeout: timeout))
            }
        }
    }

    /// Run off the main actor. This invokes only --version, never a model call.
    /// Login-shell lookup matches terminal launch, including user PATH settings.
    public static func detect(
        provider: CLIProvider, configuredExecutable: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 2,
        fallbackPath: String? = nil
    ) -> ProviderInstallation {
        let requested = environment["SHELL"] ?? "/bin/zsh"
        let supported = ["zsh", "bash", "sh", "fish"].contains(URL(fileURLWithPath: requested).lastPathComponent)
        let shell = supported && FileManager.default.isExecutableFile(atPath: requested) ? requested : "/bin/zsh"
        let command = configuredExecutable?.path ?? provider.command
        let fallbackPath =
            fallbackPath
            ?? (CLIProvider.fallbackPath
                + (provider == .grokBuild ? ":" + GrokPaths.installerBin(environment: environment) : ""))
        let marker = "__SIGIL_EXECUTABLE__="
        let missingMarker = "__SIGIL_NOT_INSTALLED__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        if URL(fileURLWithPath: shell).lastPathComponent == "fish" {
            process.arguments = [
                "-lic",
                "set -gx PATH $PATH (string split : -- $argv[1]); set executable (command -s -- $argv[2]); or begin; printf '\\n%s\\n' $argv[4]; exit 127; end; printf '\\n%s%s\\n' $argv[3] $executable; exec $executable --version",
                fallbackPath, command, marker, missingMarker,
            ]
        } else {
            process.arguments = [
                "-lic",
                "export PATH=\"$PATH:$1\"; executable=$(command -v -- \"$2\") || { printf '\\n%s\\n' \"$4\"; exit 127; }; test -x \"$executable\" || exit 126; printf '\\n%s%s\\n' \"$3\" \"$executable\"; exec \"$executable\" --version",
                "sigil-provider-check", fallbackPath, command, marker, missingMarker,
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
        let ownedRoot = probeInfo(process.processIdentifier).map(ProbeProcess.init)
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
                let stoppedTree = stopProbeTree(ownedRoot)
                let stopped = exited.wait(timeout: .now() + .milliseconds(250)) == .success
                guard stoppedTree, stopped else {
                    return ProviderInstallation(
                        executable: nil, version: nil,
                        problem: "\(provider.name)'s timed-out version check could not be stopped safely. Check Again.")
                }
                return ProviderInstallation(
                    executable: nil, version: nil, problem: "\(provider.name) did not answer its version check.",
                    timedOut: true)
            }
        }
        drain()
        let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard process.terminationStatus == 0 else {
            let missing = lines.contains { $0 == missingMarker }
            let path = lines.last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
            let executable = path.flatMap { path -> URL? in
                path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
                    ? URL(fileURLWithPath: path) : nil
            }
            return ProviderInstallation(
                executable: executable, version: nil,
                problem: missing
                    ? "Install \(provider.name) or check its executable path."
                    : "\(provider.name)'s version check failed. Check Again or check its executable path.",
                failure: missing ? .notInstalled : .probeFailed)
        }
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

    private struct ProbeProcess: Equatable {
        let pid: pid_t
        let parent: pid_t
        let seconds: UInt64
        let microseconds: UInt64

        init(_ info: proc_bsdinfo) {
            pid = pid_t(info.pbi_pid)
            parent = pid_t(info.pbi_ppid)
            seconds = info.pbi_start_tvsec
            microseconds = info.pbi_start_tvusec
        }
    }

    private static func probeInfo(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_start_tvsec > 0
        else { return nil }
        return info
    }

    /// Freeze the owned probe tree before enumerating it: a stopped parent
    /// cannot fork while its children are captured. Foundation children can
    /// have separate process groups, so the root group alone is insufficient.
    /// Reads are scoped to these PIDs, never arguments/files or the inventory.
    private static func stopProbeTree(_ root: ProbeProcess?) -> Bool {
        guard let root, root.parent == getpid(),
            let rootInfo = probeInfo(root.pid), ProbeProcess(rootInfo) == root
        else {
            return false
        }
        let pid = root.pid
        let deadline = DispatchTime.now() + .milliseconds(250)
        var pending = [root]
        var captured: [ProbeProcess] = []
        var complete = true
        while let current = pending.popLast() {
            guard captured.count < 64, DispatchTime.now() < deadline,
                let info = probeInfo(current.pid), ProbeProcess(info) == current
            else {
                complete = false
                break
            }
            captured.append(current)
            if info.pbi_status == SZOMB { continue }
            guard kill(current.pid, SIGSTOP) == 0 else {
                complete = false
                break
            }
            var stopped = false
            while DispatchTime.now() < deadline {
                guard let now = probeInfo(current.pid), ProbeProcess(now) == current else { break }
                if now.pbi_status == SSTOP || now.pbi_status == SZOMB {
                    stopped = true
                    break
                }
                usleep(1_000)
            }
            guard stopped else {
                complete = false
                break
            }
            var children = [pid_t](repeating: 0, count: 64)
            errno = 0
            let count = proc_listchildpids(current.pid, &children, Int32(children.count * MemoryLayout<pid_t>.stride))
            guard count >= 0, count < Int32(children.count), count > 0 || errno == 0 else {
                complete = false
                break
            }
            for child in children.prefix(Int(count)) {
                guard let childInfo = probeInfo(child), childInfo.pbi_ppid == UInt32(current.pid) else {
                    complete = false
                    break
                }
                pending.append(ProbeProcess(childInfo))
            }
            if !complete { break }
        }
        // Kill leaves first while their verified parents remain stopped.
        // On an incomplete walk, clean up every identity captured so far too.
        for child in (captured + pending).reversed() where child.pid != pid {
            if let info = probeInfo(child.pid), ProbeProcess(info) == child,
                kill(child.pid, SIGKILL) != 0, errno != ESRCH
            {
                complete = false
            }
        }
        guard let now = probeInfo(pid), ProbeProcess(now) == root else { return false }
        let stoppedGroup = getpgid(pid) == pid && kill(-pid, SIGKILL) == 0
        if !stoppedGroup { kill(pid, SIGKILL) }
        return complete && stoppedGroup
    }
}
