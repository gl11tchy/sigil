import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct NativeStartupRestorationTests {
    @Test
    func anUnavailableSavedCodexEntryRemainsASavedIntentWithoutOpeningATab() throws {
        _ = NSApplication.shared
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        fixture.settings.isTabMessagingEnabled = false
        let entry = OpenTabsSnapshot.Entry(
            sessionID: UUID().uuidString.lowercased(), cwd: fixture.root.path, provider: .codex)
        fixture.settings.openTabs = .init(
            tabs: [entry], selectedSessionID: entry.sessionID, selectedCWD: entry.cwd, selectedProvider: .codex)
        var installations = fixtureProviderInstallations(fixture.executable)
        let problem = "Synthetic Codex executable is unavailable."
        installations[.codex] = .init(executable: nil, version: nil, problem: problem)
        let model = AppModel(
            settings: fixture.settings, store: fixture.store, presentError: { _ in },
            panel: RightPanel(defaults: fixture.defaults, notesStore: ConversationNotesStore(root: fixture.notesRoot)),
            pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(),
            providerInstallations: installations)
        defer { model.closeAllTabsAndWait() }

        model.restoreOpenTabs()

        #expect(model.tabs.isEmpty)
        #expect(fixture.settings.openTabs.tabs == [entry])
        #expect(model.providerLaunchProblem(.codex) == problem)
        print(
            "REA-1240 saved-intent baseline: one Codex reference retained, zero tabs, synthetic unavailable probe message"
        )
    }

    @Test
    func quittingAnUnsavableDevinTabExplainsThatItWillNotReopen() throws {
        _ = NSApplication.shared
        let fixture = try ModelFixture(script: "#!/bin/sh\nwhile IFS= read -r line; do :; done\n")
        defer { fixture.cleanup() }
        fixture.settings.isTabMessagingEnabled = false
        let oldShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", fixture.executable.path, 1)
        defer {
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
        }
        let model = AppModel(
            settings: fixture.settings, store: fixture.store, presentError: { _ in },
            panel: RightPanel(defaults: fixture.defaults, notesStore: ConversationNotesStore(root: fixture.notesRoot)),
            pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(),
            providerInstallations: fixtureProviderInstallations(fixture.executable))
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: fixture.root, provider: .devin))
        #expect(tab.nativeSessionID == nil)
        let prompt = try #require(StopWorkingPrompt(action: .quit, stopping: [tab]))
        print("REA-1240 quit baseline: \(prompt.messageText) | \(prompt.informativeText)")
        #expect(prompt.informativeText.contains("1 tab will not reopen next time."))
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex])
    func initialHistoryScanRestoresDeferredNativeTabs(provider: CLIProvider) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("zsh")
        try "#!/bin/sh\nprintf 'NATIVE_READY\\n'\nwhile IFS= read -r line; do :; done\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let oldShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", shell.path, 1)
        defer {
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
        }
        let transcript = root.appendingPathComponent("native.jsonl")
        try Data("{\"fixture\":true}\n".utf8).write(to: transcript)
        let session = GrokSession(
            id: UUID().uuidString.lowercased(), cwd: root.path, summary: "Saved native conversation",
            createdAt: Date(), updatedAt: Date(), messageCount: 4, modelID: nil, agentName: nil,
            reasoningEffort: nil, directory: transcript, provider: provider)
        let gate = InitialHistoryScanGate()
        let store = SessionStore(
            root: root.appendingPathComponent("grok"), timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in
                await gate.wait()
                return .init(sessions: [session], cache: [:], loadError: nil)
            })
        defer { store.stop() }
        let suite = "NativeStartupRestorationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
        settings.executablePath = "/missing/grok"
        settings.isTabMessagingEnabled = false
        let entry = OpenTabsSnapshot.Entry(sessionID: session.nativeSessionID, cwd: root.path, provider: provider)
        settings.openTabs = .init(
            tabs: [entry], selectedSessionID: entry.sessionID, selectedCWD: root.path, selectedProvider: provider)
        let model = AppModel(
            settings: settings, store: store, presentError: { _ in }, panel: RightPanel(defaults: defaults),
            pairingStore: InMemoryRemotePairingStore(), providerInstallations: fixtureProviderInstallations(shell))
        defer { model.closeAllTabsAndWait() }
        #expect(store.sessions.isEmpty)
        await model.onAppear()
        #expect(model.tabs.isEmpty)
        #expect(settings.openTabs.tabs == [entry])
        await gate.release()
        for _ in 0..<200 {
            if model.tabs.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.sessions.count == 1)
        for _ in 0..<100 where model.selectedTab?.controller.remoteSnapshot().contains("NATIVE_READY") != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.selectedTab?.controller.remoteSnapshot().contains("NATIVE_READY") == true)
        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.sessionReference == session.reference)
        #expect(settings.openTabs.tabs.first?.provider == provider)
        #expect(settings.openTabs.tabs.first?.sessionID == session.nativeSessionID)
    }
}

private actor InitialHistoryScanGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}
