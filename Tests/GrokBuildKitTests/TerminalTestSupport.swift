import AppKit
import Darwin
import Foundation
import Testing

@testable import GrokBuildKit

enum TerminalTestSupport {
    @MainActor
    static func prepareAppKit() {
        _ = NSApplication.shared
    }

    static func launchSpec(
        executable: URL,
        extraArguments: [String] = [],
        cwd: URL = FileManager.default.temporaryDirectory
    ) -> GrokLaunchSpec {
        GrokLaunchSpec(
            executable: executable,
            workingDirectory: cwd,
            mode: .continueLatest,
            extraArguments: extraArguments
        )
    }

    /// Script that drops the grok wrapper flags `GrokLaunchSpec.arguments()` adds,
    /// then execs the remaining command. Lives under the process temp directory.
    static func makeFlagStrippingHelper() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokbuild-term-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("run")
        let script = """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          case "$1" in
            --cwd|--session-id|--resume|--model|--reasoning-effort)
              [ $# -ge 2 ] || exit 1
              shift 2
              ;;
            --continue)
              shift
              ;;
            *)
              break
              ;;
          esac
        done
        exec "$@"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @MainActor
    static func waitUntil(
        timeout: Duration = .seconds(5),
        poll: Duration = .milliseconds(20),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: poll)
        }
        return condition()
    }

    static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    static func processGroupMembers(_ pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=", "-g", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .compactMap { pid_t($0) }
    }
}
