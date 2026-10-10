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
    }
}
