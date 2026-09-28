import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct ProviderLaunchAvailabilityTests {
    @Test(arguments: CLIProvider.allCases)
    func unprobedProviderCannotStartLocallyOrRemotely(provider: CLIProvider) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: provider)
        defer { fixture.cleanup() }
        let model = fixture.makeModel()
        defer { model.closeAllTabsAndWait() }

        #expect(model.newTab(in: fixture.root, provider: provider) == nil)
        #expect(model.tabs.isEmpty)
        #expect(RemoteCommands.startProblem(provider, model: model) != nil)
        let alerts = fixture.alerts
        let reply = await RemoteCommands.execute(
            .init(challenge: "test", sequence: 1, action: "new", provider: provider.rawValue), model: model)
        #expect(!reply.ok)
        #expect(model.tabs.isEmpty)
        #expect(fixture.alerts == alerts)
        let option = RemoteCommands.newSessionOptions(model).providers.first { $0.id == provider.rawValue }
        #expect(option?.problem != nil)
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex])
    func unprobedNativeHistoryCannotOpen(provider: CLIProvider) throws {
        let fixture = try LaunchAvailabilityFixture(provider: provider)
        defer { fixture.cleanup() }
        let model = fixture.makeModel()
        defer { model.closeAllTabsAndWait() }
        model.open(fixture.session)
        #expect(model.tabs.isEmpty)
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex])
    func startupDefersUnprobedNativeHistoryWithoutLosingSavedSelection(provider: CLIProvider) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: provider)
        defer { fixture.cleanup() }
        await fixture.store.reload()
        fixture.saveOpenTab()
        let saved = fixture.settings.openTabs
        let model = fixture.makeModel()
        defer { model.closeAllTabsAndWait() }
        await model.onAppear()
        #expect(model.tabs.isEmpty)
        #expect(fixture.settings.openTabs == saved)
    }

    @Test func refreshingRejectsNewAndRestartWithoutStoppingExistingWork() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let available = fixtureProviderInstallations(fixture.shell)
        let model = fixture.makeModel(installations: available, probe: { provider, _ in await gate.probe(provider) })
        defer { model.closeAllTabsAndWait() }
        model.open(fixture.session)
        let tab = try #require(model.selectedTab)
        let refresh = Task { await model.refreshProviderInstallations() }
        await gate.waitForCalls(CLIProvider.allCases.count)
        #expect(model.providerLaunchProblem(.claudeCode) != nil)
        #expect(model.newTab(in: fixture.root, provider: .claudeCode) == nil)
        model.restartTab(id: tab.id)
        #expect(model.selectedTab === tab)
        #expect(tab.controller.isRunning)
        let alerts = fixture.alerts
        model.open(fixture.session)
        #expect(model.selectedTab === tab)
        #expect(fixture.alerts == alerts)
        tab.terminateAndWait()
        let reply = await RemoteCommands.execute(
            .init(challenge: "test", sequence: 1, action: "restart", tabID: tab.id.uuidString), model: model)
        #expect(!reply.ok)
        #expect(fixture.alerts == alerts)
        #expect(model.selectedTab === tab)
        await gate.release(round: 1, results: [:])
        await refresh.value
        #expect(model.providerLaunchProblem(.claudeCode) == "Fixture CLI is missing.")
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex])
    func completedProbeRestoresDeferredNativeSelection(provider: CLIProvider) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: provider)
        defer { fixture.cleanup() }
        await fixture.store.reload()
        fixture.saveOpenTab()
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(probe: { provider, _ in await gate.probe(provider) })
        defer { model.closeAllTabsAndWait() }
        await model.onAppear()
        let refresh = Task { await model.refreshProviderInstallations() }
        await gate.waitForCalls(CLIProvider.allCases.count)
        #expect(model.tabs.isEmpty)
        #expect(fixture.settings.openTabs.tabs.count == 1)
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        await refresh.value
        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.sessionReference == fixture.session.reference)
        #expect(fixture.settings.openTabs.selectedSessionID == fixture.session.nativeSessionID)
    }

    @Test func staleSuccessfulProbeCannotOverrideNewMissingResultOrRestoreTabs() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        await fixture.store.reload()
        fixture.saveOpenTab()
        let saved = fixture.settings.openTabs
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(probe: { provider, _ in await gate.probe(provider) })
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        let first = Task { await model.refreshProviderInstallations() }
        await gate.waitForCalls(CLIProvider.allCases.count)
        let second = Task { await model.refreshProviderInstallations() }
        await gate.waitForCalls(CLIProvider.allCases.count * 2)
        await gate.release(round: 2, results: [:])
        await second.value
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        await first.value
        #expect(model.providerLaunchProblem(.claudeCode) == "Fixture CLI is missing.")
        #expect(model.tabs.isEmpty)
        #expect(fixture.settings.openTabs == saved)
    }

    @Test func reversedProbeCompletionCannotReorderSavedTabs() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let second = GrokSession(
            id: UUID().uuidString.lowercased(), cwd: fixture.root.path, summary: "Second saved tab",
            createdAt: Date(), updatedAt: Date(), messageCount: 2, modelID: nil, agentName: nil,
            reasoningEffort: nil, directory: fixture.session.directory, provider: .codex)
        let sessions = [fixture.session, second]
        let store = SessionStore(
            root: fixture.root.appendingPathComponent("mixed"), timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in .init(sessions: sessions, cache: [:], loadError: nil) })
        defer { store.stop() }
        await store.reload()
        let entries = sessions.map {
            OpenTabsSnapshot.Entry(sessionID: $0.nativeSessionID, cwd: $0.cwd, provider: $0.provider)
        }
        fixture.settings.openTabs = .init(
            tabs: entries, selectedSessionID: entries[0].sessionID, selectedCWD: entries[0].cwd,
            selectedProvider: entries[0].provider)
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(store: store, probe: { provider, _ in await gate.probe(provider) })
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        let refresh = Task { await model.refreshProviderInstallations() }
        await gate.waitForCalls(CLIProvider.allCases.count)
        let results = fixtureProviderInstallations(fixture.shell)
        await gate.release(round: 1, provider: .codex, results: results)
        // Drain runnable work while every other provider remains explicitly suspended.
        for _ in 0..<100 where model.providerInstallations[.codex] == nil { await Task.yield() }
        #expect(model.providerInstallations.isEmpty)
        #expect(model.tabs.isEmpty)
        // A history scan can call restoration during the same partial batch.
        model.restoreOpenTabs()
        #expect(model.tabs.isEmpty)
        await gate.release(round: 1, results: results)
        await refresh.value
        #expect(model.tabs.map(\.spec.provider) == [.claudeCode, .codex])
        #expect(model.selectedTab?.sessionReference == fixture.session.reference)
    }

    @Test(arguments: [true, false])
    func probesBeforeInitialHistoryKeepMixedSavedOrderWithoutBlockingMissingHistory(nativeExists: Bool) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let oldHome = ProcessInfo.processInfo.environment["GROK_HOME"]
        setenv("GROK_HOME", fixture.root.appendingPathComponent("grok-home").path, 1)
        defer {
            if let oldHome { setenv("GROK_HOME", oldHome, 1) } else { unsetenv("GROK_HOME") }
        }
        let grokID = UUID().uuidString
        let grokDirectory = GrokPaths.sessionDirectory(cwd: fixture.root.path, sessionID: grokID)
        try FileManager.default.createDirectory(at: grokDirectory, withIntermediateDirectories: true)
        let entries: [OpenTabsSnapshot.Entry] = [
            .init(sessionID: fixture.session.nativeSessionID, cwd: fixture.root.path, provider: .claudeCode),
            .init(sessionID: grokID, cwd: fixture.root.path, provider: .grokBuild),
        ]
        fixture.settings.openTabs = .init(
            tabs: entries, selectedSessionID: entries[0].sessionID, selectedCWD: entries[0].cwd,
            selectedProvider: entries[0].provider)
        let saved = fixture.settings.openTabs
        let history = HeldHistoryScan()
        let sessions = nativeExists ? [fixture.session] : []
        let store = SessionStore(
            root: fixture.root.appendingPathComponent("mixed"), timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in
                await history.wait()
                return .init(sessions: sessions, cache: [:], loadError: nil)
            })
        defer { store.stop() }
        let results = fixtureProviderInstallations(fixture.shell)
        let model = fixture.makeModel(store: store, probe: { provider, _ in results[provider]! })
        defer { model.closeAllTabsAndWait() }
        await model.onAppear()
        await model.refreshProviderInstallations()
        #expect(store.appliedScanSequence == 0)
        #expect(model.tabs.isEmpty)
        #expect(fixture.settings.openTabs == saved)
        await history.release()
        let expected: [CLIProvider] = nativeExists ? [.claudeCode, .grokBuild] : [.grokBuild]
        for _ in 0..<200 where store.appliedScanSequence == 0 || model.tabs.count != expected.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.tabs.map(\.spec.provider) == expected)
        #expect(fixture.settings.openTabs.tabs.count == 2)
        if nativeExists { #expect(model.selectedTab?.sessionReference == fixture.session.reference) }
    }

    @Test func cancelledProbeCannotMakeProviderAvailable() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(probe: { provider, _ in await gate.probe(provider) })
        let refresh = Task { await model.refreshProviderInstallations() }
        await gate.waitForCalls(CLIProvider.allCases.count)
        refresh.cancel()
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        await refresh.value
        #expect(model.providerLaunchProblem(.claudeCode) != nil)
        #expect(model.providerInstallations.isEmpty)
        #expect(model.checkingProviders.isEmpty)
    }

    @Test func resultWithoutExecutableIsNotAvailableEvenWithoutAnError() throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let model = fixture.makeModel(installations: [.claudeCode: .init(executable: nil, version: nil, problem: nil)])
        #expect(model.providerLaunchProblem(.claudeCode) != nil)
        #expect(RemoteCommands.startProblem(.claudeCode, model: model) != nil)
    }
}

/// Existing process fixtures explicitly supply results for their isolated executable.
/// Production models start unknown and must run the same probe-result gate.
func fixtureProviderInstallations(_ executable: URL) -> [CLIProvider: ProviderInstallation] {
    Dictionary(
        uniqueKeysWithValues: CLIProvider.allCases.map {
            ($0, ProviderInstallation(executable: executable, version: "fixture", problem: nil))
        })
}

private actor HeldProviderProbe {
    private var rounds: [CLIProvider: Int] = [:]
    private var pending: [(CLIProvider, Int, CheckedContinuation<ProviderInstallation, Never>)] = []
    private var callCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func probe(_ provider: CLIProvider) async -> ProviderInstallation {
        await withCheckedContinuation { continuation in
            let round = rounds[provider, default: 0] + 1
            rounds[provider] = round
            pending.append((provider, round, continuation))
            callCount += 1
            for waiter in waiters where callCount >= waiter.0 { waiter.1.resume() }
            waiters.removeAll { callCount >= $0.0 }
        }
    }

    func waitForCalls(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func release(round: Int, provider selected: CLIProvider? = nil, results: [CLIProvider: ProviderInstallation]) {
        for (provider, entryRound, continuation) in pending
        where entryRound == round && (selected == nil || provider == selected) {
            continuation.resume(
                returning: results[provider]
                    ?? .init(
                        executable: nil, version: nil, problem: "Fixture CLI is missing."))
        }
        pending.removeAll { $0.1 == round && (selected == nil || $0.0 == selected) }
    }
}

private actor HeldHistoryScan {
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

@MainActor
private final class LaunchAvailabilityFixture {
    let root: URL
    let shell: URL
    let session: GrokSession
    let settings: AppSettings
    let store: SessionStore
    let defaults: UserDefaults
    let suite: String
    var alerts = 0
    private let oldShell: String?

    init(provider: CLIProvider) throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        shell = root.appendingPathComponent("zsh")
        try "#!/bin/sh\nprintf 'FAKE_PROVIDER_READY\\n'\nwhile IFS= read -r line; do :; done\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        oldShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", shell.path, 1)
        let transcript = root.appendingPathComponent("native.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        session = GrokSession(
            id: UUID().uuidString.lowercased(), cwd: root.path, summary: "Saved native work",
            createdAt: Date(), updatedAt: Date(), messageCount: 2, modelID: nil, agentName: nil,
            reasoningEffort: nil, directory: transcript, provider: provider)
        let session = session
        store = SessionStore(
            root: root.appendingPathComponent("grok"), timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in .init(sessions: [session], cache: [:], loadError: nil) })
        suite = "ProviderLaunchAvailabilityTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
        settings.executablePath = shell.path
        settings.defaultDirectory = root.path
        settings.isTabMessagingEnabled = false
        settings.startsInWorktree = false
    }

    func makeModel(
        installations: [CLIProvider: ProviderInstallation] = [:], store: SessionStore? = nil,
        probe: AppModel.ProviderProbe? = nil
    ) -> AppModel {
        AppModel(
            settings: settings, store: store ?? self.store, presentError: { [weak self] _ in self?.alerts += 1 },
            panel: RightPanel(defaults: defaults), pairingStore: InMemoryRemotePairingStore(),
            providerInstallations: installations, providerProbe: probe)
    }

    func saveOpenTab() {
        let entry = OpenTabsSnapshot.Entry(
            sessionID: session.nativeSessionID, cwd: root.path, provider: session.provider)
        settings.openTabs = .init(
            tabs: [entry], selectedSessionID: entry.sessionID, selectedCWD: root.path,
            selectedProvider: session.provider)
    }

    func cleanup() {
        store.stop()
        if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
