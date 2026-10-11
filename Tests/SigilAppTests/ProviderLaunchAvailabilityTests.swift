import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct ProviderLaunchAvailabilityTests {
    @Test func installedGrokDiscoveryAndAllLaunchesUseTheCheckedHostPath() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .grokBuild)
        defer { fixture.cleanup() }
        fixture.settings.useInstalledGrok()
        let results = fixtureProviderInstallations(fixture.shell)
        let model = fixture.makeModel(probe: { provider, configured in
            #expect(configured == nil)
            return results[provider]!
        })
        defer { model.closeAllTabsAndWait() }
        await model.refreshProviderInstallations(force: false)
        #expect(model.providerLaunchProblem(.grokBuild) == nil)
        #expect(model.grokExecutableURL == fixture.shell)
        let fresh = try #require(model.newTab(in: fixture.root, provider: .grokBuild))
        #expect(fresh.spec.executable == fixture.shell)
        model.restartTab(id: fresh.id)
        #expect(model.selectedTab?.spec.executable == fixture.shell)
        model.closeAllTabsAndWait()
        model.open(fixture.session)
        #expect(model.selectedTab?.spec.executable == fixture.shell)
        #expect(fixture.settings.usesInstalledGrok)
    }

    @Test func switchingFromCustomToInstalledInvalidatesTheOldResult() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .grokBuild)
        defer { fixture.cleanup() }
        let results = fixtureProviderInstallations(fixture.shell)
        let model = fixture.makeModel(
            installations: results,
            probe: { provider, configured in
                #expect(configured == nil)
                return results[provider]!
            })
        fixture.settings.useInstalledGrok()
        #expect(model.providerLaunchProblem(.grokBuild) != nil)
        #expect(model.providerInstallations[.grokBuild] == nil)
        await model.refreshProviderInstallations(force: false)
        #expect(model.providerLaunchProblem(.grokBuild) == nil)
        #expect(model.grokExecutableURL == fixture.shell)
    }

    @Test func returningToInstalledModeCannotReviveAnEarlierAutomaticCheck() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .grokBuild)
        defer { fixture.cleanup() }
        fixture.settings.useInstalledGrok()
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(probe: { provider, _ in await gate.probe(provider) })
        let first = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(6)
        fixture.settings.executablePath = fixture.shell.path
        fixture.settings.useInstalledGrok()
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        await first.value
        #expect(model.providerInstallations[.grokBuild] == nil)
        #expect(model.providerLaunchProblem(.grokBuild) != nil)
        let replacement = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(7)
        #expect(model.checkingProviders == [.grokBuild])
        await gate.release(round: 2, results: fixtureProviderInstallations(fixture.shell))
        await replacement.value
        #expect(model.providerLaunchProblem(.grokBuild) == nil)
    }

    @Test func aGrokRecoveryCheckKeepsOtherFreshProvidersAvailable() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .grokBuild)
        defer { fixture.cleanup() }
        let results = fixtureProviderInstallations(fixture.shell)
        let model = fixture.makeModel(
            installations: results,
            probe: { provider, _ in
                #expect(provider == .grokBuild)
                return results[provider]!
            })
        await model.refreshProviderInstallations(force: true, only: [.grokBuild])
        #expect(model.providerLaunchProblem(.grokBuild) == nil)
        #expect(model.providerLaunchProblem(.claudeCode) == nil)
        #expect(model.providerInstallations[.claudeCode] == results[.claudeCode])
    }

    @Test func routineRequestsReuseFreshSuccessAndCoalescePendingChecks() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(probe: { provider, _ in await gate.probe(provider) })
        let first = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(6)
        await model.refreshProviderInstallations(force: false)
        #expect(await gate.totalCalls == 6)
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        await first.value
        model.requestNewSession(in: fixture.root)
        await model.refreshProviderInstallations(force: false)
        #expect(await gate.totalCalls == 6)
        #expect(model.checkingProviders.isEmpty)
        #expect(model.providerLaunchProblem(.claudeCode) == nil)
    }

    @Test func expiryGatesLaunchWhileFreshProvidersStayAvailable() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let clock = ProviderCheckClock()
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(
            installations: fixtureProviderInstallations(fixture.shell),
            probe: { provider, _ in await gate.probe(provider) }, clock: { clock.now })
        defer { model.closeAllTabsAndWait() }
        model.open(fixture.session)
        let tab = try #require(model.selectedTab)
        clock.advance(299)
        await model.refreshProviderInstallations(force: false)
        #expect(await gate.totalCalls == 0)
        #expect(model.providerLaunchProblem(.claudeCode) == nil)
        clock.advance(1)
        #expect(model.providerLaunchProblem(.claudeCode) != nil)
        let refresh = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(6)
        #expect(model.newTab(in: fixture.root, provider: .claudeCode) == nil)
        model.restartTab(id: tab.id)
        #expect(model.selectedTab === tab)
        #expect(tab.controller.isRunning)
        await gate.release(round: 1, results: [:])
        await refresh.value
        #expect(model.providerLaunchProblem(.claudeCode) == "Fixture CLI is missing.")
    }

    @Test func unavailableResultIsRetriedWithoutRecheckingFreshProviders() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .codex)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        var results = fixtureProviderInstallations(fixture.shell)
        results[.codex] = .init(
            executable: nil, version: nil, problem: "Codex did not answer its version check.", timedOut: true)
        let model = fixture.makeModel(installations: results, probe: { provider, _ in await gate.probe(provider) })
        let refresh = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(1)
        #expect(model.checkingProviders == [.codex])
        #expect(model.providerLaunchProblem(.codex) != nil)
        #expect(model.providerLaunchProblem(.claudeCode) == nil)
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        await refresh.value
        #expect(await gate.totalCalls == 1)
        #expect(model.providerLaunchProblem(.codex) == nil)
    }

    @Test func entryLeftOpenPastExpiryChecksBeforeTheSameClickLaunches() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let clock = ProviderCheckClock()
        let gate = HeldProviderProbe()
        let results = fixtureProviderInstallations(fixture.shell)
        let model = fixture.makeModel(
            installations: results, probe: { provider, _ in await gate.probe(provider) }, clock: { clock.now })
        defer { model.closeAllTabsAndWait() }
        model.requestNewSession(in: fixture.root)
        clock.advance(300)
        let start = Task { await model.startDefaultSession(.claudeCode) }
        await gate.waitForCalls(6)
        #expect(model.tabs.isEmpty)
        #expect(model.isStartingNewSession)
        #expect(model.providerLaunchProblem(.claudeCode) != nil)
        await gate.release(round: 1, results: results)
        await start.value
        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.workingDirectory == fixture.root)
        #expect(!model.isStartingNewSession)
        #expect(!model.isShowingNewSessionSurface)
    }

    @Test func removedExecutableRequiresOnlyItsOwnReplacementCheck() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .codex)
        defer { fixture.cleanup() }
        let executable = fixture.root.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: fixture.shell, to: executable)
        var results = fixtureProviderInstallations(fixture.shell)
        results[.codex] = .init(executable: executable, version: "fixture", problem: nil)
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(installations: results, probe: { provider, _ in await gate.probe(provider) })
        try FileManager.default.moveItem(at: executable, to: fixture.root.appendingPathComponent("removed-codex"))
        #expect(model.providerLaunchProblem(.codex) != nil)
        let replacement = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(1)
        #expect(model.checkingProviders == [.codex])
        #expect(model.providerLaunchProblem(.claudeCode) == nil)
        #expect(model.newTab(in: fixture.root, provider: .codex) == nil)
        await gate.release(round: 1, results: [:])
        await replacement.value
        #expect(await gate.totalCalls == 1)
        #expect(model.providerLaunchProblem(.codex) == "Fixture CLI is missing.")
    }

    @Test func executableChangesImmediatelyInvalidateGrokAndFenceOldCallbacks() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .grokBuild)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(
            installations: fixtureProviderInstallations(fixture.shell),
            probe: { provider, _ in await gate.probe(provider) })
        let first = Task { await model.refreshProviderInstallations() }
        await gate.waitForCalls(6)
        fixture.settings.executablePath = fixture.root.appendingPathComponent("missing").path
        fixture.settings.executablePath = fixture.shell.path
        #expect(model.providerInstallations[.grokBuild] == nil)
        #expect(model.providerLaunchProblem(.grokBuild) != nil)
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        await first.value
        #expect(model.providerInstallations[.grokBuild] == nil)
        #expect(model.providerLaunchProblem(.claudeCode) == nil)
        let replacement = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(7)
        #expect(model.checkingProviders == [.grokBuild])
        await gate.release(round: 2, results: fixtureProviderInstallations(fixture.shell))
        await replacement.value
        #expect(model.providerLaunchProblem(.grokBuild) == nil)
    }

    @Test func inlineEntryStartsOnceWithSavedDefaultsAndReturnsToExistingTerminal() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .grokBuild)
        defer { fixture.cleanup() }
        fixture.settings.model = "saved-custom-model"
        fixture.settings.effort = "high"
        fixture.settings.defaultProvider = .codex
        let model = fixture.makeModel(installations: fixtureProviderInstallations(fixture.shell))
        defer { model.closeAllTabsAndWait() }
        model.requestNewSession(in: fixture.root)
        #expect(model.isShowingNewSessionSurface)
        #expect(!model.isShowingNewSessionSheet)
        await model.startDefaultSession(.grokBuild)
        let tab = try #require(model.selectedTab)
        #expect(tab.workingDirectory == fixture.root)
        #expect(tab.spec.model == "saved-custom-model")
        #expect(tab.spec.reasoningEffort == "high")
        #expect(!model.isShowingNewSessionSurface)
        #expect(fixture.settings.defaultProvider == .codex)
        #expect(!fixture.settings.startsInWorktree)
        model.requestNewSession()
        model.cancelNewSession()
        #expect(!model.isShowingNewSessionSurface)
        #expect(model.selectedTab === tab)
        #expect(tab.controller.isRunning)
        model.requestNewSession()
        model.select(tab.id)
        #expect(!model.isShowingNewSessionSurface)
        #expect(model.tabs.count == 1)
    }

    @Test func inlineUnavailableAndCancelledFirstEntryNeverLaunch() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let model = fixture.makeModel()
        model.requestNewSession(in: fixture.root)
        await model.startDefaultSession(.claudeCode)
        #expect(model.tabs.isEmpty)
        #expect(model.isShowingNewSessionSurface)
        model.showNewSessionOptions()
        #expect(model.isShowingNewSessionSheet)
        model.isShowingNewSessionSheet = false
        model.newSessionSheetDidClose()
        #expect(model.isShowingNewSessionSurface)
        model.cancelNewSession()
        #expect(model.tabs.isEmpty)
        #expect(fixture.settings.openTabs.tabs.isEmpty)
    }

    @Test(arguments: ["new", "open", "restart"], [false, true])
    func remoteLaunchChecksExpiryOrDisappearanceAndRecovers(action: String, removed: Bool) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        await fixture.store.reload()
        let executable = fixture.root.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: fixture.shell, to: executable)
        var available = fixtureProviderInstallations(fixture.shell)
        available[.claudeCode] = .init(executable: executable, version: "fixture", problem: nil)
        let clock = ProviderCheckClock()
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(
            installations: available, probe: { provider, _ in await gate.probe(provider) }, clock: { clock.now })
        defer { model.closeAllTabsAndWait() }
        var ended: TerminalTab?
        if action == "restart" {
            model.open(fixture.session)
            let tab = try #require(model.selectedTab)
            tab.terminateAndWait()
            ended = tab
        }
        let live = try #require(model.newTab(in: fixture.root, provider: .grokBuild))
        let before = model.tabs.map(\.id)
        let missing = fixture.root.appendingPathComponent("removed-claude")
        if removed {
            try FileManager.default.moveItem(at: executable, to: missing)
        } else {
            clock.advance(300)
        }
        let request = RemoteRequest(
            challenge: "test", sequence: 1, action: action, tabID: ended?.id.uuidString,
            text: action == "open" ? fixture.session.cwd : nil,
            name: action == "open" ? fixture.session.id : nil, provider: CLIProvider.claudeCode.rawValue,
            worktree: false)
        let launch = Task { await RemoteCommands.execute(request, model: model) }
        let firstCalls = removed ? 1 : 6
        await gate.waitForCalls(firstCalls)
        #expect(model.tabs.map(\.id) == before)
        #expect(live.controller.isRunning)
        #expect(model.providerLaunchProblem(.claudeCode) != nil)
        var result = available
        if removed { result[.claudeCode] = nil }
        await gate.release(round: 1, results: result)
        let reply = await launch.value
        var successfulReply = reply
        #expect(reply.ok == !removed)
        #expect(await gate.totalCalls == firstCalls)
        #expect(live.controller.isRunning)
        if removed {
            #expect(model.tabs.map(\.id) == before)
            #expect(reply.error == "Fixture CLI is missing.")
            try FileManager.default.moveItem(at: missing, to: executable)
            let retry = Task { await RemoteCommands.execute(request, model: model) }
            await gate.waitForCalls(2)
            await gate.release(round: 2, results: available)
            successfulReply = await retry.value
            #expect(successfulReply.ok)
            #expect(await gate.totalCalls == 2)
        }
        let started: TerminalTab
        if let ended {
            let replacementID = try #require(successfulReply.restartedTabID)
            started = try #require(model.tabs.first { $0.id.uuidString == replacementID })
            #expect(started.id != ended.id)
            #expect(!model.tabs.contains { $0.id == ended.id })
            #expect(model.tabs.first === started)
            #expect(model.tabs.count == before.count)
            #expect(successfulReply.restartedSession == ended.sessionReference)
            #expect(model.selectedTab === live)
        } else {
            started = try #require(model.selectedTab)
            #expect(model.tabs.count == before.count + 1)
        }
        #expect(started.spec.provider == .claudeCode)
        #expect(GrokPaths.canonicalPath(started.workingDirectory.path) == GrokPaths.canonicalPath(fixture.root.path))
    }

    @Test func remoteRequestsJoinPendingChecksAndCancelledWaitersNeverLaunch() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(probe: { provider, _ in await gate.probe(provider) })
        defer { model.closeAllTabsAndWait() }
        let refresh = Task { await model.refreshProviderInstallations() }
        await gate.waitForCalls(6)
        let request = RemoteRequest(
            challenge: "test", sequence: 1, action: "new", provider: CLIProvider.claudeCode.rawValue)
        let cancelled = Task { await RemoteCommands.execute(request, model: model) }
        let joined = Task { await RemoteCommands.execute(request, model: model) }
        for _ in 0..<20 { await Task.yield() }
        cancelled.cancel()
        let cancelledReply = await cancelled.value
        #expect(!cancelledReply.ok)
        #expect(cancelledReply.error == "Remote was turned off.")
        #expect(model.tabs.isEmpty)
        #expect(await gate.totalCalls == 6)
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        await refresh.value
        #expect(await joined.value.ok)
        #expect(model.tabs.count == 1)
        #expect(await gate.totalCalls == 6)
        #expect(model.providerLaunchProblem(.claudeCode) == nil)
    }

    @Test func remoteOptionsRefreshExpiredInventoryBeforeReplying() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let clock = ProviderCheckClock()
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(
            installations: fixtureProviderInstallations(fixture.shell),
            probe: { provider, _ in await gate.probe(provider) }, clock: { clock.now })
        clock.advance(300)
        let options = Task {
            await RemoteCommands.execute(.init(challenge: "test", sequence: 1, action: "options"), model: model)
        }
        await gate.waitForCalls(6)
        #expect(model.tabs.isEmpty)
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        let reply = await options.value
        #expect(reply.ok)
        #expect(reply.options?.providers.allSatisfy { $0.problem == nil } == true)
        #expect(model.tabs.isEmpty)
    }

    @Test(arguments: [false, true])
    func optionsLeftOpenCanCheckAgainBeforeStartingItsChosenOptions(removed: Bool) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("chosen-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let executable = fixture.root.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: fixture.shell, to: executable)
        var available = fixtureProviderInstallations(fixture.shell)
        available[.claudeCode] = .init(executable: executable, version: "fixture", problem: nil)
        let clock = ProviderCheckClock()
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(
            installations: available, probe: { provider, _ in await gate.probe(provider) }, clock: { clock.now })
        defer { model.closeAllTabsAndWait() }
        let live = try #require(model.newTab(in: fixture.root, provider: .grokBuild))
        model.requestNewSession(in: project)
        model.showNewSessionOptions()
        #expect(NewSessionLaunch.canRequestStart(.claudeCode, model: model))
        if removed {
            try FileManager.default.moveItem(at: executable, to: fixture.root.appendingPathComponent("removed-claude"))
        } else {
            clock.advance(300)
        }
        #expect(model.providerLaunchProblem(.claudeCode) == "Check Claude Code before starting.")
        #expect(NewSessionLaunch.canRequestStart(.claudeCode, model: model))
        let launch = Task {
            await NewSessionLaunch.start(
                .claudeCode, model: model, project: project, useWorktree: false,
                launch: (model: "sonnet", effort: "high", fastMode: false))
        }
        await gate.waitForCalls(removed ? 1 : 6)
        #expect(!NewSessionLaunch.canRequestStart(.claudeCode, model: model))
        #expect(model.tabs.count == 1)
        #expect(live.controller.isRunning)
        var result = available
        if removed { result[.claudeCode] = nil }
        await gate.release(round: 1, results: result)
        #expect(await launch.value == !removed)
        #expect(live.controller.isRunning)
        if removed {
            #expect(model.selectedTab === live)
            #expect(!NewSessionLaunch.canRequestStart(.claudeCode, model: model))
        } else {
            let tab = try #require(model.selectedTab)
            #expect(tab.workingDirectory == project)
            #expect(tab.spec.model == "sonnet")
            #expect(tab.spec.reasoningEffort == "high")
        }
    }

    @Test(arguments: [false, true])
    func closingOptionsWhileItsCheckRunsPreventsTheLateLaunch(cancelled: Bool) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(probe: { provider, _ in await gate.probe(provider) })
        model.showNewSessionOptions()
        let launch = Task {
            await NewSessionLaunch.start(
                .claudeCode, model: model, project: fixture.root, useWorktree: false,
                launch: (model: "sonnet", effort: "high", fastMode: false))
        }
        await gate.waitForCalls(6)
        model.isShowingNewSessionSheet = false
        if cancelled { launch.cancel() }
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        #expect(await !launch.value)
        #expect(model.tabs.isEmpty)
    }

    @Test func remoteRestartDoesNotReplaceAnotherTabIfItsTargetClosesDuringTheCheck() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .claudeCode)
        defer { fixture.cleanup() }
        let clock = ProviderCheckClock()
        let gate = HeldProviderProbe()
        let model = fixture.makeModel(
            installations: fixtureProviderInstallations(fixture.shell),
            probe: { provider, _ in await gate.probe(provider) }, clock: { clock.now })
        defer { model.closeAllTabsAndWait() }
        model.open(fixture.session)
        let ended = try #require(model.selectedTab)
        ended.terminateAndWait()
        let live = try #require(model.newTab(in: fixture.root, provider: .grokBuild))
        clock.advance(300)
        let restart = Task {
            await RemoteCommands.execute(
                .init(challenge: "test", sequence: 1, action: "restart", tabID: ended.id.uuidString), model: model)
        }
        await gate.waitForCalls(6)
        model.closeTab(ended.id)
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        let reply = await restart.value
        #expect(!reply.ok)
        #expect(reply.error == "This tab is closed.")
        #expect(reply.restartedTabID == nil)
        #expect(model.tabs.map(\.id) == [live.id])
        #expect(live.controller.isRunning)
    }

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
        let remote = Task {
            await RemoteCommands.execute(
                .init(challenge: "test", sequence: 1, action: "restart", tabID: tab.id.uuidString), model: model)
        }
        for _ in 0..<20 { await Task.yield() }
        remote.cancel()
        let reply = await remote.value
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

    @Test(arguments: [false, true])
    func reversedProbeCompletionCannotReorderSavedTabs(withFreshLaterProvider: Bool) async throws {
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
        var initial = withFreshLaterProvider ? fixtureProviderInstallations(fixture.shell) : [:]
        initial[.claudeCode] = nil
        let model = fixture.makeModel(
            installations: initial, store: store, probe: { provider, _ in await gate.probe(provider) })
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        #expect(model.tabs.isEmpty)
        let refresh = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(withFreshLaterProvider ? 1 : CLIProvider.allCases.count)
        let results = fixtureProviderInstallations(fixture.shell)
        if !withFreshLaterProvider { await gate.release(round: 1, provider: .codex, results: results) }
        // Drain runnable work while every other provider remains explicitly suspended.
        for _ in 0..<100 where model.providerInstallations[.codex] == nil { await Task.yield() }
        #expect(model.providerInstallations[.claudeCode] == nil)
        #expect((model.providerInstallations[.codex] != nil) == withFreshLaterProvider)
        #expect(model.tabs.isEmpty)
        // A history scan can call restoration during the same partial batch.
        model.restoreOpenTabs()
        #expect(model.tabs.isEmpty)
        await gate.release(round: 1, results: results)
        await refresh.value
        #expect(model.tabs.map(\.spec.provider) == [.claudeCode, .codex])
        #expect(model.selectedTab?.sessionReference == fixture.session.reference)
    }

    @Test(arguments: CLIProvider.allCases)
    func firstUseInlineLaunchKeepsCLIDefaults(provider: CLIProvider) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: provider, startsInWorktree: nil)
        defer { fixture.cleanup() }
        #expect(fixture.settings.startsInWorktree)
        #expect(fixture.settings.defaultProvider == .grokBuild)
        let model = fixture.makeModel(installations: fixtureProviderInstallations(fixture.shell))
        defer { model.closeAllTabsAndWait() }
        model.requestNewSession(in: fixture.root)
        await model.startDefaultSession(provider)
        let tab = try #require(model.selectedTab)
        #expect(tab.spec.provider == provider)
        #expect(tab.spec.model == nil)
        #expect(tab.spec.reasoningEffort == nil)
        #expect(!tab.spec.fastMode)
        #expect(tab.workingDirectory == fixture.root)
        #expect(model.tabs.count == 1)
        #expect(!model.isShowingNewSessionSheet)
        #expect(!model.isShowingNewSessionSurface)
        #expect(fixture.settings.startsInWorktree)
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

    @Test func oneTimeoutRestoresSavedTabWithoutOpeningNewSession() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .codex)
        defer { fixture.cleanup() }
        await fixture.store.reload()
        fixture.saveOpenTab()
        let gate = HeldProviderProbe()
        let clock = ProviderCheckClock()
        let scheduler = ProviderRetryScheduler(clock: clock)
        defer { scheduler.cancelAll() }
        var initial = fixtureProviderInstallations(fixture.shell)
        initial[.codex] = nil
        let model = fixture.makeModel(
            installations: initial, probe: { provider, _ in await gate.probe(provider) },
            clock: { clock.now }, sleep: { try await scheduler.sleep($0) })
        defer { model.closeAllTabsAndWait() }
        await model.onAppear()
        let first = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(1)
        await gate.release(round: 1, results: [.codex: fixtureTimeout()])
        await first.value
        await scheduler.waitForTimer()
        #expect(model.tabs.isEmpty)
        #expect(model.providerLaunchProblem(.codex)?.contains("still being checked") == true)
        #expect(!model.providerRequiresCheck(.codex))
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(4)
        #expect(await gate.totalCalls == 1)
        scheduler.advance(1)
        await gate.waitForCalls(2)
        await gate.release(round: 2, results: fixtureProviderInstallations(fixture.shell))
        await waitForProviderResult(model, .codex)
        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.sessionReference == fixture.session.reference)
        #expect(fixture.settings.openTabs.selectedSessionID == fixture.session.nativeSessionID)
        #expect(!model.isShowingNewSessionSurface)
        #expect(!model.isShowingNewSessionSheet)
        #expect(model.providerLaunchProblem(.codex) == nil)
        #expect(await gate.totalCalls == 2)
    }

    @Test func retriesExhaustAtFiveFifteenAndFortyFiveSecondsThenOneClickChecksAgain() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .codex)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let clock = ProviderCheckClock()
        let scheduler = ProviderRetryScheduler(clock: clock)
        defer { scheduler.cancelAll() }
        var initial = fixtureProviderInstallations(fixture.shell)
        initial[.codex] = nil
        let model = fixture.makeModel(
            installations: initial, probe: { provider, _ in await gate.probe(provider) },
            clock: { clock.now }, sleep: { try await scheduler.sleep($0) })
        defer { model.closeAllTabsAndWait() }
        let first = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(1)
        await gate.release(round: 1, results: [.codex: fixtureTimeout()])
        await first.value
        for (index, delay) in [5.0, 15.0, 45.0].enumerated() {
            await scheduler.waitForTimer()
            #expect(scheduler.nextDeadline == clock.now + delay)
            scheduler.advance(delay)
            await gate.waitForCalls(index + 2)
            await gate.release(round: index + 2, results: [.codex: fixtureTimeout()])
            await waitForProviderResult(model, .codex)
        }
        #expect(await gate.totalCalls == 4)
        #expect(scheduler.pendingCount == 0)
        #expect(model.providerLaunchProblem(.codex)?.contains("Version check timed out") == true)
        #expect(model.providerLaunchProblem(.codex)?.contains("Check Again") == true)
        #expect(model.providerRequiresCheck(.codex))
        for _ in 0..<20 { model.appDidBecomeActive() }
        scheduler.advance(100)
        #expect(await gate.totalCalls == 4)
        // Opening inventory, reading remote options, or checking another
        // provider must not replenish Codex's exhausted recovery sequence.
        await gate.answerImmediately(fixtureTimeout())
        for _ in 0..<3 {
            await model.refreshProviderInstallationsForEntry()
            await model.refreshProviderInstallations(force: false, only: [.codex])
            let options = await RemoteCommands.execute(
                .init(challenge: "test", sequence: 1, action: "options"), model: model)
            #expect(options.ok)
            #expect(
                options.options?.providers.first { $0.id == CLIProvider.codex.rawValue }?.problem?
                    .contains("Version check timed out") == true)
            #expect(model.providerLaunchProblem(.codex)?.contains("Version check timed out") == true)
        }
        await gate.answerImmediately(nil)
        #expect(await gate.totalCalls == 4)
        guard await gate.totalCalls == 4 else { return }
        let other = Task { await model.refreshProviderInstallations(only: [.grokBuild]) }
        await gate.waitForCalls(5)
        await gate.release(round: 1, results: fixtureProviderInstallations(fixture.shell))
        await other.value
        #expect(!model.providerIsRecovering(.codex))
        #expect(scheduler.pendingCount == 0)
        model.requestNewSession(in: fixture.root)
        let start = Task { await model.startDefaultSession(.codex) }
        await gate.waitForCalls(6)
        await gate.release(round: 5, results: fixtureProviderInstallations(fixture.shell))
        await start.value
        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.spec.provider == .codex)
        #expect(await gate.totalCalls == 6)
    }

    @Test(arguments: ["Fixture CLI is missing.", "Fixture CLI version is invalid."])
    func missingAndInvalidCLIsHaveNoAutomaticRetries(problem: String) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .codex)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let clock = ProviderCheckClock()
        let scheduler = ProviderRetryScheduler(clock: clock)
        defer { scheduler.cancelAll() }
        let model = fixture.makeModel(
            installations: fixtureProviderInstallations(fixture.shell),
            probe: { provider, _ in await gate.probe(provider) },
            clock: { clock.now }, sleep: { try await scheduler.sleep($0) })
        let refresh = Task { await model.refreshProviderInstallations(only: [.codex]) }
        await gate.waitForCalls(1)
        await gate.release(round: 1, results: [.codex: .init(executable: nil, version: nil, problem: problem)])
        await refresh.value
        for _ in 0..<20 { model.appDidBecomeActive() }
        scheduler.advance(300)
        #expect(scheduler.pendingCount == 0)
        #expect(await gate.totalCalls == 1)
        #expect(model.providerLaunchProblem(.codex) == problem)
    }

    @Test(arguments: [false, true])
    func forcedRefreshFencesPendingOrRunningAutomaticRetry(inFlight: Bool) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .codex)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let clock = ProviderCheckClock()
        let scheduler = ProviderRetryScheduler(clock: clock, honorsCancellation: false)
        defer { scheduler.cancelAll() }
        let model = fixture.makeModel(
            installations: fixtureProviderInstallations(fixture.shell),
            probe: { provider, _ in await gate.probe(provider) },
            clock: { clock.now }, sleep: { try await scheduler.sleep($0) })
        let first = Task { await model.refreshProviderInstallations(only: [.codex]) }
        await gate.waitForCalls(1)
        await gate.release(round: 1, results: [.codex: fixtureTimeout()])
        await first.value
        await scheduler.waitForTimer()
        if inFlight {
            scheduler.advance(5)
            await gate.waitForCalls(2)
        }
        let nextRound = inFlight ? 3 : 2
        let replacement = Task { await model.refreshProviderInstallations(only: [.codex]) }
        await gate.waitForCalls(nextRound)
        await gate.release(round: nextRound, results: [:])
        await replacement.value
        if inFlight {
            await gate.release(round: 2, results: fixtureProviderInstallations(fixture.shell))
        } else {
            // Deliver a canceled timer anyway; the real path must fence it.
            scheduler.advance(65)
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(await gate.totalCalls == nextRound)
        #expect(model.providerLaunchProblem(.codex) == "Fixture CLI is missing.")
        #expect(!model.providerIsRecovering(.codex))
    }

    @Test(arguments: [false, true])
    func executableChangeFencesPendingAndRunningGrokRetries(inFlight: Bool) async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .grokBuild)
        defer { fixture.cleanup() }
        let replacementPath = fixture.root.appendingPathComponent("replacement-grok")
        try FileManager.default.copyItem(at: fixture.shell, to: replacementPath)
        let gate = HeldProviderProbe()
        let clock = ProviderCheckClock()
        let scheduler = ProviderRetryScheduler(clock: clock, honorsCancellation: false)
        defer { scheduler.cancelAll() }
        let model = fixture.makeModel(
            installations: fixtureProviderInstallations(fixture.shell),
            probe: { provider, _ in await gate.probe(provider) },
            clock: { clock.now }, sleep: { try await scheduler.sleep($0) })
        defer { model.closeAllTabsAndWait() }
        let first = Task { await model.refreshProviderInstallations(only: [.grokBuild]) }
        await gate.waitForCalls(1)
        await gate.release(round: 1, results: [.grokBuild: fixtureTimeout()])
        await first.value
        await scheduler.waitForTimer()
        if inFlight {
            scheduler.advance(5)
            await gate.waitForCalls(2)
        }
        fixture.settings.executablePath = replacementPath.path
        #expect(model.providerInstallations[.grokBuild] == nil)
        #expect(!model.providerIsRecovering(.grokBuild))
        let nextRound = inFlight ? 3 : 2
        let replacement = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(nextRound)
        var replacementResults = fixtureProviderInstallations(fixture.shell)
        replacementResults[.grokBuild] = .init(executable: replacementPath, version: "fixture", problem: nil)
        await gate.release(round: nextRound, results: replacementResults)
        await replacement.value
        if inFlight {
            await gate.release(round: 2, results: fixtureProviderInstallations(fixture.shell))
        } else {
            scheduler.advance(65)
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(await gate.totalCalls == nextRound)
        #expect(model.grokExecutableURL == replacementPath)
        #expect(model.providerInstallations[.grokBuild]?.executable == replacementPath)
        #expect(model.providerLaunchProblem(.grokBuild) == nil)
        #expect(model.newTab(in: fixture.root)?.spec.executable == replacementPath)
    }

    @Test func settingsOnlyGrokRetryUsesTheAppWideActivationHook() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .grokBuild)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let clock = ProviderCheckClock()
        let scheduler = ProviderRetryScheduler(clock: clock)
        defer { scheduler.cancelAll() }
        let model = fixture.makeModel(
            installations: fixtureProviderInstallations(fixture.shell),
            probe: { provider, _ in await gate.probe(provider) },
            clock: { clock.now }, sleep: { try await scheduler.sleep($0) })
        let settingsCheck = Task { await model.refreshProviderInstallations(only: [.grokBuild]) }
        await gate.waitForCalls(1)
        await gate.release(round: 1, results: [.grokBuild: fixtureTimeout()])
        await settingsCheck.value
        await scheduler.waitForTimer()
        #expect(scheduler.nextDeadline == 5)
        // This is the app-wide model hook called by AppDelegate. No RootView
        // or WindowContent is constructed or required to receive activation.
        model.appDidBecomeActive()
        for _ in 0..<1_000 {
            if await gate.totalCalls == 2 { break }
            await Task.yield()
        }
        #expect(await gate.totalCalls == 2)
        guard await gate.totalCalls == 2 else { return }
        await gate.release(round: 2, results: fixtureProviderInstallations(fixture.shell))
        await waitForProviderResult(model, .grokBuild)
        #expect(clock.now == 0)
        #expect(model.providerLaunchProblem(.grokBuild) == nil)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func activationBurstsExpediteOnlyOneRetryWithoutResettingTheBudget() async throws {
        let fixture = try LaunchAvailabilityFixture(provider: .codex)
        defer { fixture.cleanup() }
        let gate = HeldProviderProbe()
        let clock = ProviderCheckClock()
        let scheduler = ProviderRetryScheduler(clock: clock)
        defer { scheduler.cancelAll() }
        let model = fixture.makeModel(
            installations: fixtureProviderInstallations(fixture.shell),
            probe: { provider, _ in await gate.probe(provider) },
            clock: { clock.now }, sleep: { try await scheduler.sleep($0) })
        let first = Task { await model.refreshProviderInstallations(only: [.codex]) }
        await gate.waitForCalls(1)
        await gate.release(round: 1, results: [.codex: fixtureTimeout()])
        await first.value
        await scheduler.waitForTimer()
        for _ in 0..<20 { model.appDidBecomeActive() }
        await gate.waitForCalls(2)
        for _ in 0..<20 { model.appDidBecomeActive() }
        #expect(await gate.totalCalls == 2)
        await gate.release(round: 2, results: [.codex: fixtureTimeout()])
        await waitForProviderResult(model, .codex)
        await scheduler.waitForTimer()
        #expect(scheduler.pendingCount == 1)
        #expect(scheduler.nextDeadline == 15)
        for _ in 0..<20 { model.appDidBecomeActive() }
        #expect(await gate.totalCalls == 2)
        scheduler.advance(15)
        await gate.waitForCalls(3)
        await gate.release(round: 3, results: fixtureProviderInstallations(fixture.shell))
        await waitForProviderResult(model, .codex)
        #expect(model.providerLaunchProblem(.codex) == nil)
        #expect(await gate.totalCalls == 3)
    }

    @Test(arguments: [
        (false, false, false), (false, false, true), (false, true, false), (false, true, true),
        (true, false, false), (true, false, true), (true, true, false), (true, true, true),
    ])
    func twoDeferredProvidersKeepSavedOrderAcrossSeparateRetryRounds(
        firstRecoversFirst: Bool, lateExhausts: Bool, legacySelection: Bool
    ) async throws {
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
            tabs: entries, selectedSessionID: entries[0].sessionID,
            selectedCWD: legacySelection ? nil : entries[0].cwd,
            selectedProvider: legacySelection ? nil : entries[0].provider)
        let gate = HeldProviderProbe()
        let clock = ProviderCheckClock()
        let scheduler = ProviderRetryScheduler(clock: clock)
        defer { scheduler.cancelAll() }
        var initial = fixtureProviderInstallations(fixture.shell)
        initial[.claudeCode] = nil
        initial[.codex] = nil
        let model = fixture.makeModel(
            installations: initial, store: store, probe: { provider, _ in await gate.probe(provider) },
            clock: { clock.now }, sleep: { try await scheduler.sleep($0) })
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        let first = Task { await model.refreshProviderInstallations(force: false) }
        await gate.waitForCalls(2)
        await gate.release(round: 1, results: [.claudeCode: fixtureTimeout(), .codex: fixtureTimeout()])
        await first.value
        await scheduler.waitForTimer()
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(5)
        await gate.waitForCalls(4)
        let early: CLIProvider = firstRecoversFirst ? .claudeCode : .codex
        let late: CLIProvider = firstRecoversFirst ? .codex : .claudeCode
        let available = fixtureProviderInstallations(fixture.shell)
        await gate.release(round: 2, provider: early, results: available)
        for _ in 0..<50 { await Task.yield() }
        #expect(model.tabs.isEmpty)
        await gate.release(round: 2, provider: late, results: [late: fixtureTimeout()])
        await waitForProviderResult(model, late)
        #expect(model.tabs.map(\.spec.provider) == (firstRecoversFirst ? [.claudeCode] : []))
        #expect(fixture.settings.openTabs.tabs.map(\.sessionID) == entries.map(\.sessionID))
        #expect(fixture.settings.openTabs.selectedSessionID == entries[0].sessionID)
        await scheduler.waitForTimer()
        scheduler.advance(15)
        await gate.waitForCalls(5)
        await gate.release(round: 3, results: lateExhausts ? [late: fixtureTimeout()] : available)
        await waitForProviderResult(model, late)
        if lateExhausts {
            await scheduler.waitForTimer()
            scheduler.advance(45)
            await gate.waitForCalls(6)
            await gate.release(round: 4, results: [late: fixtureTimeout()])
            await waitForProviderResult(model, late)
            #expect(model.tabs.map(\.spec.provider) == [early])
            #expect(fixture.settings.openTabs.tabs.map(\.sessionID) == entries.map(\.sessionID))
            #expect(fixture.settings.openTabs.selectedSessionID == entries[0].sessionID)
            #expect(model.providerLaunchProblem(late)?.contains("Version check timed out") == true)
            let peer = try #require(model.tabs.first)
            model.restartTab(id: peer.id)
            #expect(model.tabs.first?.id != peer.id)
            #expect(model.tabs.map(\.spec.provider) == [early])
            #expect(fixture.settings.openTabs.tabs.map(\.sessionID) == entries.map(\.sessionID))
            let manual = Task { await model.refreshProviderInstallations(only: [late]) }
            await gate.waitForCalls(7)
            await gate.release(round: 5, results: available)
            await manual.value
        }
        #expect(model.tabs.map(\.spec.provider) == [.claudeCode, .codex])
        #expect(model.selectedTab?.sessionReference == fixture.session.reference)
        #expect(fixture.settings.openTabs.tabs.map(\.sessionID) == entries.map(\.sessionID))
        model.restoreOpenTabs()
        model.restoreOpenTabs()
        #expect(model.tabs.count == 2)
        #expect(await gate.totalCalls == (lateExhausts ? 7 : 5))
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
    var totalCalls: Int { callCount }
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var immediateResult: ProviderInstallation?

    func answerImmediately(_ result: ProviderInstallation?) { immediateResult = result }

    func probe(_ provider: CLIProvider) async -> ProviderInstallation {
        await withCheckedContinuation { continuation in
            let round = rounds[provider, default: 0] + 1
            rounds[provider] = round
            if let immediateResult {
                continuation.resume(returning: immediateResult)
            } else {
                pending.append((provider, round, continuation))
            }
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

    init(provider: CLIProvider, startsInWorktree: Bool? = false) throws {
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
        if let startsInWorktree { settings.startsInWorktree = startsInWorktree }
    }

    func makeModel(
        installations: [CLIProvider: ProviderInstallation] = [:], store: SessionStore? = nil,
        probe: AppModel.ProviderProbe? = nil, clock: (@Sendable () -> TimeInterval)? = nil,
        sleep: ProviderChecks.Sleep? = nil
    ) -> AppModel {
        AppModel(
            settings: settings, store: store ?? self.store, presentError: { [weak self] _ in self?.alerts += 1 },
            panel: RightPanel(defaults: defaults), pairingStore: InMemoryRemotePairingStore(),
            providerInstallations: installations, providerProbe: probe, providerCheckClock: clock,
            providerCheckSleep: sleep)
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

private final class ProviderCheckClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private func fixtureTimeout() -> ProviderInstallation {
    .init(executable: nil, version: nil, problem: "Fixture version check timed out.", timedOut: true)
}

@MainActor
private func waitForProviderResult(_ model: AppModel, _ provider: CLIProvider) async {
    for _ in 0..<1_000 {
        if !model.checkingProviders.contains(provider), model.providerInstallations[provider] != nil { return }
        await Task.yield()
    }
    Issue.record("Provider result did not settle")
}

/// Drives the production scheduler's sleep and clock, including delivery of
/// canceled timers when requested. No real delay or CLI lookup is substituted.
@MainActor
private final class ProviderRetryScheduler {
    let clock: ProviderCheckClock
    let honorsCancellation: Bool
    private var pending: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>, ProviderRetryCancellation)] = [:]
    var pendingCount: Int { pending.values.filter { !$0.2.isCancelled }.count }
    var nextDeadline: TimeInterval? { pending.values.filter { !$0.2.isCancelled }.map(\.0).min() }

    init(clock: ProviderCheckClock, honorsCancellation: Bool = true) {
        self.clock = clock
        self.honorsCancellation = honorsCancellation
    }

    func sleep(_ delay: TimeInterval) async throws {
        if delay <= 0 { return }
        let id = UUID()
        let cancellation = ProviderRetryCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending[id] = (clock.now + delay, continuation, cancellation)
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard honorsCancellation else { return }
        pending.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }

    func advance(_ seconds: TimeInterval) {
        clock.advance(seconds)
        let ready = pending.filter { $0.value.0 <= clock.now }.map(\.key)
        for id in ready { pending.removeValue(forKey: id)?.1.resume() }
    }

    func waitForTimer() async {
        for _ in 0..<1_000 {
            if pendingCount > 0 { return }
            await Task.yield()
        }
        Issue.record("Retry timer did not register")
    }

    func cancelAll() {
        for (_, continuation, _) in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }
}

private final class ProviderRetryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
