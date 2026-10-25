import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct TaskLedgerIntegrationTests {
    @Test(arguments: CLIProvider.allCases)
    func taskIsDurableBeforeAnyProviderOutput(provider: CLIProvider) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: fixture.base.root, provider: provider))
        #expect(tab.spec.hostCommand().executable == fixture.shell)
        let taskID = try #require(model.taskID(for: tab))
        let saved = TaskLedgerStore(url: fixture.ledgerURL).read()
        #expect(saved.problem == nil)
        let entry = try #require(saved.ledger.entries.first)
        #expect(entry.taskID == taskID && entry.provider == provider)
        #expect(entry.workspacePath == GrokPaths.canonicalPath(fixture.base.root.path))
        #expect(entry.conversationID == (provider == .grokBuild ? tab.nativeSessionID : nil))
        let deadline = ContinuousClock.now + .seconds(3)
        while !tab.controller.bufferText().contains("LEDGER_PRESENT"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.controller.bufferText().contains("LEDGER_PRESENT"))
        #expect(!tab.controller.bufferText().contains("LEDGER_MISSING"))
        if provider != .grokBuild {
            tab.sessionTitle = "Pretend native id from a terminal title"
            model.recordStartedCodexSessions()
            #expect(model.taskLedger.entries.first?.conversationID == nil)
        }
    }

    @Test
    func aFailedDurableRegistrationStartsNoChildAndExposesTheProblem() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TaskLedgerStore(url: fixture.ledgerURL, beforeCommit: { _ in throw FixtureFailure() })
        var errors: [Error] = []
        let model = fixture.model(ledger: store, presentError: { errors.append($0) })
        defer { model.closeAllTabsAndWait() }
        #expect(model.newTab(in: fixture.base.root, provider: .codex) == nil)
        #expect(model.tabs.isEmpty && model.taskLedger.entries.isEmpty)
        #expect(model.taskLedgerProblem != nil && errors.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
    }

    @Test
    func restartingAndRelaunchingKeepTheTaskAndLegacyPreferences() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let original = try #require(model.newTab(in: fixture.base.root))
        let taskID = try #require(model.taskID(for: original))
        let sessionID = try #require(original.nativeSessionID)
        try fixture.base.createSession(id: sessionID, cwd: fixture.base.root)
        model.renameTab(original, to: "Saved task name")
        model.restartTab(id: original.id)
        let replacement = try #require(model.selectedTab)
        #expect(replacement.id != original.id)
        #expect(model.taskID(for: replacement) == taskID)
        let snapshot = fixture.base.settings.openTabs
        #expect(snapshot.tabs.first?.taskID == taskID)
        model.closeAllTabsAndWait()
        fixture.base.settings.openTabs = snapshot
        let restored = fixture.model()
        defer { restored.closeAllTabsAndWait() }
        restored.restoreOpenTabs()
        let reopened = try #require(restored.tabs.first)
        #expect(restored.taskID(for: reopened) == taskID)
        #expect(restored.taskLedger.entries.map(\.taskID) == [taskID])
        #expect(fixture.base.settings.isSigilConversation(sessionID))
        #expect(
            fixture.base.settings.conversationNames.contains {
                $0.sessionID == sessionID && $0.name == "Saved task name"
            })
    }

    @Test
    func nativeRecoveryActionPreservesPostMigrationTasksBeforeAnotherLaunch() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.model()
        let original = try #require(first.newTab(in: fixture.base.root))
        let taskID = try #require(first.taskID(for: original))
        first.closeAllTabsAndWait()
        let corrupt = Data("corrupt task ledger fixture".utf8)
        try corrupt.write(to: fixture.ledgerURL)
        var presented: Error?
        let next = fixture.model(presentError: { presented = $0 })
        defer { next.closeAllTabsAndWait() }
        #expect(next.newTab(in: fixture.base.root) == nil)
        #expect(next.tabs.isEmpty && next.taskLedgerProblem != nil)
        #expect(try Data(contentsOf: fixture.ledgerURL) == corrupt)
        let recovery = try #require(presented as? any RecoverableError)
        #expect(recovery.recoveryOptions == ["Recover Saved Tasks", "Cancel"])
        #expect(!recovery.attemptRecovery(optionIndex: 1))
        #expect(try Data(contentsOf: fixture.ledgerURL) == corrupt)
        #expect(recovery.attemptRecovery(optionIndex: 0))
        let tab = try #require(next.newTab(in: fixture.base.root))
        #expect(next.taskID(for: tab) != taskID)
        #expect(next.taskLedger.entries.contains { $0.taskID == taskID })
        #expect(next.taskLedger.entries.count == 2)
    }

    @Test
    func aValidatedCodexLinkAnnotatesTheExistingTask() async throws {
        let fixture = try CodexBindingFixture()
        defer { fixture.cleanup() }
        defer { fixture.store.stop() }
        let tab = try await fixture.newTab()
        let taskID = try #require(fixture.model.taskID(for: tab))
        #expect(fixture.model.taskLedger.entries.first?.conversationID == nil)
        let native = UUID().uuidString.lowercased()
        try fixture.data(native).write(to: fixture.file(native))
        await fixture.store.reload()
        let session = try #require(fixture.store.sessions.first { $0.nativeSessionID == native })
        #expect(await fixture.model.linkCodexSession(session, to: tab.id))
        #expect(fixture.model.taskID(for: tab) == taskID)
        #expect(fixture.model.taskLedger.entries.first?.conversationID == native)
    }

    @Test
    func twoAppModelsCanRunProcessesForOneSavedTask() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let a = fixture.model()
        defer { a.closeAllTabsAndWait() }
        let first = try #require(a.newTab(in: fixture.base.root))
        let taskID = try #require(a.taskID(for: first))
        try fixture.base.createSession(id: try #require(first.nativeSessionID), cwd: fixture.base.root)
        let b = fixture.model()
        defer { b.closeAllTabsAndWait() }
        b.restoreOpenTabs()
        let second = try #require(b.tabs.first)
        #expect(first.id != second.id)
        #expect(b.taskID(for: second) == taskID)
        #expect(a.taskID(for: first) == taskID)
        #expect(TaskLedgerStore(url: fixture.ledgerURL).read().ledger.entries.map(\.taskID) == [taskID])
    }

    @Test
    func claudeWaitsForItsExactValidatedHistoryIdentity() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let historyRoot = try fixture.base.directory("generated-claude-projects")
        let history = SessionStore(
            root: fixture.base.store.root, timing: SessionStoreTiming(), nativeRoots: [(.claudeCode, historyRoot)])
        defer { history.stop() }
        let model = fixture.model(history: history)
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: fixture.base.root, provider: .claudeCode))
        let taskID = try #require(model.taskID(for: tab))
        let native = try #require(tab.nativeSessionID)
        model.renameTab(tab, to: "Pending Claude task name")
        #expect(model.taskLedger.entries.first?.title == "Pending Claude task name")
        #expect(model.taskLedger.entries.first?.conversationID == nil)
        let project = historyRoot.appendingPathComponent("generated")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func write(_ id: String) throws {
            let record: [String: Any] = [
                "type": "user", "sessionId": id, "cwd": fixture.base.root.path,
                "version": "2.1.283", "timestamp": "2026-10-01T00:00:00Z",
                "message": ["content": "Generated task fixture"],
            ]
            try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(
                to: project.appendingPathComponent(id + ".jsonl"))
        }
        try write(UUID().uuidString.lowercased())
        await history.reload()
        _ = await history.validatedSessions(for: history.sessions)
        model.reconcileTaskLedger()
        #expect(model.taskLedger.entries.first?.conversationID == nil)
        try write(native)
        await history.reload()
        _ = await history.validatedSessions(for: history.sessions)
        #expect(history.sessions.contains { $0.nativeSessionID == native && $0.isHistoryValidated })
        model.reconcileTaskLedger()
        #expect(model.taskID(for: tab) == taskID)
        #expect(model.taskLedger.entries.first?.conversationID == native)
        #expect(model.taskLedger.entries.first?.title == "Pending Claude task name")
    }

    private struct FixtureFailure: Error {}

    @MainActor
    private final class Fixture {
        let base: ModelFixture
        let shell: URL
        let ledgerURL: URL
        private let oldEnvironment: [String: String?]

        init() throws {
            base = try ModelFixture()
            base.settings.isTabMessagingEnabled = false
            ledgerURL = base.root.appendingPathComponent("ledger/tasks.json")
            shell = base.root.appendingPathComponent("zsh")
            let script = """
                #!/bin/sh
                if [ -s '\(ledgerURL.path)' ]; then printf 'LEDGER_PRESENT\\n'; else printf 'LEDGER_MISSING\\n'; fi
                while IFS= read -r line; do :; done
                """
            try script.write(to: shell, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
            let codexHome = try base.directory("isolated-codex")
            let claudeHome = try base.directory("isolated-claude")
            oldEnvironment = Dictionary(
                uniqueKeysWithValues: ["SHELL", "CODEX_HOME", "CLAUDE_CONFIG_DIR"].map {
                    ($0, ProcessInfo.processInfo.environment[$0])
                })
            setenv("SHELL", shell.path, 1)
            setenv("CODEX_HOME", codexHome.path, 1)
            setenv("CLAUDE_CONFIG_DIR", claudeHome.path, 1)
        }

        func model(
            ledger: TaskLedgerStore? = nil, history: SessionStore? = nil,
            presentError: @escaping (Error) -> Void = { _ in }
        ) -> AppModel {
            AppModel(
                settings: base.settings, store: history ?? base.store, presentError: presentError,
                panel: RightPanel(defaults: base.defaults, notesStore: ConversationNotesStore(root: base.notesRoot)),
                pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(),
                providerInstallations: fixtureProviderInstallations(base.executable),
                taskLedgerStore: ledger ?? TaskLedgerStore(url: ledgerURL))
        }

        func cleanup() {
            for (key, value) in oldEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            base.cleanup()
        }
    }
}
