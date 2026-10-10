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
        tab.controller.onUserSubmit?()
        try await Task.sleep(for: .milliseconds(1550))
        #expect(tab.activity == .unknown)
        #expect(tab.workingSince == nil)
        #expect(tab.lastSubmittedAt != nil)
        #expect(!tab.capabilities.lifecycle)
        #expect(!tab.isWatchingForCompletion)
        #expect(tab.shouldWarnBeforeStopping)
        #expect(!tab.hasUnseenActivity)
        let project = SidebarProject(
            id: fixture.root.path, name: "project", displayPath: fixture.root.path,
            cwd: fixture.root.path, sessions: [], updatedAt: .now)
        #expect(!fixture.model.isWorking(project))
        #expect(RemoteCommands.snapshot(fixture.model, terminal: false).tabs.first?.status == "unknown")
        #expect(
            StopWorkingPrompt(action: .quit, stopping: [tab])?.messageText
                == "\(provider.name) is still running. Quit anyway?")
        var warnings = 0
        fixture.model.confirmStopWorking = { prompt in
            warnings += 1
            #expect(prompt.messageText == "\(provider.name) is still running.")
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
    func remoteRestartDoesNotRequireGrokForOtherProviders(provider: CLIProvider) async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        fixture.model.settings.executablePath = "/missing/grok"
        let tab = try #require(fixture.model.newTab(in: fixture.root, provider: provider))
        tab.terminateAndWait()
        let reply = await RemoteCommands.execute(
            RemoteRequest(challenge: "test", sequence: 1, action: "restart", tabID: tab.id.uuidString),
            model: fixture.model)
        if provider == .codex {
            #expect(!reply.ok)
            #expect(fixture.model.selectedTab?.id == tab.id)
            #expect(reply.error?.contains("session ID is not known") == true)
            return
        }
        #expect(reply.ok)
        let replacement = try #require(fixture.model.selectedTab)
        #expect(replacement.id != tab.id)
        #expect(reply.restartedTabID == replacement.id.uuidString)
        #expect(replacement.spec.provider == provider)
        #expect(replacement.controller.isRunning)
    }

    @Test(arguments: providers)
    func remoteNewStartsTheChosenProviderWithoutGrok(provider: CLIProvider) async throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        fixture.model.settings.executablePath = "/missing/grok"
        fixture.model.addProject(fixture.root)
        func new(_ provider: CLIProvider?) async -> RemoteReply {
            await RemoteCommands.execute(
                RemoteRequest(
                    challenge: "test", sequence: 1, action: "new", text: fixture.root.path,
                    provider: provider?.rawValue, model: "grok-4.6"),
                model: fixture.model)
        }
        let grok = await new(.grokBuild)
        #expect(!grok.ok)
        #expect(
            grok.error
                == "The selected Grok executable is unavailable. Choose another path or Use Installed Grok in Settings."
        )
        #expect(await new(provider).ok)
        let chosen = try #require(fixture.model.selectedTab)
        #expect(chosen.spec.provider == provider)
        #expect(chosen.spec.model == nil)
        // A phone that names no provider gets the Mac's default.
        fixture.model.settings.defaultProvider = provider
        #expect(await new(nil).ok)
        #expect(fixture.model.tabs.map(\.spec.provider) == [provider, provider])
        #expect(fixture.errors.titles.isEmpty)
    }

    @Test(arguments: [CLIProvider.codex, .devin, .cursor, .kimi])
    func projectArchiveOnlyStopsArchiveCapableTabsAfterConfirmation(provider: CLIProvider) throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let grok = try #require(fixture.model.newTab(in: fixture.root))
        let other = try #require(fixture.model.newTab(in: fixture.root, provider: provider))
        #expect(grok.activity == .unknown)
        #expect(grok.capabilities.archive)
        #expect(!other.capabilities.archive)
        other.noteTurnStarted()
        var prompts: [StopWorkingPrompt] = []
        var confirm = false
        fixture.model.confirmStopWorking = {
            prompts.append($0)
            return confirm
        }
        let project = SidebarProject(
            id: fixture.root.path, name: "project", displayPath: fixture.root.path,
            cwd: fixture.root.path, sessions: [], updatedAt: .now)
        fixture.model.archive(project)
        #expect(prompts.count == 1)
        #expect(prompts.last?.count == 1)
        #expect(prompts.last?.action == .archive)
        #expect(fixture.model.tabs.map(\.id) == [grok.id, other.id])
        #expect(grok.controller.isRunning)
        #expect(other.controller.isRunning)

        confirm = true
        fixture.model.archive(project)
        #expect(prompts.count == 2)
        #expect(prompts.last?.count == 1)
        #expect(fixture.model.tabs.map(\.id) == [other.id])
        #expect(!grok.controller.isRunning)
        #expect(other.controller.isRunning)
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex])
    func projectArchiveIncludesKnownNativeSessionsAndHonorsCancellation(provider: CLIProvider) throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        let grok = try #require(fixture.model.newTab(in: fixture.root))
        let sessionID = UUID().uuidString.lowercased()
        let transcript = fixture.root.appendingPathComponent("\(sessionID).jsonl")
        let record: [String: Any] =
            provider == .codex
            ? [
                "type": "session_meta",
                "payload": ["id": sessionID, "cwd": fixture.root.path, "cli_version": "0.157.1"],
            ]
            : [
                "type": "user", "sessionId": sessionID, "cwd": fixture.root.path, "version": "2.1.283",
                "message": ["content": "fixture"],
            ]
        try JSONSerialization.data(withJSONObject: record).write(to: transcript)
        let session = GrokSession(
            id: sessionID, cwd: fixture.root.path, summary: "Native conversation",
            createdAt: Date(), updatedAt: Date(), messageCount: 0, modelID: nil,
            agentName: nil, reasoningEffort: nil, directory: transcript, provider: provider)
        fixture.model.open(session)
        let native = try #require(fixture.model.selectedTab)
        #expect(native.sessionReference == session.reference)
        #expect(native.capabilities.archive)
        native.noteTurnStarted()
        let unsupported = try #require(fixture.model.newTab(in: fixture.root, provider: .devin))
        unsupported.noteTurnStarted()
        var prompts: [StopWorkingPrompt] = []
        var confirm = false
        fixture.model.confirmStopWorking = {
            prompts.append($0)
            return confirm
        }
        let project = SidebarProject(
            id: fixture.root.path, name: "project", displayPath: fixture.root.path,
            cwd: fixture.root.path, sessions: [session], updatedAt: .now)

        fixture.model.archive(project)
        #expect(prompts.count == 1)
        #expect(prompts.last?.count == 2)
        #expect(fixture.model.tabs.map(\.id) == [grok.id, native.id, unsupported.id])
        #expect(grok.controller.isRunning && native.controller.isRunning && unsupported.controller.isRunning)

        confirm = true
        fixture.model.archive(project)
        #expect(prompts.count == 2)
        #expect(prompts.last?.count == 2)
        #expect(fixture.model.tabs.map(\.id) == [unsupported.id])
        #expect(!grok.controller.isRunning && !native.controller.isRunning)
        #expect(unsupported.controller.isRunning)
    }

    @Test func anotherCLIGetsOnlyTheModelEffortAndSpeedItWasGiven() throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        fixture.model.settings.model = "grok-4.7"
        fixture.model.settings.effort = "xhigh"
        let plain = try #require(fixture.model.newTab(in: fixture.root, provider: .claudeCode))
        #expect(plain.spec.arguments() == ["--session-id", plain.nativeSessionID!])
        let chosen = try #require(
            fixture.model.newTab(in: fixture.root, model: "opus", effort: "max", fastMode: true, provider: .claudeCode))
        #expect(
            chosen.spec.arguments() == [
                "--session-id", chosen.nativeSessionID!, "--model", "opus", "--effort", "max", "--settings",
                #"{"fastMode":true}"#,
            ])
        let grok = try #require(fixture.model.newTab(in: fixture.root))
        #expect(grok.spec.model == "grok-4.7")
        #expect(grok.spec.reasoningEffort == "xhigh")
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
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
        settings.executablePath = shell.path
        let errors = errors
        model = AppModel(
            settings: settings, store: SessionStore(root: root.appendingPathComponent("sessions")),
            presentError: { errors.titles.append($0.localizedDescription) },
            panel: RightPanel(defaults: defaults),
            pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(),
            providerInstallations: fixtureProviderInstallations(shell))
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
