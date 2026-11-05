import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct NativeStartupRestorationTests {
    @Test
    func anUnavailableSavedCodexEntryRemainsASavedIntentWithoutOpeningATab() async throws {
        _ = NSApplication.shared
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        fixture.settings.isTabMessagingEnabled = false
        let entry = OpenTabsSnapshot.Entry(
            sessionID: UUID().uuidString.lowercased(), cwd: fixture.root.path, provider: .codex)
        let transcript = fixture.root.appendingPathComponent("generated-codex.jsonl")
        try Data("{\"fixture\":true}\n".utf8).write(to: transcript)
        let session = GrokSession(
            id: entry.sessionID, cwd: entry.cwd, summary: "Unavailable saved Codex",
            createdAt: Date(), updatedAt: Date(), messageCount: 2, modelID: nil, agentName: nil,
            reasoningEffort: nil, directory: transcript, provider: .codex)
        let store = SessionStore(
            root: fixture.store.root, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in .init(sessions: [session], cache: [:], loadError: nil) })
        defer { store.stop() }
        await store.reload()
        #expect(store.appliedScanSequence > 0 && store.sessions.first?.isHistoryValidated == true)
        fixture.settings.openTabs = .init(
            tabs: [entry], selectedSessionID: entry.sessionID, selectedCWD: entry.cwd, selectedProvider: .codex)
        var installations = fixtureProviderInstallations(fixture.executable)
        let problem = "Synthetic Codex executable is unavailable."
        installations[.codex] = .init(executable: nil, version: nil, problem: problem)
        let model = AppModel(
            settings: fixture.settings, store: store, presentError: { _ in },
            panel: RightPanel(defaults: fixture.defaults, notesStore: ConversationNotesStore(root: fixture.notesRoot)),
            pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(),
            providerInstallations: installations)
        defer { model.closeAllTabsAndWait() }

        model.restoreOpenTabs()

        #expect(model.tabs.isEmpty)
        #expect(fixture.settings.openTabs.tabs == [entry])
        #expect(model.providerLaunchProblem(.codex) == problem)
        #expect(model.unrestoredTabs.map(\.entry) == [entry])
        #expect(model.unrestoredTabs.first?.reason == .providerUnavailable(problem))
        #expect(model.unrestoredTabs.first?.title == session.title)
        fixture.settings.conversationNames = [.init(sessionID: session.id, cwd: session.cwd, name: "My saved chat")]
        #expect(model.unrestoredTabs.first?.title == "My saved chat")
        print(
            "REA-1240 saved-intent baseline: one Codex reference retained, zero tabs, synthetic unavailable probe message"
        )
    }

    @Test
    func quittingAnUnsavableDevinTabExplainsThatItWillNotReopen() throws {
        _ = NSApplication.shared
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let model = fixture.model(fixture.base.store)
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: fixture.base.root, provider: .devin))
        #expect(tab.nativeSessionID == nil)
        #expect(tab.spec.hostCommand().executable == fixture.shell)
        let prompt = try #require(StopWorkingPrompt(action: .quit, stopping: [tab]))
        print("REA-1240 quit baseline: \(prompt.messageText) | \(prompt.informativeText)")
        #expect(prompt.informativeText.contains("1 tab will not reopen next time."))
        tab.terminateAndWait()
        let ended = try #require(StopWorkingPrompt(action: .quit, stopping: [tab]))
        #expect(ended.informativeText == "1 tab will not reopen next time.")
        #expect(!ended.messageText.contains("still running"))
        #expect(StopWorkingPrompt(action: .closeTab, stopping: [tab]) == nil)
    }

    @Test
    func quitWarningsCountUnsavableTabsWithoutInventingWork() {
        let ended = StopWorkingPrompt(action: .quit, working: 0, running: [], unsavable: 2)
        #expect(ended.messageText == "These tabs cannot reopen. Quit anyway?")
        #expect(ended.informativeText == "2 tabs will not reopen next time.")
        let panel = StopWorkingPrompt(action: .quit, working: 0, running: [], panelJob: true, unsavable: 1)
        #expect(panel.informativeText == "The command will stop. 1 tab will not reopen next time.")
        let close = StopWorkingPrompt(action: .closeTab, working: 1, running: [], unsavable: 1)
        #expect(close.informativeText == "The response in progress will stop.")
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
            settings: settings, store: store, presentError: { _ in },
            panel: RightPanel(
                defaults: defaults, notesStore: ConversationNotesStore(root: root.appendingPathComponent("notes"))),
            pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(),
            providerInstallations: fixtureProviderInstallations(shell))
        defer { model.closeAllTabsAndWait() }
        #expect(store.sessions.isEmpty)
        await model.onAppear()
        #expect(model.tabs.isEmpty)
        #expect(settings.openTabs.tabs == [entry])
        #expect(model.unrestoredTabs.first?.reason == .historyLoading)
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
        #expect(model.unrestoredTabs.isEmpty)
    }

    @Test(arguments: [false, true])
    func missingFolderAndRemovedHistoryHaveDifferentReasons(removeFolder: Bool) async throws {
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let project = try fixture.base.directory("project")
        let session = try fixture.session(cwd: project)
        let store = fixture.store([session])
        defer { store.stop() }
        await store.reload()
        let entries = fixture.save([session])
        if removeFolder {
            try FileManager.default.removeItem(at: project)
        } else {
            try FileManager.default.removeItem(at: session.directory)
        }
        let model = fixture.model(store)
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        #expect(model.tabs.isEmpty)
        #expect(model.unrestoredTabs.map(\.entry) == entries)
        #expect(model.unrestoredTabs.first?.reason == (removeFolder ? .folderMissing : .historyMissing))
        #expect(fixture.base.settings.openTabs.tabs == entries)
    }

    @Test(arguments: [false, true])
    func failedHistoryReadIsNotClaimedMissing(retainsUnverifiedRow: Bool) async throws {
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session(validated: false)
        let displayed = retainsUnverifiedRow ? [session] : []
        let store = SessionStore(
            root: fixture.base.store.root, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in
                .init(sessions: displayed, cache: [:], loadError: "Synthetic history read failed.")
            })
        defer { store.stop() }
        await store.reload()
        let entries = fixture.save([session])
        let model = fixture.model(store)
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        #expect(model.unrestoredTabs.first?.reason == .historyUnavailable("Synthetic history read failed."))
        #expect(fixture.base.settings.openTabs.tabs == entries)
        #expect(FileManager.default.fileExists(atPath: session.directory.path))
    }

    @Test
    func retryRepairsProviderAndFolderWithoutChangingSavedOrder() async throws {
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let project = try fixture.base.directory("temporarily-missing")
        let sessions = [try fixture.session(provider: .claudeCode, cwd: project), try fixture.session()]
        let store = fixture.store(sessions)
        defer { store.stop() }
        await store.reload()
        let entries = fixture.save(sessions)
        try FileManager.default.removeItem(at: project)
        let available = fixtureProviderInstallations(fixture.shell)
        var initial = available
        initial[.codex] = .init(executable: nil, version: nil, problem: "Synthetic missing Codex.")
        let model = fixture.model(store, installations: initial, probe: { provider, _ in available[provider]! })
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        #expect(model.unrestoredTabs.map(\.entry) == entries)
        let staleRow = try #require(model.unrestoredTabs.first)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        await model.retryUnrestoredTabs()
        #expect(model.tabs.map(\.sessionReference) == sessions.map { Optional($0.reference) })
        #expect(model.selectedTab?.sessionReference == sessions[0].reference)
        #expect(model.unrestoredTabs.isEmpty)
        #expect(fixture.base.settings.openTabs.tabs.map(\.sessionID) == entries.map(\.sessionID))
        model.forgetUnrestoredTab(staleRow)
        model.restoreOpenTabs()
        #expect(model.tabs.count == 2)
        #expect(fixture.base.settings.openTabs.tabs.map(\.sessionID) == entries.map(\.sessionID))
    }

    @Test(arguments: [false, true])
    func forgetDuringRetryCannotResurrectSavedIntent(whileReadingHistory: Bool) async throws {
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let historyGate = InitialHistoryScanGate()
        defer { Task { await historyGate.release() } }
        let store = SessionStore(
            root: fixture.base.store.root, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in
                if whileReadingHistory { await historyGate.wait() }
                return .init(sessions: [session], cache: [:], loadError: nil)
            })
        defer { store.stop() }
        if !whileReadingHistory { await store.reload() }
        let entries = fixture.save([session])
        let probeGate = SavedTabGate<ProviderInstallation>()
        defer {
            Task { await probeGate.finish(.init(executable: nil, version: nil, problem: "Fixture closed.")) }
        }
        let available = fixtureProviderInstallations(fixture.shell)
        var unavailable = available
        unavailable[.codex] = .init(executable: nil, version: nil, problem: "Synthetic unavailable Codex.")
        let model = fixture.model(store, installations: unavailable, probe: { _, _ in await probeGate.probe() })
        defer { model.closeAllTabsAndWait() }
        model.panel.setNotes("Keep these notes", forSessionID: session.id, cwd: session.cwd)
        model.panel.notesStore.flushNow()
        let before = try fixture.fileContents()
        let names = [ConversationName(sessionID: session.id, cwd: session.cwd, name: "Keep this name")]
        fixture.base.settings.conversationNames = names
        model.restoreOpenTabs()
        let retry = Task { await model.retryUnrestoredTabs() }
        try await probeGate.waitForCalls(1)
        #expect(model.unrestoredTabs.first?.reason == .checkingProviders)
        if whileReadingHistory {
            await probeGate.release(1, result: available[.codex]!)
            let deadline = ContinuousClock.now + .seconds(5)
            while !store.isLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(store.isLoading)
            #expect(model.unrestoredTabs.first?.reason == .historyLoading)
        }
        let row = try #require(model.unrestoredTabs.first)
        #expect(row.entry == entries[0])
        model.forgetUnrestoredTab(row)
        #expect(model.unrestoredTabs.isEmpty)
        #expect(fixture.base.settings.openTabs.tabs.isEmpty)
        #expect(fixture.base.settings.openTabs.selectedSessionID == nil)
        if whileReadingHistory {
            await historyGate.release()
        } else {
            await probeGate.release(1, result: available[.codex]!)
        }
        await retry.value
        model.restoreOpenTabs()
        model.forgetUnrestoredTab(row)  // Stale UI row is harmless too.
        #expect(model.tabs.isEmpty && model.unrestoredTabs.isEmpty)
        #expect(fixture.base.settings.openTabs.tabs.isEmpty)
        #expect(fixture.base.settings.conversationNames == names)
        #expect(try fixture.fileContents() == before)
        let relaunched = fixture.model(store)
        defer { relaunched.closeAllTabsAndWait() }
        relaunched.restoreOpenTabs()
        #expect(relaunched.tabs.isEmpty && relaunched.unrestoredTabs.isEmpty)
        #expect(fixture.base.settings.openTabs.tabs.isEmpty)
    }

    @Test
    func olderRetryCannotClearNewerRetryOrPublishItsProviderResult() async throws {
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let sessions = [try fixture.session(), try fixture.session()]
        let store = fixture.store(sessions)
        defer { store.stop() }
        await store.reload()
        let entries = fixture.save(sessions)
        let gate = SavedTabGate<ProviderInstallation>()
        defer {
            Task { await gate.finish(.init(executable: nil, version: nil, problem: "Fixture closed.")) }
        }
        let model = fixture.model(store, installations: [:], probe: { _, _ in await gate.probe() })
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        let first = Task { await model.retryUnrestoredTabs() }
        try await gate.waitForCalls(1)
        let second = Task { await model.retryUnrestoredTabs() }
        try await gate.waitForCalls(2)
        await gate.release(1, result: fixtureProviderInstallations(fixture.shell)[.codex]!)
        await first.value
        #expect(model.tabs.isEmpty)
        #expect(model.unrestoredTabs.map(\.entry) == entries)
        #expect(model.unrestoredTabs.allSatisfy { $0.reason == .checkingProviders })
        await gate.release(2, result: .init(executable: nil, version: nil, problem: "Newer check is missing."))
        await second.value
        #expect(model.tabs.isEmpty)
        #expect(model.unrestoredTabs.allSatisfy { $0.reason == .providerUnavailable("Newer check is missing.") })
    }

    @Test
    func olderHistoryRetryCannotReplaceNewerMissingHistory() async throws {
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let history = SavedTabGate<SessionScanner.Result>()
        defer { Task { await history.finish(.init(sessions: [], cache: [:], loadError: "Fixture closed.")) } }
        let store = SessionStore(
            root: fixture.base.store.root, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in await history.probe() })
        defer { store.stop() }
        let initialScan = Task { await store.reload() }
        try await history.waitForCalls(1)
        await history.release(1, result: .init(sessions: [session], cache: [:], loadError: nil))
        await initialScan.value
        fixture.save([session])
        let available = fixtureProviderInstallations(fixture.shell)
        var initial = available
        initial[.codex] = .init(executable: nil, version: nil, problem: "Synthetic unavailable Codex.")
        let model = fixture.model(store, installations: initial, probe: { provider, _ in available[provider]! })
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        let first = Task { await model.retryUnrestoredTabs() }
        try await history.waitForCalls(2)
        let second = Task { await model.retryUnrestoredTabs() }
        try await history.waitForCalls(3)
        await history.release(3, result: .init(sessions: [], cache: [:], loadError: nil))
        await second.value
        #expect(model.tabs.isEmpty)
        #expect(model.unrestoredTabs.first?.reason == .historyLoading)
        await history.release(2, result: .init(sessions: [session], cache: [:], loadError: nil))
        await first.value
        #expect(store.sessions.isEmpty)
        #expect(model.tabs.isEmpty)
        #expect(model.unrestoredTabs.first?.reason == .historyMissing)
    }

    @Test
    func forgettingEarlierEntriesKeepsLaterRetryBehindAlreadyRestoredTabs() async throws {
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let projects = try (0..<5).map { try fixture.base.directory("project-\($0)") }
        let sessions = try projects.map { try fixture.session(cwd: $0) }
        let store = fixture.store(sessions)
        defer { store.stop() }
        await store.reload()
        fixture.save(sessions)
        for index in [1, 2, 4] { try FileManager.default.removeItem(at: projects[index]) }
        let available = fixtureProviderInstallations(fixture.shell)
        let model = fixture.model(store, probe: { provider, _ in available[provider]! })
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        #expect(model.tabs.map(\.sessionReference) == [sessions[0].reference, sessions[3].reference])
        for session in sessions[1...2] {
            model.forgetUnrestoredTab(
                try #require(model.unrestoredTabs.first { $0.entry.sessionID == session.nativeSessionID }))
        }
        try FileManager.default.createDirectory(at: projects[4], withIntermediateDirectories: true)
        await model.retryUnrestoredTabs()
        #expect(
            model.tabs.map(\.sessionReference) == [sessions[0].reference, sessions[3].reference, sessions[4].reference])
        #expect(
            fixture.base.settings.openTabs.tabs.map(\.sessionID) == [
                sessions[0].nativeSessionID, sessions[3].nativeSessionID, sessions[4].nativeSessionID,
            ])
    }

    @Test
    func forgetKeepsOtherProvidersAndFoldersWithTheSameRawID() throws {
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let id = UUID().uuidString.lowercased()
        let entries: [OpenTabsSnapshot.Entry] = [
            .init(sessionID: id, cwd: fixture.base.root.path, provider: .codex),
            .init(sessionID: id, cwd: fixture.base.root.path, provider: .claudeCode),
            .init(
                sessionID: id, cwd: fixture.base.root.appendingPathComponent("another-folder").path, provider: .codex),
            .init(sessionID: id, cwd: fixture.base.root.path + "/.", provider: .codex),
            .init(sessionID: id, cwd: fixture.base.root.path, provider: .codex),
        ]
        fixture.base.settings.openTabs = .init(
            tabs: entries, selectedSessionID: id, selectedCWD: entries[1].cwd, selectedProvider: .claudeCode)
        let model = fixture.model(fixture.base.store)
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        let rows = model.unrestoredTabs
        #expect(rows.map(\.entry) == entries)
        #expect(Set(rows.map(\.id)).count == entries.count)
        let row = try #require(model.unrestoredTabs.first)
        model.forgetUnrestoredTab(row)
        #expect(model.unrestoredTabs.map(\.entry) == Array(entries[1...2]))
        #expect(fixture.base.settings.openTabs.tabs == Array(entries[1...2]))
        #expect(model.unrestoredTabs.map(\.id) == Array(rows[1...2]).map(\.id))
        #expect(fixture.base.settings.openTabs.selectedProvider == .claudeCode)
    }

    @Test
    func legacyProviderDefaultAndEveryDeferredEntryAreRetained() throws {
        let fixture = try SavedTabsFixture()
        defer { fixture.cleanup() }
        let rows = (0..<513).map { ["sessionID": "legacy-\($0)", "cwd": fixture.base.root.path] }
        let snapshot = try JSONDecoder().decode(
            OpenTabsSnapshot.self, from: JSONSerialization.data(withJSONObject: ["tabs": rows]))
        #expect(snapshot.tabs.allSatisfy { $0.provider == .grokBuild })
        fixture.base.settings.openTabs = snapshot
        var initial = fixtureProviderInstallations(fixture.shell)
        initial[.grokBuild] = .init(executable: nil, version: nil, problem: "Synthetic missing Grok.")
        let model = fixture.model(fixture.base.store, installations: initial)
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        #expect(model.unrestoredTabs.map(\.entry) == snapshot.tabs)
        #expect(Set(model.unrestoredTabs.map(\.id)).count == 513)
        model.forgetUnrestoredTab(try #require(model.unrestoredTabs.first))
        #expect(model.unrestoredTabs.count == 512)
        #expect(fixture.base.settings.openTabs.tabs == Array(snapshot.tabs.dropFirst()))
    }
}

@MainActor
private final class SavedTabsFixture {
    let base: ModelFixture
    let shell: URL
    private let oldEnvironment: [String: String?]

    init() throws {
        base = try ModelFixture(script: "#!/bin/sh\nwhile IFS= read -r line; do :; done\n")
        shell = base.root.appendingPathComponent("zsh")
        try FileManager.default.copyItem(at: base.executable, to: shell)
        oldEnvironment = Dictionary(
            uniqueKeysWithValues: ["SHELL", "HOME", "CFFIXED_USER_HOME", "ZDOTDIR", "CODEX_HOME", "CLAUDE_CONFIG_DIR"]
                .map {
                    ($0, ProcessInfo.processInfo.environment[$0])
                })
        setenv("SHELL", shell.path, 1)
        for key in ["HOME", "CFFIXED_USER_HOME", "ZDOTDIR"] { setenv(key, base.root.path, 1) }
        setenv("CODEX_HOME", base.root.appendingPathComponent("codex-home").path, 1)
        setenv("CLAUDE_CONFIG_DIR", base.root.appendingPathComponent("claude-home").path, 1)
        base.settings.isTabMessagingEnabled = false
    }

    func cleanup() {
        for (key, value) in oldEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        base.cleanup()
    }

    func session(provider: CLIProvider = .codex, cwd: URL? = nil, validated: Bool = true) throws -> GrokSession {
        let file = base.root.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data("{\"generated\":true}\n".utf8).write(to: file)
        return GrokSession(
            id: UUID().uuidString.lowercased(), cwd: (cwd ?? base.root).path, summary: "Generated saved chat",
            createdAt: .now, updatedAt: .now, messageCount: 2, modelID: nil, agentName: nil,
            reasoningEffort: nil, directory: file, provider: provider, isHistoryValidated: validated)
    }

    func store(_ sessions: [GrokSession]) -> SessionStore {
        SessionStore(
            root: base.store.root, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in .init(sessions: sessions, cache: [:], loadError: nil) })
    }

    @discardableResult func save(_ sessions: [GrokSession]) -> [OpenTabsSnapshot.Entry] {
        let entries = sessions.map {
            OpenTabsSnapshot.Entry(sessionID: $0.nativeSessionID, cwd: $0.cwd, provider: $0.provider)
        }
        base.settings.openTabs = .init(
            tabs: entries, selectedSessionID: entries.first?.sessionID, selectedCWD: entries.first?.cwd,
            selectedProvider: entries.first?.provider)
        return entries
    }

    func model(
        _ store: SessionStore, installations: [CLIProvider: ProviderInstallation]? = nil,
        probe: AppModel.ProviderProbe? = nil
    ) -> AppModel {
        AppModel(
            settings: base.settings, store: store, presentError: { _ in },
            panel: RightPanel(defaults: base.defaults, notesStore: ConversationNotesStore(root: base.notesRoot)),
            pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(),
            providerInstallations: installations ?? fixtureProviderInstallations(shell), providerProbe: probe)
    }

    func fileContents() throws -> [String: Data] {
        let enumerator = try #require(
            FileManager.default.enumerator(at: base.root, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files[url.path] = try Data(contentsOf: url)
        }
        return files
    }
}

private struct SavedTabGateTimeout: Error {}

private actor SavedTabGate<Value: Sendable> {
    private var calls = 0
    private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
    private var finished: Value?

    func probe() async -> Value {
        if let finished { return finished }
        return await withCheckedContinuation { continuation in
            calls += 1
            pending[calls] = continuation
        }
    }

    func waitForCalls(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while calls < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls >= count, "Expected a controlled fixture request before the bounded deadline.")
        if calls < count { throw SavedTabGateTimeout() }
    }

    func release(_ call: Int, result: Value) {
        pending.removeValue(forKey: call)?.resume(returning: result)
    }

    func finish(_ result: Value) {
        finished = result
        let waiting = Array(pending.values)
        pending.removeAll()
        for continuation in waiting { continuation.resume(returning: result) }
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
