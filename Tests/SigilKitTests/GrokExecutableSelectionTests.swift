import Foundation
import Testing

@testable import SigilKit

struct GrokExecutableSelectionTests {
    @Test(arguments: [false, true])
    func aKnownLegacyDefaultMigratesOnlyWithoutAnExplicitChoice(chosen: Bool) {
        let installer = URL(fileURLWithPath: "/fixture/.grok/bin/grok")
        let themed = installer.deletingLastPathComponent().appendingPathComponent("grok-sigil")
        for path in [installer.path, themed.path] {
            #expect(
                GrokExecutableSelection.restoring(
                    storedPath: path, wasChosen: chosen, installer: installer, themed: themed)
                    == (chosen ? .custom(path) : .installed))
        }
    }

    @Test func firstUseAndLegacyCustomPathsKeepTheirIntent() {
        let installer = URL(fileURLWithPath: "/fixture/.grok/bin/grok")
        let themed = installer.deletingLastPathComponent().appendingPathComponent("grok-sigil")
        #expect(
            GrokExecutableSelection.restoring(
                storedPath: nil, wasChosen: false, installer: installer, themed: themed) == .installed)
        #expect(
            GrokExecutableSelection.restoring(
                storedPath: "/custom/missing grok", wasChosen: false, installer: installer, themed: themed)
                == .custom("/custom/missing grok"))
        #expect(
            GrokExecutableSelection.restoring(
                storedPath: "", wasChosen: true, installer: installer, themed: themed) == .custom(""))
    }

    @Test func installedDiscoveryPrefersTheLoginShellOverAStaleThemedAndInstallerCopy() throws {
        let fixture = try GrokExecutableFixture()
        defer { fixture.remove() }
        let found = fixture.detect()
        #expect(found.isAvailable)
        #expect(found.executable == fixture.host)
        #expect(found.version == "grok 2.0.0 synthetic-host")
    }

    @Test func installerFallbackIsUsedOnlyAfterTheLoginShellPath() throws {
        let fixture = try GrokExecutableFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.host)
        let found = fixture.detect()
        #expect(found.isAvailable)
        #expect(found.executable == fixture.installer)
        #expect(found.version == "grok 2.0.0 synthetic-installer")
    }

    @Test func aThemedCopyAloneDoesNotBecomeAnAutomaticFallback() throws {
        let fixture = try GrokExecutableFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.host)
        try FileManager.default.removeItem(at: fixture.installer)
        let found = fixture.detect()
        #expect(!found.isAvailable)
        #expect(found.executable == nil)
        #expect(found.problem != nil)
    }

    @Test func anExplicitThemedCopyStaysSelectedDespiteANewerHost() throws {
        let fixture = try GrokExecutableFixture()
        defer { fixture.remove() }
        let found = fixture.detect(configured: fixture.themed)
        #expect(found.isAvailable)
        #expect(found.executable == fixture.themed)
        #expect(found.version == "grok 1.0.0 synthetic-themed")
    }

    @Test func aMissingExplicitChoiceNeverFallsBackToTheHost() throws {
        let fixture = try GrokExecutableFixture()
        defer { fixture.remove() }
        let found = fixture.detect(configured: fixture.root.appendingPathComponent("missing"))
        #expect(!found.isAvailable)
        #expect(found.executable == nil)
        #expect(found.problem != nil)
    }

    @Test func automaticLaunchPreservesHostPathOrderAndExecutesTheNormalGrok() throws {
        let fixture = try GrokExecutableFixture()
        defer { fixture.remove() }
        let spec = GrokLaunchSpec(workingDirectory: fixture.root, mode: .continueLatest)
        let environment = spec.environment(processEnvironment: fixture.environment)
        #expect(environment["PATH"] == fixture.environment["PATH"])
        let output = try fixture.run(spec.hostCommand(processEnvironment: environment), environment: environment)
        #expect(output.contains("grok 2.0.0 synthetic-host"))
        #expect(output.contains("--continue"))
        #expect(!output.contains("synthetic-themed"))
    }

    @Test(arguments: ["new", "resume", "restart"])
    func aCheckedPathIsTheLaunchTargetEvenWhenTheProfileChanges(action: String) throws {
        let fixture = try GrokExecutableFixture()
        defer { fixture.remove() }
        let checked = try #require(fixture.detect().executable)
        // Another path now comes first. An already checked launch remains pinned.
        try fixture.writeProfile(path: fixture.installer.deletingLastPathComponent().path)
        let mode: GrokLaunchSpec.Mode =
            action == "new" ? .new(sessionID: UUID()) : .resume(sessionID: "fixture-session")
        let spec = GrokLaunchSpec(executable: checked, workingDirectory: fixture.root, mode: mode)
        let environment = spec.environment(processEnvironment: fixture.environment)
        let output = try fixture.run(spec.hostCommand(processEnvironment: environment), environment: environment)
        #expect(output.contains("grok 2.0.0 synthetic-host"))
        #expect(!output.contains("synthetic-installer"))
        #expect(output.contains(action == "new" ? "--session-id" : "--resume fixture-session"))
    }
}

private struct GrokExecutableFixture {
    let root: URL
    let host: URL
    let installer: URL
    let themed: URL
    var environment: [String: String] {
        [
            "HOME": root.path, "CFFIXED_USER_HOME": root.path, "ZDOTDIR": root.path,
            "GROK_HOME": installer.deletingLastPathComponent().deletingLastPathComponent().path,
            "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin", "TERM": "dumb",
        ]
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-selection-\(UUID().uuidString)")
        host = root.appendingPathComponent("host tools/grok")
        installer = root.appendingPathComponent(".grok/bin/grok")
        themed = root.appendingPathComponent(".grok/bin/grok-sigil")
        for (file, version) in [
            (host, "grok 2.0.0 synthetic-host"), (installer, "grok 2.0.0 synthetic-installer"),
            (themed, "grok 1.0.0 synthetic-themed"),
        ] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nprintf '\(version)\\n'\n[ \"$1\" = --version ] || printf 'arguments=%s\\n' \"$*\"\n"
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try writeProfile(path: host.deletingLastPathComponent().path)
    }

    func writeProfile(path: String) throws {
        // Generated UUID paths may contain spaces, but contain no quotes.
        try "export PATH='\(path):/usr/bin:/bin'\n".write(
            to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    }

    func detect(configured: URL? = nil) -> ProviderInstallation {
        ProviderInstallation.detect(
            provider: .grokBuild, configuredExecutable: configured,
            environment: environment, fallbackPath: installer.deletingLastPathComponent().path)
    }

    func run(_ command: GrokLaunchSpec.HostCommand, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        try pipe.fileHandleForWriting.close()
        guard done.wait(timeout: .now() + .seconds(3)) == .success else {
            process.terminate()
            throw CocoaError(.executableRuntimeMismatch)
        }
        #expect(process.terminationStatus == 0)
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
