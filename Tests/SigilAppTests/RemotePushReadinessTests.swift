import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct RemotePushReadinessTests {
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
        remote.noteTab(tab, model: fixture.model)
        remote.resumeIfPaired(model: fixture.model)
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
    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func readinessEventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(4)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    return condition()
}
