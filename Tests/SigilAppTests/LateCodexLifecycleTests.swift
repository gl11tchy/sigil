import Darwin
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct LateCodexLifecycleTests {
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

    @Test func aTurnCompletedBeforeAttachmentRestoresIdleWithoutAnUnreadDotOrAlert() async throws {
        let fixture = try LateCodexFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.source.newTab()
        tab.noteTurnStarted()
        let native = try fixture.rollout(tab, events: [("task_started", "first"), ("task_complete", "first")])
        _ = try await fixture.source.newTab()
        var settled = 0
        tab.onSettle = { settled += 1 }
        var phonePlanner = RemoteAlertPlanner()
        var alerts: [RemoteAlert] = []
        _ = phonePlanner.plan(tabID: tab.id.uuidString, status(tab))
        let original = tab.onActivityChange
        tab.onActivityChange = {
            original?()
            let plan = phonePlanner.plan(tabID: tab.id.uuidString, status(tab))
            if !tab.isCatchingUpLifecycle, let alert = plan.alert { alerts.append(alert) }
        }
        await fixture.bind()
        #expect(await eventually { tab.activity == .idle })
        #expect(settled == 0 && !tab.hasUnseenActivity && alerts.isEmpty)
        try fixture.append(native, events: [("task_complete", "first")])
        try fixture.append(native, events: [("task_started", "next")])
        #expect(await eventually { tab.activity == .working })
        try fixture.append(native, events: [("task_complete", "next")])
        #expect(await eventually { settled == 1 })
        #expect(alerts.map(\.kind) == [.finished])
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
        #expect(tab.spec.sessionFile == fixture.source.file(native))
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

    private func status(_ tab: TerminalTab) -> RemoteAlertPlanner.Snapshot {
        .init(status: tab.activity.statusName, since: 0, question: nil, title: "fixture")
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
