import Darwin
import Foundation
import Observation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
struct RemoteIdleSleepTests {
    @Test @MainActor func aValidatedWorkingTurnWithAwayAlertsHoldsTheAssertion() async throws {
        let fixture = try IdleSleepFixture()
        defer { fixture.cleanup() }
        let tab = try fixture.newTab()
        tab.noteTurnStarted()
        try fixture.append(tab, type: "agent_message_chunk", turn: "warmup")
        try fixture.append(tab, type: "turn_completed", turn: "warmup")
        try await idleSleepUntil { tab.activity == .idle }
        #expect(tab.capabilities.lifecycle && tab.controller.isRunning)
        fixture.model.remoteControl.resumeIfPaired(model: fixture.model)
        #expect(fixture.model.remoteControl.isEnabled && fixture.model.remoteControl.isPaired)
        #expect(fixture.model.remoteControl.status != "Phone connected")
        let record = IdleSleepRecord()
        let watch = RemoteIdleSleepWatch(sleep: RemoteIdleSleep(hold: record.hold, release: record.release))
        defer { watch.stop() }
        watch.start(fixture.model)
        try fixture.append(tab, type: "agent_message_chunk", turn: "active")
        try await idleSleepUntil { tab.activity == .working }
        let deadline = ContinuousClock.now + .seconds(2)
        while record.created.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The old status-only watcher does not create any assertion here.
        withExtendedLifetime(watch) {
            #expect(record.created == ["PreventUserIdleSystemSleep"])
        }
    }

    @Test(arguments: Array(0..<8))
    @MainActor
    func connectionAlertAndWorkPolicyTable(bits: Int) {
        let phone = bits & 1 != 0
        let alerts = bits & 2 != 0
        let working = bits & 4 != 0
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release, clock: { 0 })
        let tab = RemoteIdleSleep.WorkingTab(id: UUID(), generation: UUID(), revision: 1)
        sleep.apply(phoneConnected: phone, alertsArmed: alerts, workingTabs: working ? [tab] : [])
        #expect(record.created.count == (phone || (alerts && working) ? 1 : 0))
        sleep.stop()
        #expect(record.released == record.createdIDs)
    }

    @Test @MainActor func transitionsAndIndependentCopiesReleaseOnlyTheirOwnSingleAssertion() {
        let record = IdleSleepRecord()
        let first = RemoteIdleSleep(hold: record.hold, release: record.release, clock: { 0 })
        let second = RemoteIdleSleep(hold: record.hold, release: record.release, clock: { 0 })
        let tab = RemoteIdleSleep.WorkingTab(id: UUID(), generation: UUID(), revision: 1)
        first.apply(phoneConnected: false, alertsArmed: true, workingTabs: [tab])
        first.apply(phoneConnected: true, alertsArmed: true, workingTabs: [tab])
        first.apply(phoneConnected: false, alertsArmed: true, workingTabs: [tab])
        second.apply(phoneConnected: true, alertsArmed: false, workingTabs: [])
        #expect(record.createdIDs == [1, 2])
        first.stop()
        #expect(record.released == [1])
        second.apply(phoneConnected: true, alertsArmed: false, workingTabs: [])
        #expect(record.createdIDs == [1, 2])
        second.stop()
        #expect(record.released == [1, 2])
    }

    @Test @MainActor func quietWorkExpiresWithoutReconnectOrAlertTogglesRenewingTheWindow() {
        let record = IdleSleepRecord()
        let clock = IdleSleepClock()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release, clock: { clock.now })
        let tab = RemoteIdleSleep.WorkingTab(id: UUID(), generation: UUID(), revision: 1)
        sleep.apply(phoneConnected: false, alertsArmed: false, workingTabs: [tab])
        clock.now = RemoteIdleSleep.inactivityLimit - 1
        sleep.apply(phoneConnected: false, alertsArmed: true, workingTabs: [tab])
        #expect(record.createdIDs == [1] && sleep.nextReviewDelay == 1)
        // Ordinary reconnect and repeated quiet input use the original deadline.
        sleep.apply(phoneConnected: false, alertsArmed: true, workingTabs: [tab])
        clock.now += 1
        sleep.apply(phoneConnected: false, alertsArmed: true, workingTabs: [tab])
        #expect(record.released == [1] && sleep.nextReviewDelay == nil)
        sleep.apply(phoneConnected: true, alertsArmed: true, workingTabs: [tab])
        #expect(record.createdIDs == [1, 2])
        sleep.apply(phoneConnected: false, alertsArmed: true, workingTabs: [tab])
        #expect(record.released == [1, 2])
        let progress = RemoteIdleSleep.WorkingTab(id: tab.id, generation: tab.generation, revision: 2)
        sleep.apply(phoneConnected: false, alertsArmed: true, workingTabs: [progress])
        #expect(record.createdIDs == [1, 2, 3])
        sleep.stop()
    }

    @Test @MainActor func oneRemainingWorkingTabKeepsTheSameClaimUntilTheLastConsumerEnds() {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release, clock: { 0 })
        let first = RemoteIdleSleep.WorkingTab(id: UUID(), generation: UUID(), revision: 1)
        let second = RemoteIdleSleep.WorkingTab(id: UUID(), generation: UUID(), revision: 1)
        sleep.apply(phoneConnected: false, alertsArmed: true, workingTabs: [first, second])
        sleep.apply(phoneConnected: false, alertsArmed: true, workingTabs: [second])
        #expect(record.createdIDs == [1] && record.released.isEmpty)
        sleep.apply(phoneConnected: false, alertsArmed: false, workingTabs: [second])
        #expect(record.released == [1])
        sleep.stop()
        #expect(record.released == [1])
    }

    @Test @MainActor func failedCreationRetriesWithTheInjectedClockAndNeverReleasesAnUnownedID() {
        let record = IdleSleepRecord()
        let clock = IdleSleepClock()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release, clock: { clock.now })
        record.failCreates = true
        sleep.apply(phoneConnected: true, alertsArmed: false, workingTabs: [])
        sleep.apply(phoneConnected: true, alertsArmed: false, workingTabs: [])
        #expect(record.attempts == 1 && record.released.isEmpty)
        clock.now = RemoteIdleSleep.retryDelay - 1
        sleep.apply(phoneConnected: true, alertsArmed: false, workingTabs: [])
        #expect(record.attempts == 1)
        clock.now += 1
        record.failCreates = false
        sleep.apply(phoneConnected: true, alertsArmed: false, workingTabs: [])
        #expect(record.attempts == 2 && record.createdIDs == [1])
        sleep.stop()
        #expect(record.released == [1])
    }

    @Test @MainActor func aFailedReleaseKeepsOwnershipAndRetriesWithoutCreatingAnotherAssertion() {
        let record = IdleSleepRecord()
        let clock = IdleSleepClock()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release, clock: { clock.now })
        sleep.apply(phoneConnected: true, alertsArmed: false, workingTabs: [])
        record.failReleases = true
        sleep.apply(phoneConnected: false, alertsArmed: false, workingTabs: [])
        sleep.apply(phoneConnected: false, alertsArmed: false, workingTabs: [])
        #expect(record.releaseAttempts == [1] && record.released.isEmpty)
        sleep.apply(phoneConnected: true, alertsArmed: false, workingTabs: [])
        #expect(record.createdIDs == [1])
        sleep.apply(phoneConnected: false, alertsArmed: false, workingTabs: [])
        #expect(record.createdIDs == [1] && record.releaseAttempts == [1, 1])
        clock.now += RemoteIdleSleep.retryDelay
        record.failReleases = false
        sleep.apply(phoneConnected: false, alertsArmed: false, workingTabs: [])
        #expect(record.released == [1] && record.releaseAttempts == [1, 1, 1])
        sleep.apply(phoneConnected: true, alertsArmed: false, workingTabs: [])
        #expect(record.createdIDs == [1, 2])
        sleep.stop()
        #expect(record.released == [1, 2])
    }

    @Test @MainActor func missingAndLostJournalNeverBorrowTheNominalWorkingState() async throws {
        let fixture = try IdleSleepFixture()
        defer { fixture.cleanup() }
        let tab = try fixture.newTab()
        tab.noteTurnStarted()
        #expect(tab.capabilities.lifecycle && tab.activity == .working)
        #expect(tab.idleSleepWorkingTab == nil)
        fixture.model.remoteControl.resumeIfPaired(model: fixture.model)
        let record = IdleSleepRecord()
        let clock = IdleSleepClock()
        let watch = RemoteIdleSleepWatch(
            sleep: RemoteIdleSleep(hold: record.hold, release: record.release, clock: { clock.now }))
        defer { watch.stop() }
        watch.start(fixture.model)
        #expect(record.created.isEmpty)
        try fixture.append(tab, type: "agent_message_chunk", turn: "active")
        try await idleSleepUntil { tab.idleSleepWorkingTab != nil && record.createdIDs == [1] }
        let journal = try #require(tab.completionEventsURL)
        let parked = journal.appendingPathExtension("parked")
        try FileManager.default.moveItem(at: journal, to: parked)
        try await idleSleepUntil { tab.idleSleepWorkingTab == nil && record.released == [1] }
        #expect(tab.activity == .working && !tab.hasUnseenActivity)
        clock.now = RemoteIdleSleep.inactivityLimit + 1
        try FileManager.default.moveItem(at: parked, to: journal)
        try await idleSleepUntil { tab.idleSleepWorkingTab != nil }
        watch.review(fixture.model)
        #expect(record.createdIDs == [1] && record.released == [1])
        #expect(tab.activity == .working)
    }

    @Test(arguments: ["interrupted", "disconnected", "failed", "exited"])
    @MainActor
    func losingCurrentWorkReleasesWithoutInventingCompletion(reason: String) async throws {
        let fixture = try IdleSleepFixture()
        defer { fixture.cleanup() }
        let tab = try fixture.newTab()
        tab.noteTurnStarted()
        try fixture.append(tab, type: "agent_message_chunk", turn: "active")
        try await idleSleepUntil { tab.idleSleepWorkingTab != nil }
        fixture.model.remoteControl.resumeIfPaired(model: fixture.model)
        let record = IdleSleepRecord()
        let watch = RemoteIdleSleepWatch(sleep: RemoteIdleSleep(hold: record.hold, release: record.release))
        defer { watch.stop() }
        watch.start(fixture.model)
        #expect(record.createdIDs == [1])
        switch reason {
        case "interrupted": tab.noteInterrupted()
        case "disconnected": tab.noteDisconnected()
        case "failed": try fixture.append(tab, type: "turn_completed", turn: "active", reason: "error")
        default: tab.terminate()
        }
        try await idleSleepUntil { record.released == [1] }
        #expect(tab.activity != .idle && tab.idleSleepWorkingTab == nil && !tab.hasUnseenActivity)
    }

    @Test @MainActor func aQuietLongTurnTimerReleasesPowerWithoutChangingTaskTruth() async throws {
        let fixture = try IdleSleepFixture()
        defer { fixture.cleanup() }
        let tab = try fixture.newTab()
        tab.noteTurnStarted()
        try fixture.append(tab, type: "agent_message_chunk", turn: "active")
        try await idleSleepUntil { tab.idleSleepWorkingTab != nil }
        fixture.model.remoteControl.resumeIfPaired(model: fixture.model)
        let record = IdleSleepRecord()
        let clock = IdleSleepClock()
        let gate = IdleSleepReviewGate()
        defer { gate.releaseAll() }
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release, clock: { clock.now })
        let watch = RemoteIdleSleepWatch(sleep: sleep, wait: gate.wait)
        defer { watch.stop() }
        watch.start(fixture.model)
        try await idleSleepUntil { gate.arrivals > 0 }
        #expect(record.createdIDs == [1] && tab.activity == .working)
        clock.now = RemoteIdleSleep.inactivityLimit - 1
        watch.review(fixture.model)
        #expect(record.released.isEmpty && sleep.nextReviewDelay == 1)
        let arrivals = gate.arrivals
        try await idleSleepUntil { gate.arrivals > arrivals }
        clock.now += 1
        gate.releaseAll()
        try await idleSleepUntil { record.released == [1] }
        #expect(tab.activity == .working && tab.idleSleepWorkingTab != nil && !tab.hasUnseenActivity)
        watch.review(fixture.model)
        #expect(record.createdIDs == [1])
        try fixture.append(tab, type: "agent_thought_chunk", turn: "active")
        try await idleSleepUntil { record.createdIDs == [1, 2] }
        #expect(tab.activity == .working)
        watch.stop()
        #expect(record.released == [1, 2])
    }

    @Test @MainActor func alertRegistrationIsObservableAndAwayWorkKeepsTheConnectedClaim() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let fixture = try IdleSleepFixture()
        defer { fixture.cleanup() }
        let tab = try fixture.newTab()
        tab.noteTurnStarted()
        try fixture.append(tab, type: "agent_message_chunk", turn: "active")
        try await idleSleepUntil { tab.idleSleepWorkingTab != nil }
        let remote = fixture.model.remoteControl
        remote.start(urlText: relay.origin, model: fixture.model)
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }
        let record = IdleSleepRecord()
        let watch = RemoteIdleSleepWatch(sleep: RemoteIdleSleep(hold: record.hold, release: record.release))
        defer { watch.stop() }
        watch.start(fixture.model)
        #expect(record.createdIDs == [1] && !remote.alertsArmed)
        let added = IdleSleepObservationCount()
        withObservationTracking { _ = remote.alertsArmed } onChange: { added.increment() }
        let reply = try await paired.phone.request(
            .init(
                challenge: paired.challenge, sequence: 2, action: "notify",
                text: String(repeating: "ab", count: 32), name: "development"), key: paired.device)
        #expect(reply.ok && remote.alertsArmed && added.count == 1)
        let removed = IdleSleepObservationCount()
        withObservationTracking { _ = remote.alertsArmed } onChange: { removed.increment() }
        let cleared = try await paired.phone.request(
            .init(challenge: paired.challenge, sequence: 3, action: "notify", text: ""), key: paired.device)
        #expect(cleared.ok && !remote.alertsArmed && removed.count == 1)
        #expect(record.createdIDs == [1] && record.released.isEmpty)
        let armed = try await paired.phone.request(
            .init(
                challenge: paired.challenge, sequence: 4, action: "notify",
                text: String(repeating: "ab", count: 32), name: "development"), key: paired.device)
        #expect(armed.ok && remote.alertsArmed)
        paired.phone.close()
        try await idleSleepUntil { remote.status != "Phone connected" }
        watch.review(fixture.model)
        #expect(record.createdIDs == [1] && record.released.isEmpty)
        remote.stop()
        try await idleSleepUntil { record.released == [1] }
        #expect(!remote.alertsArmed)
    }

    @Test @MainActor func freshSleepDoesNotHoldBecauseTheAppIsOpen() {
        let record = IdleSleepRecord()
        _ = RemoteIdleSleep(hold: record.hold, release: record.release)
        #expect(record.created.isEmpty)
        #expect(record.released.isEmpty)
    }

    @Test @MainActor func offDoesNotCreateAnAssertion() {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Off")
        #expect(record.attempts == 0)
        #expect(record.created.isEmpty)
        #expect(record.released.isEmpty)
    }

    @Test(arguments: [
        "Waiting for phone",
        "Connecting…",
        "Phone disconnected",
        "Scan to connect",
        "Reconnecting…",
        "phone connected",
        "Phone connected ",
        "",
    ])
    @MainActor
    func statusOtherThanPhoneConnectedDoesNotHold(status: String) {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: status)
        #expect(record.attempts == 0)
        #expect(record.created.isEmpty)
        #expect(record.released.isEmpty)
    }

    @Test @MainActor func phoneConnectedHoldsPreventUserIdleSystemSleepOnce() {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Phone connected")
        #expect(record.created == ["PreventUserIdleSystemSleep"])
        #expect(record.released.isEmpty)
    }

    @Test(arguments: [
        "Off",
        "Waiting for phone",
        "Connecting…",
        "Phone disconnected",
        "Scan to connect",
        "Reconnecting…",
        "phone connected",
        "Phone connected ",
        "",
    ])
    @MainActor
    func leavingPhoneConnectedReleasesTheAssertion(status: String) {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Phone connected")
        sleep.apply(status: status)
        sleep.apply(status: status)
        #expect(record.created == ["PreventUserIdleSystemSleep"])
        #expect(record.released == record.createdIDs)
    }

    @Test @MainActor func connectingAgainAfterReleaseHoldsANewAssertion() {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Off")
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Phone disconnected")
        #expect(record.created == ["PreventUserIdleSystemSleep", "PreventUserIdleSystemSleep"])
        #expect(record.released == record.createdIDs)
    }

    @Test @MainActor func failedHoldIsNotReleased() {
        let record = IdleSleepRecord()
        record.failCreates = true
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Off")
        #expect(record.attempts == 1)
        #expect(record.created.isEmpty)
        #expect(record.released.isEmpty)
    }

    @Test @MainActor func zeroIdentifierIsNotAClaim() {
        var releases = 0
        let sleep = RemoteIdleSleep(
            hold: { _ in 0 },
            release: { _ in
                releases += 1
                return true
            })
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Off")
        #expect(releases == 0)
    }
}

@MainActor
private final class IdleSleepRecord {
    private(set) var created: [String] = []
    private(set) var createdIDs: [UInt32] = []
    private(set) var released: [UInt32] = []
    private(set) var attempts = 0
    var failCreates = false
    var failReleases = false
    private(set) var releaseAttempts: [UInt32] = []
    private var nextID: UInt32 = 1

    func hold(_ type: String) -> UInt32? {
        attempts += 1
        guard !failCreates else { return nil }
        let id = nextID
        nextID += 1
        created.append(type)
        createdIDs.append(id)
        return id
    }

    func release(_ identifier: UInt32) -> Bool {
        releaseAttempts.append(identifier)
        guard !failReleases else { return false }
        released.append(identifier)
        return true
    }
}


@MainActor
private final class IdleSleepFixture {
    let root: URL
    let model: AppModel
    private let store: SessionStore
    private let suite: String
    private let oldShell: String?
    private let oldGrokHome: String?

    init() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigil-idle-sleep-\(UUID().uuidString)")
        root = URL(fileURLWithPath: GrokPaths.canonicalPath(path.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-grok")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        oldShell = getenv("SHELL").map { String(cString: $0) }
        oldGrokHome = getenv("GROK_HOME").map { String(cString: $0) }
        // This synthetic shell ignores its arguments and never reads login files.
        setenv("SHELL", executable.path, 1)
        setenv("GROK_HOME", root.appendingPathComponent("home").path, 1)
        suite = "sigil-idle-sleep-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.executablePath = executable.path
        settings.defaultDirectory = root.path
        settings.isTabMessagingEnabled = false
        store = SessionStore(root: root.appendingPathComponent("sessions"))
        let pairing = InMemoryRemotePairingStore()
        pairing.save(
            RemotePairing(
                origin: "http://127.0.0.1:9", deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey(),
                pushToken: String(repeating: "ab", count: 32), pushEnvironment: "development"))
        model = AppModel(
            settings: settings, store: store, presentError: { _ in }, panel: RightPanel(defaults: defaults),
            pairingStore: pairing, kimiKeyStore: InMemoryKimiKeyStore(),
            providerInstallations: fixtureProviderInstallations(executable))
    }

    func newTab() throws -> TerminalTab {
        try #require(model.newTab(in: root))
    }

    func append(
        _ tab: TerminalTab, type: String, turn: String, sessionID: String? = nil, reason: String = "end_turn"
    ) throws {
        let journal = try #require(tab.completionEventsURL)
        try #require(journal.path.hasPrefix(root.path + "/"))
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let milliseconds = Int64(Date().addingTimeInterval(0.01).timeIntervalSince1970 * 1000)
        let object: [String: Any] = [
            "timestamp": milliseconds / 1000,
            "params": [
                "sessionId": sessionID ?? tab.nativeSessionID!,
                "_meta": ["eventId": UUID().uuidString, "promptId": turn, "agentTimestampMs": milliseconds],
                "update": ["sessionUpdate": type, "prompt_id": turn, "stop_reason": reason],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        if !FileManager.default.fileExists(atPath: journal.path) { try Data().write(to: journal) }
        let handle = try FileHandle(forWritingTo: journal)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func cleanup() {
        model.remoteControl.stop()
        model.closeAllTabsAndWait()
        store.stop()
        if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
        if let oldGrokHome { setenv("GROK_HOME", oldGrokHome, 1) } else { unsetenv("GROK_HOME") }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func idleSleepUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(condition())
}


@MainActor
private final class IdleSleepClock {
    var now: TimeInterval = 0
}

@MainActor
private final class IdleSleepReviewGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait(_ duration: Duration) async throws {
        arrivals += 1
        await withCheckedContinuation { waiting.append($0) }
    }

    func releaseAll() {
        let values = waiting
        waiting.removeAll()
        for value in values { value.resume() }
    }
}

private final class IdleSleepObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
