import Darwin
import Foundation
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
        let sleep = RemoteIdleSleep(hold: { _ in 0 }, release: { _ in releases += 1 })
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

    func release(_ identifier: UInt32) {
        released.append(identifier)
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
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sigil-idle-sleep-\(UUID().uuidString)")
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
            pairingStore: pairing, kimiKeyStore: InMemoryKimiKeyStore(), providerInstallations: [:])
    }

    func newTab() throws -> TerminalTab {
        try #require(model.newTab(in: root))
    }

    func append(_ tab: TerminalTab, type: String, turn: String, sessionID: String? = nil) throws {
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
                "update": ["sessionUpdate": type, "prompt_id": turn, "stop_reason": "end_turn"],
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
