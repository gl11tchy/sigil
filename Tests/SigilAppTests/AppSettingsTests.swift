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

        // These tests list chats from the history files directly.

        settings.showOtherAppSessions = true
        settings.executablePath = root.path
        #expect(!settings.executableExists)
        settings.executablePath = "/bin/echo"
        #expect(settings.executableExists)
    }

    @Test @MainActor
    func aChosenStockGrokPathSurvivesARelaunch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["grok", "grok-sigil"] {
            let file = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let oldGrokHome = ProcessInfo.processInfo.environment["GROK_HOME"]
        setenv("GROK_HOME", root.path, 1)
        defer {
            if let oldGrokHome { setenv("GROK_HOME", oldGrokHome, 1) } else { unsetenv("GROK_HOME") }
        }
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        let stock = bin.appendingPathComponent("grok").path
        let themed = bin.appendingPathComponent("grok-sigil").path

        // Both old unchosen defaults now use installed discovery.
        defaults.value.set(stock, forKey: "grok.executablePath")
        #expect(AppSettings(defaults: defaults.value).usesInstalledGrok)
        defaults.value.set(themed, forKey: "grok.executablePath")
        #expect(AppSettings(defaults: defaults.value).usesInstalledGrok)

        // Once the user picks the stock CLI, a relaunch keeps it.
        AppSettings(defaults: defaults.value).executablePath = stock
        #expect(AppSettings(defaults: defaults.value).executablePath == stock)
        #expect(!AppSettings(defaults: defaults.value).usesInstalledGrok)

        // A deliberate themed choice stays too; returning to installed mode
        // clears the override and survives the next launch.
        let selected = AppSettings(defaults: defaults.value)
        selected.executablePath = themed
        #expect(AppSettings(defaults: defaults.value).executablePath == themed)
        #expect(!AppSettings(defaults: defaults.value).usesInstalledGrok)
        selected.useInstalledGrok()
        #expect(defaults.value.string(forKey: "grok.executablePath") == nil)
        #expect(!defaults.value.bool(forKey: "grok.executablePath.chosen"))
        #expect(AppSettings(defaults: defaults.value).usesInstalledGrok)
    }

    @Test @MainActor
    func legacyCustomAndMissingExplicitPathsDoNotMigrate() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        defaults.value.set("/custom/missing-grok", forKey: "grok.executablePath")
        let legacy = AppSettings(defaults: defaults.value)
        #expect(!legacy.usesInstalledGrok)
        #expect(legacy.executablePath == "/custom/missing-grok")
        #expect(!legacy.executableExists)
        defaults.value.set(true, forKey: "grok.executablePath.chosen")
        let explicit = AppSettings(defaults: defaults.value)
        #expect(!explicit.usesInstalledGrok)
        #expect(explicit.executablePath == "/custom/missing-grok")
    }

    @Test @MainActor
    func settingsRememberModePinsAndFocusedFolder() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }

        let first = AppSettings(defaults: defaults.value)
        first.focusedProjectPath = "/tmp/sigil"
        first.pinnedConversations = [.init(sessionID: "abc", cwd: "/tmp/sigil")]
        first.pinnedProjects = ["/tmp/sigil"]
        first.conversationNames = [.init(sessionID: "abc", cwd: "/tmp/sigil", name: "Auth rewrite")]
        first.showWorktreeSessions = true
        first.showSubagentSessions = true

        let second = AppSettings(defaults: defaults.value)
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

    /// The app ships as Sigil Dark. A stored "Sigil Neon" — the theme it
    /// replaced — lands on Sigil Dark too, instead of an unrelated fallback.
    @Test @MainActor
    func themeDefaultsToSigilDarkAndTheRetiredNeonThemeMovesToIt() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        #expect(AppSettings(defaults: defaults.value).theme == .sigilDark)
        defaults.value.set("Sigil Neon", forKey: "terminal.theme")
        #expect(AppSettings(defaults: defaults.value).theme == .sigilDark)
        defaults.value.set("Sigil Light", forKey: "terminal.theme")
        #expect(AppSettings(defaults: defaults.value).theme == .sigilLight)
    }

    @Test @MainActor
    func worktreeSessionsAreHiddenByDefault() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }
        let settings = AppSettings(defaults: defaults.value)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
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
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
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

extension AppSettingsTests {
    @Test @MainActor
    func newSessionDefaultsPersist() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }

        let fresh = AppSettings(defaults: defaults.value)
        #expect(fresh.defaultProvider == .grokBuild)
        #expect(fresh.startsInWorktree)

        fresh.defaultProvider = .claudeCode
        fresh.startsInWorktree = false
        let reloaded = AppSettings(defaults: defaults.value)
        #expect(reloaded.defaultProvider == .claudeCode)
        #expect(!reloaded.startsInWorktree)
    }

    @Test @MainActor
    func kimiSignInDefaultsToTheAccountAndPersists() {
        let defaults = isolatedDefaults()
        defer { defaults.reset() }

        let fresh = AppSettings(defaults: defaults.value)
        #expect(fresh.kimiSignIn == .kimiAccount)
        #expect(fresh.kimiModel == KimiCode.defaultModel)

        fresh.kimiSignIn = .apiKey
        fresh.kimiModel = "kimi-k2.7-code"
        let reloaded = AppSettings(defaults: defaults.value)
        #expect(reloaded.kimiSignIn == .apiKey)
        #expect(reloaded.kimiModel == "kimi-k2.7-code")
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
