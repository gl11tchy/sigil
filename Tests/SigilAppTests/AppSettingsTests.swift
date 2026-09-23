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
        first.conversationNames = [.init(sessionID: "abc", cwd: "/tmp/sigil", name: "Auth rewrite")]
        first.showWorktreeSessions = true
        first.showSubagentSessions = true

        let second = AppSettings(defaults: defaults.value)
        #expect(second.sidebarMode == .projects)
        #expect(second.focusedProjectPath == "/tmp/sigil")
        #expect(second.pinnedConversations == [.init(sessionID: "abc", cwd: "/tmp/sigil")])
        #expect(second.pinnedProjects == ["/tmp/sigil"])
        #expect(
            second.conversationNames == [
                .init(sessionID: "abc", cwd: "/tmp/sigil", name: "Auth rewrite")
            ])
        #expect(second.showWorktreeSessions)
        #expect(second.showSubagentSessions)
    }

    @Test @MainActor
    func sidebarDefaultsToProjectsAndKeepsAStoredRecentsValue() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        #expect(AppSettings(defaults: defaults.value).sidebarMode == .projects)
        defaults.value.set("recents", forKey: "sidebar.mode")
        #expect(AppSettings(defaults: defaults.value).sidebarMode == .recents)
    }

    @Test @MainActor
    func worktreeSessionsAreHiddenByDefault() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        let settings = AppSettings(defaults: defaults.value)
        #expect(!settings.showWorktreeSessions)
        #expect(!settings.showSubagentSessions)
    }

    @Test @MainActor
    func optionAsMetaKeyIsOffByDefaultAndRemembered() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        let first = AppSettings(defaults: defaults.value)
        #expect(!first.optionAsMetaKey)
        first.optionAsMetaKey = true
        #expect(AppSettings(defaults: defaults.value).optionAsMetaKey)
    }

    @Test @MainActor
    func persistedFontSizeIsClampedToTheSliderRange() {
        for (stored, expected) in [
            (-20.0, 8.0), (1000.0, 32.0), (Double.infinity, 13.0), (Double.nan, 13.0),
        ] {
            let defaults = isolatedDefaults()
            defer { defaults.reset() }
            defaults.value.set(stored, forKey: "terminal.fontSize")
            #expect(Double(AppSettings(defaults: defaults.value).fontSize) == expected)
        }

        let absent = isolatedDefaults()
        defer { absent.reset() }
        #expect(AppSettings(defaults: absent.value).fontSize == 13)
    }

    @Test @MainActor
    func fontSizeAssignmentsStayClampedAndRelaunchMatches() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        let settings = AppSettings(defaults: defaults.value)
        settings.fontSize = -20
        #expect(settings.fontSize == 8)
        settings.fontSize = 1000
        #expect(settings.fontSize == 32)
        #expect(AppSettings(defaults: defaults.value).fontSize == 32)
    }

    @Test @MainActor
    func invalidPersistedEffortFallsBackToTheCLIDefault() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        defaults.value.set("turbo", forKey: "session.effort")
        #expect(AppSettings(defaults: defaults.value).effort == "")
        defaults.value.set("high", forKey: "session.effort")
        #expect(AppSettings(defaults: defaults.value).effort == "high")
    }

    @Test @MainActor
    func normalizedExecutablePathTrimsWhitespaceAndExpandsTilde() {
        #expect(AppSettings.normalizedExecutablePath("  /bin/echo \n") == "/bin/echo")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AppSettings.normalizedExecutablePath("~/bin/grok") == "\(home)/bin/grok")
        #expect(AppSettings.normalizedExecutablePath("/tmp/grok") == "/tmp/grok")
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
