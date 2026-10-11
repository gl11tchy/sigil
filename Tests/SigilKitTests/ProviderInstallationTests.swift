import Darwin
import Foundation
import Testing

@testable import SigilKit

struct ProviderInstallationTests {
    @Test func asynchronousDetectionPreservesSuccessAndFailureWithoutModelCalls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("fake cli")
        try "#!/bin/sh\n[ \"$1\" = --version ] || exit 99\nprintf 'synthetic-cli 1.0\\n'\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let environment = ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        let success = await ProviderInstallation.detectAsync(
            provider: .codex, configuredExecutable: binary, environment: environment)
        #expect(success.isAvailable)
        #expect(success.executable == binary)
        #expect(success.version == "synthetic-cli 1.0")
        #expect(!success.timedOut)
        let missing = await ProviderInstallation.detectAsync(
            provider: .codex, configuredExecutable: root.appendingPathComponent("missing"), environment: environment)
        #expect(!missing.isAvailable)
        #expect(missing.problem != nil)
        #expect(!missing.timedOut)
        #expect(missing.failure == .notInstalled)
    }
    @Test func detectsAnExecutableAndVersionWithoutStartingAConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("fake cli")
        try "#!/bin/sh\n[ \"$1\" = --version ] || exit 99\nprintf 'codex-cli 0.157.1\\n'\n".write(
            to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let found = ProviderInstallation.detect(
            provider: .codex, configuredExecutable: binary, environment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"])
        #expect(found.isAvailable)
        #expect(found.executable == binary)
        #expect(found.version == "codex-cli 0.157.1")
        let missing = ProviderInstallation.detect(
            provider: .codex, configuredExecutable: root.appendingPathComponent("missing"),
            environment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"])
        #expect(!missing.isAvailable)
        #expect(missing.problem != nil)
    }

    @Test(arguments: [false, true])
    func stalledVersionProbeReturnsAnExplicitTimeout(asynchronous: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("stall")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let environment = ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": root.path]
        let found: ProviderInstallation
        if asynchronous {
            found = await ProviderInstallation.detectAsync(
                provider: .claudeCode, configuredExecutable: binary, environment: environment, timeout: 0.05)
        } else {
            found = ProviderInstallation.detect(
                provider: .claudeCode, configuredExecutable: binary, environment: environment, timeout: 0.05)
        }
        #expect(!found.isAvailable)
        #expect(found.timedOut)
        #expect(found.problem?.contains("did not answer") == true)
    }

    @Test func aTimeoutNeverAuthorizesLaunchEvenWithAnExecutable() {
        let found = ProviderInstallation(
            executable: URL(fileURLWithPath: "/synthetic/cli"), version: nil, problem: nil, timedOut: true)
        #expect(!found.isAvailable)
    }

    @Test func invalidVersionExitIsNotATimeout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("invalid")
        try "#!/bin/sh\nexit 9\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let found = ProviderInstallation.detect(
            provider: .codex, configuredExecutable: binary,
            environment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": root.path])
        #expect(!found.isAvailable)
        #expect(!found.timedOut)
        #expect(found.problem != nil)
        #expect(found.failure == .probeFailed)
        #expect(found.executable == binary)
        #expect(found.problem?.contains("Install") == false)
    }

    @Test(arguments: [
        ("/bin/sh", false, false), ("/bin/sh", false, true),
        ("/bin/zsh", false, false), ("/bin/zsh", false, true),
        ("/bin/bash", false, false), ("/bin/bash", false, true),
        ("/bin/sh", true, false), ("/bin/sh", true, true),
    ])
    func timedOutProbeStopsItsChildAndReapsTheDirectProcess(
        shell: String, separateGroup: Bool, asynchronous: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("pids")
        let binary = root.appendingPathComponent("spawn")
        let header = separateGroup ? "#!/bin/bash\nset -m\n" : "#!/bin/sh\n"
        try
            (header
            + "/bin/sleep 3 &\nchild=$!\nprintf '%s %s\\n' \"$$\" \"$child\" > '\(capture.path)'\n/bin/ps -o pgid= -p \"$child\" >> '\(capture.path)'\nwait\n")
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let environment = ["SHELL": shell, "PATH": "/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": root.path]
        let found: ProviderInstallation
        if asynchronous {
            found = await ProviderInstallation.detectAsync(
                provider: .codex, configuredExecutable: binary, environment: environment, timeout: 0.2)
        } else {
            found = ProviderInstallation.detect(
                provider: .codex, configuredExecutable: binary, environment: environment, timeout: 0.2)
        }
        #expect(found.timedOut)
        #expect(!found.isAvailable)
        let pids = try String(contentsOf: capture, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        #expect(pids.count == 3)
        guard pids.count == 3 else { return }
        #expect(pids[2] == (separateGroup ? pids[1] : pids[0]))
        let directResult = kill(pids[0], 0)
        let directError = errno
        #expect(directResult == -1 && directError == ESRCH)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let childExists = proc_pidinfo(pids[1], PROC_PIDTBSDINFO, 0, &info, size) == size
        let childIsRunning = childExists && info.pbi_status != SZOMB
        #expect(!childIsRunning)
        if childIsRunning {
            // On a regression only this bounded fake sleep is left to finish.
            // Never signal a PID from a later, possibly reused observation.
            try await Task.sleep(for: .seconds(3.2))
        }
    }
}
