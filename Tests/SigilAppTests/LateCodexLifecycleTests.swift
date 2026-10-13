import Darwin
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct LateCodexLifecycleTests {
    @Test(arguments: [false, true])
    func actualRemoteCatchUpUpdatesAnAwayActivityWithoutReplayingAlerts(completed: Bool) async throws {
        // Start the existing loopback relay before the fake CLI replaces PATH.
        // Its APNs capture writes frames locally, never contacts Apple.
        let relay = try await RelayFixture(captureAPNs: true)
        defer { relay.stop() }
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let model = fixture.source.model
        let tab = try await fixture.source.newTab()
        let remote = model.remoteControl
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: model)
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }
        let token = String(repeating: "ab", count: 32)
        let activityToken = String(repeating: "cd", count: 40)
        let notify = try await paired.phone.request(
            .init(challenge: paired.challenge, sequence: 2, action: "notify", text: token, name: "development"),
            key: paired.device)
        #expect(notify.ok)
        let registered = try await paired.phone.request(
            .init(
                challenge: paired.challenge, sequence: 3, action: "activity", tabID: tab.id.uuidString,
                text: activityToken),
            key: paired.device)
        #expect(registered.ok)

        var native: String?
        if completed {
            native = try fixture.rollout(tab, events: [("task_started", "first")])
            await fixture.bind()
            #expect(await eventually { tab.activity == .working })
        }
        paired.phone.close()
        #expect(await eventually { remote.status == "Phone disconnected" })
        if let native {
            // Keep the planner's real Working baseline. No actor suspension
            // between publishing the completion and replacing the reader, so
            // the old watcher cannot apply or notify its pending batch.
            try fixture.append(native, events: [("task_complete", "first")])
            let process = try #require(tab.controller.processGeneration)
            let root = try #require(fixture.source.store.codexHistoryRoot)
            let resolved = model.codexTranscriptResolver(
                process, root, fixture.source.store.sessions, fixture.source.cwd)
            let receipt = try #require(resolved)
            tab.adoptTranscript(receipt, generation: process)
        } else {
            native = try fixture.rollout(tab, events: [("task_started", "first")])
            await fixture.bind()
        }

        let restored = completed ? "idle" : "working"
        #expect(await eventually { (try? capturedPushes(relay).contains { $0.state?.status == restored }) == true })
        let caughtUp = try capturedPushes(relay)
        #expect(caughtUp.filter { $0.pushType == "alert" }.isEmpty)
        let updates = caughtUp.filter { $0.pushType == "liveactivity" }
        #expect(updates.count == 1 && updates.first?.token == activityToken)
        #expect(updates.first?.state?.status == restored && updates.first?.event == "update")
        // A later ordinary evaluation cannot recover a consumed transition;
        // the original catch-up must already have sent the activity frame.
        remote.noteTab(tab, model: model)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try capturedPushes(relay).count == caughtUp.count)

        let id = try #require(native)
        let turn = completed ? "next" : "first"
        if completed {
            try fixture.append(id, events: [("task_started", turn)])
            #expect(
                await eventually { (try? capturedPushes(relay).contains { $0.state?.status == "working" }) == true })
        }
        try fixture.append(id, events: [("task_complete", turn)])
        #expect(
            await eventually {
                guard let pushes = try? capturedPushes(relay) else { return false }
                return pushes.contains { $0.pushType == "alert" }
                    && pushes.last { $0.pushType == "liveactivity" }?.state?.status == "idle"
            })
        let final = try capturedPushes(relay)
        let alerts = try final.filter { $0.pushType == "alert" }.map { push -> RemoteAlert in
            let data = try #require(push.data)
            return try RemoteCrypto.open(data, key: paired.device, direction: RemoteAlert.direction)
        }
        #expect(alerts.map(\.kind) == [.finished])
        #expect(alerts.first?.tabID == tab.id.uuidString)
        #expect(final.last { $0.pushType == "liveactivity" }?.state?.status == "idle")
    }

    @Test func losingObservationPublishesCapabilitiesEvenWhenStateWasAlreadyUnknown() async throws {
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.source.newTab()
        _ = try fixture.rollout(tab, events: [])
        await fixture.bind()
        #expect(tab.activity == .unknown && tab.capabilities.lifecycle && tab.isWatchingForCompletion)
        var publishedLoss = false
        let original = tab.onActivityChange
        tab.onActivityChange = {
            original?()
            if !tab.capabilities.lifecycle { publishedLoss = true }
        }
        fixture.observations.set(nil, generation: nil)
        #expect(await eventually { !tab.isWatchingForCompletion })
        #expect(tab.activity == .unknown && publishedLoss)
        #expect(
            RemoteCommands.snapshot(fixture.source.model).tabs.first { $0.id == tab.id.uuidString }?.capabilities?
                .lifecycle == false)
    }

    @Test func delayedFirstIdentityStaysUnknownUntilTheExactReceiptArrives() async throws {
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.source.newTab()
        tab.noteTurnStarted()
        let native = try fixture.rollout(tab, events: [("task_started", "first")])
        fixture.observations.set(nil, generation: nil)
        await fixture.bind()
        #expect(tab.sessionReference == nil && tab.activity == .unknown)
        #expect(!tab.capabilities.lifecycle && !tab.isWatchingForCompletion)
        try fixture.observe(tab, files: [fixture.source.file(native)])
        await fixture.bind()
        #expect(await eventually { tab.activity == .working })
        try fixture.append(native, events: [("task_complete", "first")])
        #expect(await eventually { tab.activity == .idle })
    }

    @Test func firstActiveTurnAttachesAndCompletesOnceInTheBackground() async throws {
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.source.newTab()
        tab.noteTurnStarted()
        let native = try fixture.rollout(tab, events: [("task_started", "first")])
        var settled = 0
        tab.onSettle = { settled += 1 }
        _ = try await fixture.source.newTab()  // the tracked tab is in the background
        await fixture.bind()
        #expect(await eventually { tab.activity == .working })
        #expect(tab.nativeSessionID == native)
        #expect(tab.capabilities.lifecycle && tab.isWatchingForCompletion)
        #expect(!tab.hasUnseenActivity && settled == 0)
        #expect(
            RemoteCommands.snapshot(fixture.source.model).tabs.first { $0.id == tab.id.uuidString }?.capabilities?
                .lifecycle == true)
        let watcher = try #require(tab.completionWatchGeneration)
        tab.noteTurnStarted()
        #expect(tab.completionWatchGeneration == watcher)
        try fixture.append(native, events: [("task_complete", "other"), ("task_complete", "first")])
        #expect(await eventually { tab.activity == .idle && settled == 1 })
        #expect(tab.hasUnseenActivity)
        try fixture.append(native, events: [("task_complete", "first"), ("task_started", "queued")])
        #expect(await eventually { tab.activity == .working })
        try fixture.append(native, events: [("task_complete", "first"), ("task_complete", "queued")])
        #expect(await eventually { tab.activity == .idle && settled == 2 })
    }

    @Test func aTurnCompletedBeforeAttachmentRestoresIdleWithoutUnreadOrSettleReplay() async throws {
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.source.newTab()
        tab.noteTurnStarted()
        let native = try fixture.rollout(tab, events: [("task_started", "first"), ("task_complete", "first")])
        _ = try await fixture.source.newTab()
        var settled = 0
        tab.onSettle = { settled += 1 }
        await fixture.bind()
        #expect(await eventually { tab.activity == .idle })
        #expect(settled == 0 && !tab.hasUnseenActivity)
        try fixture.append(native, events: [("task_complete", "first")])
        try fixture.append(native, events: [("task_started", "next")])
        #expect(await eventually { tab.activity == .working })
        try fixture.append(native, events: [("task_complete", "next")])
        #expect(await eventually { settled == 1 })
    }

    @Test(arguments: ["ambiguous", "replace", "truncate", "rewrite", "new-header", "lost-generation"])
    func invalidatedOwnershipOrRolloutEndsTrackingWithoutCompletion(change: String) async throws {
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.source.newTab()
        let native = try fixture.rollout(tab, events: [("task_started", "first")])
        var settled = 0
        tab.onSettle = { settled += 1 }
        await fixture.bind()
        #expect(await eventually { tab.activity == .working })
        let file = fixture.source.file(native)
        switch change {
        case "ambiguous":
            let other = UUID().uuidString.lowercased()
            try fixture.source.data(other).write(to: fixture.source.file(other))
            try fixture.observe(tab, files: [file, fixture.source.file(other)])
            await fixture.bind()
            #expect(tab.sessionReference == nil)
        case "replace":
            try fixture.source.data(native).write(to: file, options: .atomic)
        case "truncate":
            try Data().write(to: file)
        case "rewrite":
            let original = try Data(contentsOf: file)
            let changed = Data(
                String(decoding: original, as: UTF8.self).replacingOccurrences(of: "0.157.1", with: "1.157.1").utf8)
            try changed.write(to: file)
        case "new-header":
            try fixture.appendData(native, fixture.source.data(native))
        default:
            fixture.observations.set(nil, generation: nil)
        }
        #expect(await eventually { tab.activity == .unknown && !tab.isWatchingForCompletion })
        #expect(!tab.capabilities.lifecycle && !tab.hasUnseenActivity && settled == 0)
        #expect(
            RemoteCommands.snapshot(fixture.source.model).tabs.first { $0.id == tab.id.uuidString }?.capabilities?
                .lifecycle == false)
    }

    @Test func interruptedAttachmentStaysStoppedAndItsNextSubmissionDoesNotReplay() async throws {
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.source.newTab()
        let native = try fixture.rollout(tab, events: [("task_started", "old"), ("task_complete", "old")])
        tab.noteInterrupted()
        await fixture.bind()
        #expect(tab.nativeSessionID == native && tab.activity == .interrupted)
        #expect(!tab.isWatchingForCompletion)
        tab.noteTurnStarted()
        #expect(tab.activity == .unknown && tab.isWatchingForCompletion)
        var settled = 0
        tab.onSettle = { settled += 1 }
        try fixture.append(native, events: [("task_complete", "old"), ("task_started", "new")])
        #expect(await eventually { tab.activity == .working })
        try fixture.append(native, events: [("task_complete", "new")])
        #expect(await eventually { tab.activity == .idle && settled == 1 })
    }

    @Test func restartRetainsTheTranscriptAndReadsOnlyNewTurnEvents() async throws {
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let old = try await fixture.source.newTab()
        let native = try fixture.rollout(old, events: [("task_started", "first"), ("task_complete", "first")])
        await fixture.bind()
        #expect(await eventually { old.activity == .idle })
        fixture.source.model.restartTab(id: old.id)
        let tab = try #require(fixture.source.model.tabs.first)
        #expect(tab !== old && tab.controller.processGeneration != old.controller.processGeneration)
        let retained = try #require(tab.spec.sessionFile)
        #expect(GrokPaths.canonicalPath(retained.path) == GrokPaths.canonicalPath(fixture.source.file(native).path))
        #expect(tab.nativeSessionID == native && tab.capabilities.lifecycle)
        tab.noteTurnStarted()
        var settled = 0
        tab.onSettle = { settled += 1 }
        try fixture.append(native, events: [("task_complete", "first"), ("task_started", "next")])
        #expect(await eventually { tab.activity == .working })
        try fixture.append(native, events: [("task_complete", "next")])
        #expect(await eventually { tab.activity == .idle && settled == 1 })
    }

    @Test(arguments: [false, true])
    func aDelayedVerifiedResultCannotAttachToAClosedOrRestartedTab(restarted: Bool) async throws {
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.source.newTab()
        let native = try fixture.rollout(tab, events: [("task_started", "first")])
        await fixture.bind()
        #expect(await eventually { tab.activity == .working })
        fixture.observations.pauseNextResult()
        fixture.source.model.recordStartedCodexSessions()
        let pending = try #require(fixture.source.model.codexBindingTask)
        #expect(await eventually { fixture.observations.isPaused })
        if restarted { fixture.source.model.restartTab(id: tab.id) } else { fixture.source.model.closeTab(tab.id) }
        fixture.observations.release()
        await pending.value
        #expect(!tab.isWatchingForCompletion)
        #expect(tab.activity != .working)
        if restarted {
            let replacement = try #require(fixture.source.model.tabs.first)
            #expect(replacement.nativeSessionID == native)
            #expect(replacement.activity == .unknown && !replacement.isWatchingForCompletion)
        } else {
            #expect(fixture.source.model.tabs.isEmpty)
        }
    }

}

private struct LateCodexPush: Decodable {
    struct Payload: Decodable {
        struct APS: Decodable {
            let event: String?
            let state: RemoteActivityState?
            enum CodingKeys: String, CodingKey {
                case event
                case state = "content-state"
            }
        }
        struct Sigil: Decodable { let data: String }
        let aps: APS
        let sigil: Sigil?
    }
    let token: String
    let pushType: String
    let payload: Payload
    var state: RemoteActivityState? { payload.aps.state }
    var event: String? { payload.aps.event }
    var data: String? { payload.sigil?.data }
}

@MainActor
private func capturedPushes(_ relay: RelayFixture) throws -> [LateCodexPush] {
    guard FileManager.default.fileExists(atPath: relay.apnsCapture.path) else { return [] }
    return try String(contentsOf: relay.apnsCapture, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(LateCodexPush.self, from: Data($0.utf8))
    }
}

/// Generated homes and CLI only. All late-binding kernel observations are
/// synthetic and generation-scoped, through the production validation path.
@MainActor
private final class LateCodexFixture {
    let source: CodexBindingFixture
    let observations = LateCodexObservations()

    init() throws {
        source = try CodexBindingFixture()
        let observations = observations
        source.model.codexTranscriptResolver = { generation, root, sessions, cwd in
            let result = CodexSessionBinding.resolveTranscript(
                process: generation, historyRoot: root, sessions: sessions, workingDirectory: cwd,
                snapshot: { generation, _ in observations.read(generation) })
            observations.delayResult()
            return result
        }
    }

    func cleanup() {
        observations.release()
        source.store.stop()
        source.cleanup()
    }

    func rollout(_ tab: TerminalTab, events: [(String, String)]) throws -> String {
        let native = UUID().uuidString.lowercased()
        try source.data(native).write(to: source.file(native))
        try append(native, events: events)
        try observe(tab, files: [source.file(native)])
        return native
    }

    func observe(_ tab: TerminalTab, files: [URL]) throws {
        let generation = try #require(tab.controller.processGeneration)
        var held: [ProcessOpenFiles.FileIdentity: ProcessOpenFiles.HeldFile] = [:]
        for file in files {
            var info = stat()
            #expect(lstat(file.path, &info) == 0)
            let identity = ProcessOpenFiles.FileIdentity(
                path: GrokPaths.canonicalPath(file.path), device: UInt32(bitPattern: info.st_dev), inode: info.st_ino)
            held[identity] = .init(
                identity: identity, writable: true,
                bornAt: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000)
        }
        observations.set(
            .init(nodes: [.init(generation: generation, parent: getpid())], files: held), generation: generation)
    }

    func bind() async {
        await source.store.reload()
        await source.awaitBinding()
    }

    func append(_ native: String, events: [(String, String)]) throws {
        // Fractional precision avoids rounding a generated event before child birth.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (type, turn) in events {
            try appendData(
                native,
                JSONSerialization.data(withJSONObject: [
                    "timestamp": formatter.string(from: Date().addingTimeInterval(1)), "type": "event_msg",
                    "payload": ["type": type, "turn_id": turn],
                ]) + Data([0x0A]))
        }
    }

    func appendData(_ native: String, _ data: Data) throws {
        let handle = try FileHandle(forWritingTo: source.file(native))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private final class LateCodexObservations: @unchecked Sendable {
    private let condition = NSCondition()
    private var snapshot: ProcessOpenFiles.Snapshot?
    private var generation: ChildProcessGeneration?
    private var shouldPause = false
    private var paused = false
    var isPaused: Bool { condition.withLock { paused } }
    func set(_ snapshot: ProcessOpenFiles.Snapshot?, generation: ChildProcessGeneration?) {
        condition.withLock {
            self.snapshot = snapshot
            self.generation = generation
        }
    }
    func read(_ generation: ChildProcessGeneration) -> ProcessOpenFiles.Snapshot? {
        condition.withLock { self.generation == generation ? snapshot : nil }
    }
    func pauseNextResult() { condition.withLock { shouldPause = true } }
    func delayResult() {
        condition.lock()
        defer { condition.unlock() }
        guard shouldPause else { return }
        shouldPause = false
        paused = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(3)
        while paused, condition.wait(until: deadline) {}
        paused = false
    }
    func release() {
        condition.withLock {
            paused = false
            shouldPause = false
            condition.broadcast()
        }
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}
