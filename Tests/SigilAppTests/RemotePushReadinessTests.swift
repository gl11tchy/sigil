import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct RemotePushReadinessTests {
    @Test(arguments: [false, true])
    func queuedMacActivitiesKeepOriginalTimestampsAndTypeSpecificExpiry(ending: Bool) async throws {
        let context = try await ReadyPushContext()
        defer { context.cleanup() }
        try context.relay.releaseRoute()
        #expect(await readinessEventually { context.remote.isHostReadyForPushes })
        let phone = try RelayPhone(origin: context.relay.origin)
        defer { phone.close() }
        let challenge = try await phone.route(["ticket": context.ticket])
        let registered = try await phone.request(
            .init(
                challenge: challenge, sequence: 1, action: "activity", tabID: context.tab.id.uuidString,
                text: String(repeating: "cd", count: 40)), key: context.device)
        #expect(registered.ok)
        context.remote.noteTab(context.tab, model: context.fixture.model, suppressAlerts: true)
        phone.close()
        #expect(await readinessEventually { context.remote.status == "Phone disconnected" })
        let gate = ReadyPushGate()
        defer { gate.release() }
        context.remote.beforeQueuedPushSend = { await gate.holdOnce() }
        let issued = Int(context.clock.now.timeIntervalSince1970)
        try await context.interrupt()
        #expect(await readinessEventually { gate.paused })
        if ending {
            context.fixture.model.closeTab(context.tab.id)
            context.remote.forgetTab(context.tab.id)
        }
        context.clock.now = context.clock.now.addingTimeInterval(30)
        gate.release()
        #expect(await readinessEventually { context.relay.captureCount == 2 })
        let lines = try String(contentsOf: context.relay.capture, encoding: .utf8).split(separator: "\n")
        let requests = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let activity = try #require(requests.compactMap { $0 }.first { $0["pushType"] as? String == "liveactivity" })
        let payload = try #require(activity["payload"] as? [String: Any])
        let aps = try #require(payload["aps"] as? [String: Any])
        #expect(aps["timestamp"] as? Int == issued)
        #expect(aps["event"] as? String == (ending ? "end" : "update"))
        #expect(activity["expiration"] as? Int == issued + (ending ? 900 : 60))
    }

    @Test func aQueuedMacAlertKeepsSealedIssuanceAndWireExpiryWhenItsClockAdvances() async throws {
        let context = try await ReadyPushContext()
        defer { context.cleanup() }
        let issued = Int(context.clock.now.timeIntervalSince1970)
        try await context.interrupt()
        #expect(context.remote.pendingPushCount == 1)
        context.clock.now = context.clock.now.addingTimeInterval(30)
        try context.relay.releaseRoute()
        #expect(await readinessEventually { context.relay.captureCount == 1 })
        let captured = try context.relay.firstAlert(key: context.device)
        let alert = try #require(captured)
        let expiration = try context.relay.firstExpiration()
        #expect(alert.issuedAt == issued)
        #expect(expiration == issued + 300)
        #expect(context.relay.allocationCount == 1 && !context.relay.sawPolicyClose)
    }

    @Test func expiredQueuedAlertsDoNotGainANewLifetimeWhenReadyArrives() async throws {
        let context = try await ReadyPushContext()
        defer { context.cleanup() }
        try await context.interrupt()
        // The batching callback is asynchronous: never advance its clock until
        // the original event has actually entered the queue. A fixed sleep can
        // otherwise create a future-dated event rather than expire an old one.
        try #require(await readinessEventually { context.remote.pendingPushCount == 1 })
        context.clock.now = context.clock.now.addingTimeInterval(301)
        try context.relay.releaseRoute()
        #expect(await readinessEventually { context.remote.isHostReadyForPushes })
        #expect(await readinessEventually { context.remote.pendingPushCount == 0 })
        #expect(context.relay.captureCount == 0 && !context.relay.sawPolicyClose)
    }

    @Test(arguments: [false, true])
    func stopAndDisconnectClearQueuedPushes(revoke: Bool) async throws {
        let context = try await ReadyPushContext()
        defer { context.cleanup() }
        try await context.interrupt()
        #expect(context.remote.pendingPushCount == 1)
        context.remote.stop(revoke: revoke)
        #expect(context.remote.pendingPushCount == 0 && !context.remote.isHostReadyForPushes)
        try context.relay.releaseRoute()
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.relay.captureCount == 0)
    }

    @Test func anAlertRaisedDuringReconnectSleepUsesTheNextReadyOnTheSameRoom() async throws {
        let context = try await ReadyPushContext()
        defer { context.cleanup() }
        try context.relay.releaseRoute()
        #expect(await readinessEventually { context.remote.isHostReadyForPushes })
        try context.relay.holdRoute()
        try context.relay.dropHost()
        #expect(await readinessEventually { context.remote.status == "Reconnecting…" })
        try await context.interrupt()
        #expect(context.remote.pendingPushCount == 1 && context.relay.captureCount == 0)
        #expect(await readinessEventually { context.relay.heldRouteCount >= 2 })
        try context.relay.releaseRoute()
        #expect(await readinessEventually { context.relay.captureCount == 1 })
        let capturedAlert = try context.relay.firstAlert(key: context.device)
        let alert = try #require(capturedAlert)
        #expect(alert.issuedAt == Int(context.clock.now.timeIntervalSince1970))
        let expiration = try context.relay.firstExpiration()
        #expect(expiration == Int(context.clock.now.timeIntervalSince1970) + 300)
        #expect(context.relay.allocationCount == 1 && !context.relay.sawPolicyClose)
    }

    @Test(arguments: [false, true])
    func unauthenticatedPeersRetainAlertsAndAuthenticationRetainsUnreconciledEnds(retire: Bool) async throws {
        let context = try await ReadyPushContext()
        defer { context.cleanup() }
        try context.relay.releaseRoute()
        #expect(await readinessEventually { context.remote.isHostReadyForPushes })
        let first = try RelayPhone(origin: context.relay.origin)
        let firstChallenge = try await first.route(["ticket": context.ticket])
        _ = try await first.request(.init(challenge: firstChallenge, sequence: 1, action: "state"), key: context.device)
        let activity = try await first.request(
            .init(
                challenge: firstChallenge, sequence: 2, action: "activity", tabID: context.tab.id.uuidString,
                text: String(repeating: "cd", count: 40)), key: context.device)
        #expect(activity.ok)
        context.remote.noteTab(context.tab, model: context.fixture.model, suppressAlerts: true)
        first.close()
        #expect(await readinessEventually { context.remote.status == "Phone disconnected" })
        let gate = ReadyPushGate()
        defer { gate.release() }
        context.remote.beforeQueuedPushSend = { await gate.holdOnce() }
        try await context.interrupt()
        #expect(await readinessEventually { gate.paused })
        context.fixture.model.closeTab(context.tab.id)
        context.remote.forgetTab(context.tab.id)
        #expect(context.remote.pendingPushCount == 2)
        let phone = try RelayPhone(origin: context.relay.origin)
        defer { phone.close() }
        let challenge = try await phone.route(["ticket": context.ticket])
        #expect(context.remote.pendingPushCount == 2)  // peer alone is not authentication
        _ = try await phone.request(.init(challenge: challenge, sequence: 1, action: "state"), key: context.device)
        #expect(context.remote.pendingPushCount == 1)  // the end still owns its activity
        if retire {
            let ended = try await phone.request(
                .init(
                    challenge: challenge, sequence: 2, action: "activity", tabID: context.tab.id.uuidString, text: ""),
                key: context.device)
            #expect(ended.ok && context.remote.pendingPushCount == 0)
        }
        gate.release()
        #expect(await readinessEventually { context.remote.pendingPushCount == 0 })
        if retire {
            #expect(context.relay.captureCount == 0)
        } else {
            #expect(await readinessEventually { context.relay.captureCount == 1 })
            let captured = try String(contentsOf: context.relay.capture, encoding: .utf8)
            #expect(captured.contains("\"event\":\"end\""))
            #expect(!captured.contains("\"pushType\":\"alert\""))
        }
    }

    @Test func replacingAnActivityTokenCannotSendItsPausedOldUpdate() async throws {
        let context = try await ReadyPushContext()
        defer { context.cleanup() }
        try context.relay.releaseRoute()
        #expect(await readinessEventually { context.remote.isHostReadyForPushes })
        let phone = try RelayPhone(origin: context.relay.origin)
        defer { phone.close() }
        let challenge = try await phone.route(["ticket": context.ticket])
        _ = try await phone.request(.init(challenge: challenge, sequence: 1, action: "state"), key: context.device)
        _ = try await phone.request(
            .init(
                challenge: challenge, sequence: 2, action: "activity", tabID: context.tab.id.uuidString,
                text: String(repeating: "cd", count: 40)), key: context.device)
        context.remote.noteTab(context.tab, model: context.fixture.model, suppressAlerts: true)
        phone.close()
        #expect(await readinessEventually { context.remote.status == "Phone disconnected" })
        let gate = ReadyPushGate()
        defer { gate.release() }
        context.remote.beforeQueuedPushSend = { await gate.holdOnce() }
        try await context.interrupt()
        #expect(await readinessEventually { gate.paused })
        let replacementPhone = try RelayPhone(origin: context.relay.origin)
        defer { replacementPhone.close() }
        let replacementChallenge = try await replacementPhone.route(["ticket": context.ticket])
        _ = try await replacementPhone.request(
            .init(challenge: replacementChallenge, sequence: 1, action: "state"), key: context.device)
        let replaced = try await replacementPhone.request(
            .init(
                challenge: replacementChallenge, sequence: 2, action: "activity", tabID: context.tab.id.uuidString,
                text: String(repeating: "ef", count: 40)), key: context.device)
        #expect(replaced.ok && context.remote.pendingPushCount == 0)
        gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.relay.captureCount == 0)
    }

    @Test(arguments: [false, true])
    func aPausedOldWriteCannotCrossAReopenedConnectionOrPairing(repair: Bool) async throws {
        let context = try await ReadyPushContext()
        defer { context.cleanup() }
        try context.relay.releaseRoute()
        #expect(await readinessEventually { context.remote.isHostReadyForPushes })
        let gate = ReadyPushGate()
        defer { gate.release() }
        context.remote.beforeQueuedPushSend = { await gate.holdOnce() }
        try await context.interrupt()
        #expect(await readinessEventually { gate.paused })
        if repair {
            context.store.save(
                RemotePairing(
                    origin: context.relay.origin, deviceKey: RemoteCrypto.randomKey(),
                    ticket: RemoteCrypto.randomKey(), pushToken: String(repeating: "ef", count: 32),
                    pushEnvironment: "development"))
        }
        context.remote.resumeIfPaired(model: context.fixture.model)
        gate.release()
        #expect(await readinessEventually { context.remote.isHostReadyForPushes })
        #expect(context.remote.pendingPushCount == 0 && context.relay.captureCount == 0)
    }

    @Test func anActualMacAlertWaitsForTheRealRelayRouteAndRegistration() async throws {
        let relay = try await ReadyRelayFixture()
        defer { relay.stop() }
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let tab = try #require(fixture.model.newTab(in: fixture.directory("push-readiness")))
        let store = InMemoryRemotePairingStore()
        let device = RemoteCrypto.randomKey()
        store.save(
            RemotePairing(
                origin: relay.origin, deviceKey: device, ticket: RemoteCrypto.randomKey(),
                pushToken: String(repeating: "ab", count: 32), pushEnvironment: "development"))
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.resumeIfPaired(model: fixture.model)
        remote.noteTab(tab, model: fixture.model)
        #expect(await readinessEventually { relay.hasHeldRoute })
        tab.noteInterrupted()
        remote.noteTab(tab, model: fixture.model)
        // Existing production alert batching is 300 ms. Hold the route through
        // that callback, then release it; the fixture changes no production code.
        try await Task.sleep(for: .milliseconds(500))
        try relay.releaseRoute()
        #expect(await readinessEventually { relay.captureCount == 1 })
        #expect(!relay.sawPolicyClose)
        #expect(relay.allocationCount == 1)
        if let alert = try relay.firstAlert(key: device) {
            #expect(alert.kind == .stopped && alert.tabID == tab.id.uuidString)
        }
    }
}

/// Uses actual RemoteControl, actual relay protocol and an ordered WebSocket
/// proxy that withholds only the host challenge. Captures APNs locally.
@MainActor
final class ReadyRelayFixture {
    let root: URL
    let origin: String
    private let process: Process
    var capture: URL { root.appendingPathComponent("apns.jsonl") }
    var trace: URL { root.appendingPathComponent("trace.jsonl") }
    var hasHeldRoute: Bool { traces.contains { $0["heldHostRoute"] as? Bool == true } }
    var heldRouteCount: Int { traces.filter { $0["heldHostRoute"] as? Bool == true }.count }
    var sawPolicyClose: Bool { traces.contains { $0["backendClose"] as? Int == 1008 } }
    var allocationCount: Int { traces.compactMap { $0["allocations"] as? Int }.max() ?? 0 }
    var captureCount: Int { (try? String(contentsOf: capture, encoding: .utf8).split(separator: "\n").count) ?? 0 }
    private var traces: [[String: Any]] {
        guard let text = try? String(contentsOf: trace, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sigil-ready-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let port = root.appendingPathComponent("port")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", repo.appendingPathComponent("Sidereal/test/ready-relay-fixture.mjs").path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SIGIL_TEST_PORT_FILE": port.path,
            "SIGIL_TEST_APNS_CAPTURE": root.appendingPathComponent("apns.jsonl").path,
            "SIGIL_TEST_TRACE": root.appendingPathComponent("trace.jsonl").path,
            "SIGIL_TEST_ROUTE_RELEASE": root.appendingPathComponent("release-route").path,
            "SIGIL_TEST_DROP_HOST": root.appendingPathComponent("drop-host").path,
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(4)
        while !FileManager.default.fileExists(atPath: port.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        origin = "http://127.0.0.1:\(try String(contentsOf: port, encoding: .utf8))"
    }

    func releaseRoute() throws { try Data().write(to: root.appendingPathComponent("release-route")) }
    func holdRoute() throws { try FileManager.default.removeItem(at: root.appendingPathComponent("release-route")) }
    func dropHost() throws { try Data().write(to: root.appendingPathComponent("drop-host")) }
    func firstAlert(key: String) throws -> RemoteAlert? {
        guard FileManager.default.fileExists(atPath: capture.path) else { return nil }
        guard let line = try String(contentsOf: capture, encoding: .utf8).split(separator: "\n").first else {
            return nil
        }
        let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let payload = request?["payload"] as? [String: Any]
        let sigil = payload?["sigil"] as? [String: Any]
        let data = try #require(sigil?["data"] as? String)
        return try RemoteCrypto.open(data, key: key, direction: RemoteAlert.direction)
    }
    func firstExpiration() throws -> Int? {
        guard let line = try String(contentsOf: capture, encoding: .utf8).split(separator: "\n").first else {
            return nil
        }
        let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        return request?["expiration"] as? Int
    }
    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ReadyPushClock { var now = Date() }

@MainActor
private final class ReadyPushContext {
    let relay: ReadyRelayFixture
    let fixture: PhoneCommandFixture
    let tab: TerminalTab
    let store = InMemoryRemotePairingStore()
    let device = RemoteCrypto.randomKey()
    let ticket = RemoteCrypto.randomKey()
    let clock = ReadyPushClock()
    let remote: RemoteControl
    init() async throws {
        relay = try await ReadyRelayFixture()
        fixture = try PhoneCommandFixture()
        tab = try #require(fixture.model.newTab(in: fixture.directory("queued-push")))
        let clock = clock
        remote = RemoteControl(store: store, pushClock: { clock.now })
        store.save(
            RemotePairing(
                origin: relay.origin, deviceKey: device, ticket: ticket,
                pushToken: String(repeating: "ab", count: 32), pushEnvironment: "development"))
        remote.resumeIfPaired(model: fixture.model)
        remote.noteTab(tab, model: fixture.model)
        #expect(await readinessEventually { relay.hasHeldRoute })
    }
    func interrupt() async throws {
        tab.noteInterrupted()
        remote.noteTab(tab, model: fixture.model)
        // noteTab batches evaluation asynchronously. A sleep longer than its
        // 300 ms delay does not prove the callback ran on a busy CI actor.
        // Every caller holds routing or a send gate, so the queued push stays
        // observable until the test deliberately releases it.
        try #require(await readinessEventually { remote.pendingPushCount > 0 })
    }
    func cleanup() {
        remote.stop()
        fixture.cleanup()
        relay.stop()
    }
}

@MainActor
private final class ReadyPushGate {
    private var used = false
    private var continuation: CheckedContinuation<Void, Never>?
    var paused: Bool { continuation != nil }
    func holdOnce() async {
        guard !used else { return }
        used = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func readinessEventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(4)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    return condition()
}
