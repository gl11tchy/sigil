import Foundation
import Testing

@testable import SigilKit

struct ProviderInstallationTests {
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

    @Test func stalledVersionProbeReturnsAnExplicitProblem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("stall")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let found = ProviderInstallation.detect(
            provider: .claudeCode, configuredExecutable: binary,
            environment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"], timeout: 0.05)
        #expect(!found.isAvailable)
        #expect(found.problem?.contains("did not answer") == true)
    }
}
