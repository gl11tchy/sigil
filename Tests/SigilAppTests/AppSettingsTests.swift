import Foundation
import Testing

@testable import SigilApp

@Suite(.serialized)
struct AppSettingsTests {
    @Test @MainActor
    func executableValidationAcceptsSymlinksAndRejectsDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("grok-real")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        let symlink = root.appendingPathComponent("grok")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)

        #expect(AppSettings.isExecutableFile(at: executable))
        #expect(AppSettings.isExecutableFile(at: symlink))
        #expect(!AppSettings.isExecutableFile(at: root))
        #expect(!AppSettings.isExecutableFile(at: root.appendingPathComponent("missing")))
    }

    @Test @MainActor
    func settingsUseTheValidatedExecutablePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = isolatedDefaults()
        defer { defaults.reset() }

        let settings = AppSettings(defaults: defaults.value)
        settings.executablePath = root.path
        #expect(!settings.executableExists)
        settings.executablePath = "/bin/echo"
        #expect(settings.executableExists)
    }

    @Test @MainActor
    func settingsRememberModePinsAndFocusedFolder() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }

        let first = AppSettings(defaults: defaults.value)
        first.sidebarMode = .projects
        first.focusedProjectPath = "/tmp/sigil"
        first.pinnedConversations = [.init(sessionID: "abc", cwd: "/tmp/sigil")]
        first.pinnedProjects = ["/tmp/sigil"]
        first.showWorktreeSessions = true

        let second = AppSettings(defaults: defaults.value)
        #expect(second.sidebarMode == .projects)
        #expect(second.focusedProjectPath == "/tmp/sigil")
        #expect(second.pinnedConversations == [.init(sessionID: "abc", cwd: "/tmp/sigil")])
        #expect(second.pinnedProjects == ["/tmp/sigil"])
        #expect(second.showWorktreeSessions)
    }

    @Test @MainActor
    func worktreeSessionsAreHiddenByDefault() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        let settings = AppSettings(defaults: defaults.value)
        #expect(!settings.showWorktreeSessions)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func isolatedDefaults() -> (value: UserDefaults, reset: () -> Void) {
    let name = "SigilAppTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}
