import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
struct RemoteRelayTests {
    @Test @MainActor func disconnectTellsTheConnectedPhoneItsPairingIsRevoked() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let model = AppModel()
        let remote = RemoteControl(store: InMemoryRemotePairingStore())
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: model)
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }
        remote.stop(revoke: true)
        let frame = try await paired.phone.receive()
        #expect(frame["error"] == "unauthorized")
    }

    @Test @MainActor func pairingThatCannotBeSavedIsReported() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let model = AppModel()
        let remote = RemoteControl(store: UnsavableStore())
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: model)
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }
        #expect(remote.isPaired)
        #expect(remote.error == "Sigil could not save this pairing in Keychain. It ends when Sigil quits.")
    }

    @Test @MainActor func savedNewPairingEndsAnEarlierFailedRevoke() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let model = AppModel()
        let store = InMemoryRemotePairingStore()
        store.revokeFailed = true
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: model)
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }
        #expect(!store.revokeFailed)
        #expect(!remote.revokeFailed)
    }

    @Test @MainActor func oversizedRequestGetsAnErrorReplyAndKeepsThePhonePaired() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let model = AppModel()
        let remote = RemoteControl(store: InMemoryRemotePairingStore())
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: model)
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }
        let oversized = RemoteRequest(
            challenge: paired.challenge, sequence: 2, action: "chats", text: String(repeating: "b", count: 8_193))
        let reply = try await paired.phone.request(oversized, key: paired.device)
        #expect(!reply.ok)
        #expect(reply.sequence == 2)
        #expect(reply.error == "Too long to send. Shorten it and try again.")
        let state = try await paired.phone.request(
            RemoteRequest(challenge: paired.challenge, sequence: 3, action: "state"), key: paired.device)
        #expect(state.ok)
    }

    @Test @MainActor func newPeerIsNotShownAsConnectedUntilItAuthenticates() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let device = RemoteCrypto.randomKey()
        let ticket = RemoteCrypto.randomKey()
        let store = InMemoryRemotePairingStore()
        store.save(RemotePairing(origin: relay.origin, deviceKey: device, ticket: ticket))
        let model = AppModel()
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.resumeIfPaired(model: model)
        try await waitUntil { remote.status == "Phone disconnected" }
        let phone = try RelayPhone(relay: relay)
        defer { phone.close() }
        let challenge = try await phone.route(["ticket": ticket])
        #expect(
            try await phone.request(RemoteRequest(challenge: challenge, sequence: 1, action: "state"), key: device).ok)
        #expect(remote.status == "Phone connected")
        let silent = try RelayPhone(relay: relay)
        defer { silent.close() }
        _ = try await silent.route(["ticket": ticket])
        try await waitUntil { remote.status != "Phone connected" }
        #expect(remote.status == "Phone disconnected")
    }

    @Test @MainActor func pairingRoomStopsRoutingOnceThePairedPhoneLeaves() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let model = AppModel()
        let remote = RemoteControl(store: InMemoryRemotePairingStore())
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: model)
        let paired = try await relay.pair(remote)
        paired.phone.close()
        var resumed = false
        for _ in 0..<100 where !resumed {
            let phone = try RelayPhone(relay: relay)
            resumed = (try? await phone.route(["ticket": paired.ticket])) != nil
            phone.close()
            if !resumed { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(resumed)
        let intruder = try RelayPhone(relay: relay)
        defer { intruder.close() }
        let hello = try? await intruder.route(["room": paired.room])
        #expect(hello == nil)
        #expect(intruder.closeCode == .policyViolation)
    }

    @Test @MainActor func deletedRoomIsReplacedOnTheFirstRefusedReconnect() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let model = AppModel()
        let store = InMemoryRemotePairingStore()
        store.save(
            RemotePairing(origin: relay.origin, deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.resumeIfPaired(model: model)
        try await waitUntil { remote.status == "Phone disconnected" }
        try await relay.restartWithoutRooms()
        try await waitUntil { remote.status == "Reconnecting…" }
        let dropped = ContinuousClock.now
        try await waitUntil(for: .seconds(12)) { remote.status == "Phone disconnected" }
        #expect(remote.status == "Phone disconnected")
        #expect(ContinuousClock.now - dropped < .seconds(5))
    }

    @MainActor private func waitUntil(for timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class UnsavableStore: RemotePairingStore {
    var revokeFailed = false
    func load() -> RemotePairing? { nil }
    func save(_: RemotePairing) -> Bool { false }
    func clear() -> Bool { true }
}

/// Sidereal's loopback relay fixture, for one test.
@MainActor
final class RelayFixture {
    let origin: String
    let phoneOrigin = "http://localhost:3099"
    private var process = Process()
    private let root: URL
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let portFile = root.appendingPathComponent("port")
        process = try await Self.launch(
            [repo.appendingPathComponent("Sidereal/test/relay-fixture.mjs").path], portFile: portFile)
        origin = "http://127.0.0.1:\(try String(contentsOf: portFile, encoding: .utf8))"
    }

    /// Replaces the relay on the same port. Every room is gone and the host is
    /// dropped, as when the relay deletes a room at its 24 h limit.
    func restartWithoutRooms() async throws {
        process.terminate()
        process.waitUntilExit()
        let port = try #require(URLComponents(string: origin)?.port)
        let server = repo.appendingPathComponent("Sidereal/server.mjs").absoluteString
        let script = """
            import { writeFileSync } from 'node:fs';
            import { createRelay } from '\(server)';
            const relay = createRelay({ publicOrigin: 'http://localhost:3099' });
            relay.server.listen(\(port), '127.0.0.1', () => {
              writeFileSync(process.env.SIGIL_TEST_PORT_FILE, '\(port)', { mode: 0o600 });
            });
            process.on('SIGTERM', () => relay.close());
            """
        process = try await Self.launch(
            ["--input-type=module", "-e", script], portFile: root.appendingPathComponent("restarted"))
    }

    private static func launch(_ arguments: [String], portFile: URL) async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["SIGIL_TEST_PORT_FILE": portFile.path]) {
            _, new in new
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return process
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Waits for the Mac's QR link, then pairs a new phone through the relay.
    func pair(_ remote: RemoteControl) async throws -> PairedPhone {
        for _ in 0..<250 {
            if remote.pairingURL != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let link = try #require(remote.pairingURL)
        var parts = URLComponents()
        parts.query = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.fragment)
        let room = try #require(parts.queryItems?.first { $0.name == "room" }?.value)
        let bootstrap = try #require(parts.queryItems?.first { $0.name == "key" }?.value)
        let phone = try RelayPhone(relay: self)
        let challenge = try await phone.route(["room": room])
        let device = RemoteCrypto.randomKey()
        let reply = try await phone.request(
            RemoteRequest(challenge: challenge, sequence: 1, action: "pair", text: device), key: bootstrap,
            replyKey: device)
        #expect(reply.ok)
        return PairedPhone(
            phone: phone, room: room, device: device, challenge: challenge, ticket: try #require(reply.ticket))
    }
}

struct PairedPhone {
    let phone: RelayPhone
    let room: String
    let device: String
    let challenge: String
    let ticket: String
}

/// A phone's WebSocket to the relay, bounded so a silent Mac cannot hang a test.
@MainActor
final class RelayPhone {
    private let network = URLSession(configuration: .ephemeral)
    private let socket: URLSessionWebSocketTask
    private let timeout: Task<Void, Never>

    init(relay: RelayFixture) throws {
        var endpoint = try #require(URLComponents(string: relay.origin))
        endpoint.scheme = "ws"
        endpoint.path = "/connect"
        endpoint.queryItems = [URLQueryItem(name: "role", value: "phone")]
        var request = URLRequest(url: try #require(endpoint.url))
        request.setValue(relay.phoneOrigin, forHTTPHeaderField: "Origin")
        let socket = network.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    /// Sends the sealed route and returns the Mac's challenge.
    func route(_ route: [String: String]) async throws -> String {
        let key = try #require(try await receive()["route"])
        try await send(["route": RemoteCrypto.seal(route, key: key, direction: "relay-phone")])
        return try #require(try await receive()["hello"])
    }

    func request(_ request: RemoteRequest, key: String, replyKey: String? = nil) async throws -> RemoteReply {
        try await send(["data": RemoteCrypto.seal(request, key: key, direction: "phone")])
        let frame = try await receive()
        return try RemoteCrypto.open(try #require(frame["data"]), key: replyKey ?? key, direction: "mac")
    }

    func send(_ frame: [String: String]) async throws {
        let bytes = try JSONEncoder().encode(frame)
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    func receive() async throws -> [String: String] {
        let bytes: Data
        switch try await socket.receive() {
        case .string(let text): bytes = Data(text.utf8)
        case .data(let data): bytes = data
        @unknown default: throw RemoteError.invalidMessage
        }
        return try JSONDecoder().decode([String: String].self, from: bytes)
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { socket.closeCode }

    func close() {
        timeout.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        network.invalidateAndCancel()
    }
}

@Suite(.serialized)
struct RemoteEventStreamTests {
    /// After `watch`, output on the Mac reaches the phone as sealed event frames
    /// with only the changed rows, and a selection change carries the new tab list.
    @Test @MainActor func watchStreamsChangesWithoutPolling() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("stream-folder")
        let feed = fixture.root.appendingPathComponent("feed")
        let script = """
            #!/bin/sh
            echo READY
            while true; do
              if [ -f '\(feed.path)' ]; then cat '\(feed.path)'; rm -f '\(feed.path)'; fi
              sleep 0.05
            done
            """
        try Data(script.utf8).write(to: fixture.executable)
        let tab = try #require(fixture.model.newTab(in: folder))
        for _ in 0..<200 {
            if tab.controller.remoteSnapshot().contains("READY") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let remote = fixture.model.remoteControl
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: fixture.model)
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }

        let watched = try await paired.phone.request(
            RemoteRequest(challenge: paired.challenge, sequence: 2, action: "watch"), key: paired.device)
        #expect(watched.ok)
        #expect(watched.state?.screen?.rows.contains { $0.t == "READY" } == true)

        try Data("\u{1b}[31mFROM_MAC\u{1b}[0m\n".utf8).write(to: feed)
        let event: RemoteReply = try await paired.phone.receiveReply(key: paired.device)
        #expect(event.event == true)
        #expect(event.sequence == 0)
        #expect(event.challenge == paired.challenge)
        let rows = try #require(event.state?.screen?.rows)
        let row = try #require(rows.first { $0.t == "FROM_MAC" })
        #expect(row.s == [[0, 8, 1, -1, 0]])
        #expect(rows.count < 10)
        #expect(event.state?.screen?.palette == nil)
        #expect(event.state?.terminal == "")

        // A second tab: the event lists both tabs, selects the new one, and starts its screen over.
        let second = try #require(fixture.model.newTab(in: folder))
        var selectionEvent: RemoteReply
        repeat {
            selectionEvent = try await paired.phone.receiveReply(key: paired.device)
        } while selectionEvent.state?.selectedTabID != second.id.uuidString
        #expect(selectionEvent.state?.tabs.count == 2)
        #expect(selectionEvent.state?.screen?.palette != nil)

        // Leaving stops the stream: nothing arrives for the next change.
        paired.phone.close()
        try await Task.sleep(for: .milliseconds(300))
        try Data("AFTER\n".utf8).write(to: feed)
        try await Task.sleep(for: .milliseconds(300))
        #expect(remote.status == "Phone disconnected")
    }
}

struct RemoteEventFramingTests {
    @Test func rowsAreSplitByEncodedSizeAndOversizedRowsLoseTheirStyles() throws {
        var base = RemoteReply(challenge: "c", sequence: 0, event: true)
        base.state = RemoteState(tabs: [], selectedTabID: "T", terminal: "", screen: nil, mac: "m")
        // Every character styled differently: the runs, not the text, carry the weight.
        let runs = (0..<200).map { [$0, 1, $0 % 256, -1, 0] }
        let rows = (0..<40).map { RemoteScreen.Row(i: $0, t: String(repeating: "x", count: 200), s: runs) }
        let screen = RemoteScreen(
            tab: "T", gen: 1, first: 0, end: 40, rows: rows, palette: ["000000"], fg: "ffffff", bg: "000000")
        let frames = RemoteControl.frames(base: base, screen: screen, limit: 20_000)
        #expect(frames.count > 1)
        for frame in frames {
            #expect(try JSONEncoder().encode(frame).count <= 20_000)
        }
        #expect(frames[0].state?.screen?.palette == ["000000"])
        #expect(frames[1].state?.screen?.palette == nil)
        #expect(frames.flatMap { $0.state?.screen?.rows.map(\.i) ?? [] } == Array(0..<40))
        #expect(frames.allSatisfy { $0.state?.screen?.tab == "T" && $0.state?.screen?.end == 40 })

        let huge = RemoteScreen.Row(
            i: 0, t: String(repeating: "y", count: 100), s: (0..<3_000).map { [$0 % 100, 1, $0 % 256, 4, 1] })
        let single = RemoteControl.frames(
            base: base, screen: RemoteScreen(gen: 1, first: 0, end: 1, rows: [huge]), limit: 20_000)
        #expect(single.count == 1)
        #expect(single[0].state?.screen?.rows.first?.s == nil)
        #expect(single[0].state?.screen?.rows.first?.t.count == 100)
        #expect(RemoteControl.frames(base: base, screen: nil).count == 1)
    }
}

extension RelayPhone {
    /// The next sealed frame from the Mac, whatever its sequence.
    func receiveReply(key: String) async throws -> RemoteReply {
        while true {
            let frame = try await receive()
            guard let data = frame["data"] else { continue }
            return try RemoteCrypto.open(data, key: key, direction: "mac")
        }
    }
}
