import AppKit
import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
@MainActor
struct ProviderBoundaryTests {
    nonisolated static let providers: [CLIProvider] = [.claudeCode, .codex, .devin, .cursor, .kimi]

    @Test(arguments: providers)
    func silentProviderKeepsCloseWarningAndDoesNotClaimCompletion(provider: CLIProvider) async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let tab = try #require(fixture.model.newTab(in: fixture.root, provider: provider))
        #expect(tab.shouldWarnBeforeStopping)
        tab.noteTurnStarted()
        try await Task.sleep(for: TerminalTab.idleFallbackSilence + .milliseconds(350))
        #expect(tab.activity == .working)
        #expect(tab.shouldWarnBeforeStopping)
        #expect(!tab.hasUnseenActivity)
        var warnings = 0
        fixture.model.confirmStopWorking = { _ in
            warnings += 1
            return false
        }
        fixture.model.requestCloseTab(tab.id)
        #expect(warnings == 1)
        #expect(fixture.model.tabs.contains { $0.id == tab.id })
        #expect(tab.controller.isRunning)
        tab.terminateAndWait()
        #expect(!tab.shouldWarnBeforeStopping)
    }

    @Test(arguments: providers)
    func closingAnIdleProviderTabSaysItIsRunningNotWorking(provider: CLIProvider) throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let tab = try #require(fixture.model.newTab(in: fixture.root, provider: provider))
        #expect(tab.activity != .working)
        var prompts: [StopWorkingPrompt] = []
        fixture.model.confirmStopWorking = {
            prompts.append($0)
            return false
        }

        fixture.model.requestCloseTab(tab.id)

        let prompt = try #require(prompts.first)
        #expect(prompt.messageText == "\(provider.name) is still running.")
        #expect(prompt.informativeText == "\(provider.name) will stop.")
        #expect(
            StopWorkingPrompt(action: .quit, stopping: [tab])?.messageText
                == "\(provider.name) is still running. Quit anyway?")
        tab.terminateAndWait()
    }

    @Test(arguments: providers)
    func grokBridgeCannotDiscoverOrQueueToOtherProviders(provider: CLIProvider) async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let grok = try #require(fixture.model.newTab(in: fixture.root))
        let other = try #require(fixture.model.newTab(in: fixture.root, provider: provider))
        let bridge = TabBridge(model: fixture.model)
        let peer = BridgePeer(tabID: grok.id.uuidString)
        #expect(bridge.bridgeListTabs(asking: peer).map(\.tabID) == [grok.id.uuidString])
        #expect(!bridge.bridgeSend(from: peer, to: other.id.uuidString, message: "hello").ok)
        let ask = await bridge.bridgeAsk(from: peer, to: other.id.uuidString, question: "hello", timeout: 0.01)
        #expect(!ask.ok)
        #expect(ask.error?.contains("no open tab") == true)
        #expect(other.bridgeInbox.isEmpty)
        #expect(!other.hasUnseenActivity)
        #expect(
            !bridge.bridgeSend(from: .init(tabID: other.id.uuidString), to: grok.id.uuidString, message: "hello").ok)
    }

    @Test(arguments: providers)
    func remoteRestartDoesNotRequireGrokForOtherProviders(provider: CLIProvider) throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        fixture.model.settings.executablePath = "/missing/grok"
        let tab = try #require(fixture.model.newTab(in: fixture.root, provider: provider))
        tab.terminateAndWait()
        let reply = RemoteCommands.execute(
            RemoteRequest(challenge: "test", sequence: 1, action: "restart", tabID: tab.id.uuidString),
            model: fixture.model)
        #expect(reply.ok)
        let replacement = try #require(fixture.model.selectedTab)
        #expect(replacement.id != tab.id)
        #expect(reply.restartedTabID == replacement.id.uuidString)
        #expect(replacement.spec.provider == provider)
        #expect(replacement.controller.isRunning)
    }

    @Test(arguments: providers)
    func grokProjectArchiveLeavesOtherProvidersRunning(provider: CLIProvider) throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let grok = try #require(fixture.model.newTab(in: fixture.root))
        let other = try #require(fixture.model.newTab(in: fixture.root, provider: provider))
        other.noteTurnStarted()
        var warnings = 0
        fixture.model.confirmStopWorking = { _ in
            warnings += 1
            return false
        }
        let project = SidebarProject(
            id: fixture.root.path, name: "project", displayPath: fixture.root.path,
            cwd: fixture.root.path, sessions: [], updatedAt: .now)
        fixture.model.archive(project)
        #expect(warnings == 0)
        #expect(fixture.model.tabs.map(\.id) == [other.id])
        #expect(!grok.controller.isRunning)
        #expect(other.controller.isRunning)
    }

    @Test func kimiAccountSignInPassesNoKey() throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        fixture.model.saveKimiAPIKey("sk-unused")
        let tab = try #require(fixture.model.newTab(in: fixture.root, provider: .kimi))
        #expect(tab.spec.providerEnvironment.isEmpty)
    }

    @Test func kimiAPIKeySignInPassesTheKeyAndModelToEveryLaunch() throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        fixture.model.settings.kimiSignIn = .apiKey
        fixture.model.settings.kimiModel = "kimi-k2.7-code"
        #expect(fixture.model.saveKimiAPIKey("  sk-first  "))
        #expect(fixture.model.hasKimiAPIKey)
        let tab = try #require(fixture.model.newTab(in: fixture.root, provider: .kimi))
        #expect(tab.spec.providerEnvironment["KIMI_MODEL_API_KEY"] == "sk-first")
        #expect(tab.spec.providerEnvironment["KIMI_MODEL_NAME"] == "kimi-k2.7-code")
        #expect(fixture.settings.openTabs.tabs.isEmpty)

        fixture.model.saveKimiAPIKey("sk-second")
        fixture.model.restartTab(id: tab.id)
        let restarted = try #require(fixture.model.selectedTab)
        #expect(restarted.id != tab.id)
        #expect(restarted.spec.providerEnvironment["KIMI_MODEL_API_KEY"] == "sk-second")
    }

    @Test func kimiAPIKeySignInWithoutAKeyStartsNothing() throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        fixture.model.settings.kimiSignIn = .apiKey
        #expect(!fixture.model.hasKimiAPIKey)
        #expect(fixture.model.canSignIn(.claudeCode))
        #expect(fixture.errors.titles.isEmpty)
        // New Session asks this before it makes a worktree.
        #expect(!fixture.model.canSignIn(.kimi))
        fixture.errors.titles.removeAll()
        #expect(fixture.model.newTab(in: fixture.root, provider: .kimi) == nil)
        #expect(fixture.model.tabs.isEmpty)
        #expect(fixture.errors.titles == ["Kimi API key is missing"])

        fixture.model.saveKimiAPIKey("sk-test")
        fixture.model.removeKimiAPIKey()
        #expect(!fixture.model.hasKimiAPIKey)
    }
}

/// Every child is a local read loop, never an authenticated provider. The fake
/// login shell ignores its command string; these tests exercise tab boundaries.
@MainActor
private struct ProviderFixture {
    let root: URL
    let model: AppModel
    let settings: AppSettings
    let errors = PresentedErrors()
    private let suite: String
    private let defaults: UserDefaults
    private let oldShell: String?

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shell = root.appendingPathComponent("zsh")
        try "#!/bin/sh\nprintf 'READY\\n'\nwhile IFS= read -r line; do :; done\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        suite = "ProviderBoundaryTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults)
        settings.executablePath = shell.path
        let errors = errors
        model = AppModel(
            settings: settings, store: SessionStore(root: root.appendingPathComponent("sessions")),
            presentError: { errors.titles.append($0.localizedDescription) },
            panel: RightPanel(defaults: defaults),
            pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore())
        oldShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", shell.path, 1)
    }

    func cleanup() {
        model.closeAllTabsAndWait()
        if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class PresentedErrors {
    var titles: [String] = []
}
