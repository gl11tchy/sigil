import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct ProviderContinuityIntegrationTests {
    @Test func aValidatedLateCodexLinkAttachesLifecycleAndReportsItToThePhone() async throws {
        let fixture = try CodexBindingFixture()
        defer { fixture.cleanup() }
        defer { fixture.store.stop() }
        let tab = try await fixture.newTab()
        tab.noteTurnStarted()
        let native = UUID().uuidString.lowercased()
        try fixture.data(native).write(to: fixture.file(native))
        await fixture.store.reload()
        let session = try #require(fixture.store.sessions.first { $0.nativeSessionID == native })
        // The existing explicit user-link action validates this generated file;
        // no process inventory or cwd/time guess supplies identity.
        #expect(await fixture.model.linkCodexSession(session, to: tab.id))
        #expect(tab.nativeSessionID == native)
        #expect(tab.capabilities.lifecycle)
        #expect(tab.isWatchingForCompletion)
        let phone = RemoteCommands.snapshot(fixture.model).tabs.first { $0.id == tab.id.uuidString }
        #expect(phone?.capabilities?.lifecycle == true)
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex])
    func nativeConversationReopensRestoresAndKeepsItsProviderData(provider: CLIProvider) async throws {
        let fixture = try ContinuityFixture(provider: provider)
        defer { fixture.cleanup() }
        await fixture.store.reload()
        fixture.model.open(fixture.session)
        let tab = try #require(fixture.model.selectedTab)
        #expect(tab.spec.provider == provider)
        #expect(tab.nativeSessionID == fixture.session.nativeSessionID)
        #expect(tab.sessionID == fixture.session.id)
        #expect(tab.spec.arguments().contains(fixture.session.nativeSessionID))
        #expect(fixture.model.isOpen(fixture.session))
        #expect(fixture.settings.openTabs.tabs.first?.provider == provider)
        #expect(fixture.settings.openTabs.tabs.first?.sessionID == fixture.session.nativeSessionID)
        #expect(!fixture.model.canExportSelectedTranscript)
        #expect(!fixture.model.deleteConversation(fixture.session))
        #expect(FileManager.default.fileExists(atPath: fixture.session.directory.path))
        let snapshot = fixture.settings.openTabs
        fixture.model.closeAllTabsAndWait()
        fixture.settings.openTabs = snapshot
        let restored = fixture.makeModel()
        defer { restored.closeAllTabsAndWait() }
        restored.restoreOpenTabs()
        #expect(restored.tabs.count == 1)
        #expect(restored.selectedTab?.sessionReference == fixture.session.reference)
        restored.restoreOpenTabs()
        #expect(restored.tabs.count == 1)
        let chats = await RemoteCommands.execute(
            .init(challenge: "test", sequence: 1, action: "chats", text: "native work"), model: restored)
        #expect(chats.chats?.contains { $0.id == fixture.session.id && $0.provider == provider.rawValue } == true)
        let state = RemoteCommands.snapshot(restored)
        #expect(state.tabs.first?.sessionID == fixture.session.nativeSessionID)
        #expect(state.tabs.first?.capabilities?.export == false)
    }

    @Test func missingProjectPreservesNativeSavedReferenceWithoutStartingAnything() async throws {
        let fixture = try ContinuityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        await fixture.store.reload()
        let missing = fixture.root.appendingPathComponent("missing").path
        let entry = OpenTabsSnapshot.Entry(
            sessionID: fixture.session.nativeSessionID, cwd: missing, provider: .claudeCode)
        fixture.settings.openTabs = .init(
            tabs: [entry], selectedSessionID: entry.sessionID,
            selectedCWD: missing, selectedProvider: .claudeCode)
        fixture.model.restoreOpenTabs()
        #expect(fixture.model.tabs.isEmpty)
        #expect(fixture.settings.openTabs.tabs == [entry])
    }

    @Test func archivingAProjectWarnsBeforeStoppingNativeProviderWork() async throws {
        let fixture = try ContinuityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        await fixture.store.reload()
        fixture.model.open(fixture.session)
        let tab = try #require(fixture.model.selectedTab)
        tab.noteTurnStarted()
        var warned = false
        fixture.model.confirmStopWorking = { _ in
            warned = true
            return false
        }
        let project = try #require(
            SidebarOrganization.projects(from: [fixture.session], canonicalPath: GrokPaths.canonicalPath).first)
        fixture.model.archive(project)
        #expect(warned)
        #expect(tab.controller.isRunning)
        #expect(!fixture.model.isArchived(fixture.session))
    }
}

@MainActor
private final class ContinuityFixture {
    let root: URL
    let session: GrokSession
    let store: SessionStore
    let settings: AppSettings
    let defaults: UserDefaults
    let suite: String
    private let oldShell: String?
    lazy var model = makeModel()

    init(provider: CLIProvider) throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shell = root.appendingPathComponent("zsh")
        // Isolated process receipt, never invokes an installed authenticated CLI.
        try "#!/bin/sh\nprintf 'NATIVE_READY\\n'\nwhile IFS= read -r line; do printf 'INPUT:%s\\n' \"$line\"; done\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        oldShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", shell.path, 1)
        let transcript = root.appendingPathComponent("native.jsonl")
        try Data("{\"fixture\":true}\n".utf8).write(to: transcript)
        session = GrokSession(
            id: UUID().uuidString.lowercased(), cwd: root.path, summary: "native work",
            createdAt: Date(), updatedAt: Date(), messageCount: 4, modelID: nil, agentName: nil,
            reasoningEffort: nil, directory: transcript, provider: provider)
        let session = session
        store = SessionStore(
            root: root.appendingPathComponent("grok"), timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in .init(sessions: [session], cache: [:], loadError: nil) })
        suite = "ProviderContinuityIntegrationTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
        settings.executablePath = "/missing/grok"
        settings.showEmptySessions = true
    }

    func makeModel() -> AppModel {
        AppModel(
            settings: settings, store: store, presentError: { _ in }, panel: RightPanel(defaults: defaults),
            pairingStore: InMemoryRemotePairingStore(),
            providerInstallations: fixtureProviderInstallations(root.appendingPathComponent("zsh")))
    }

    func cleanup() {
        model.closeAllTabsAndWait()
        store.stop()
        if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
