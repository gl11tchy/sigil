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
    private let process = Process()
    private let root: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let portFile = root.appendingPathComponent("port")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", repo.appendingPathComponent("Sidereal/test/relay-fixture.mjs").path]
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
        origin = "http://127.0.0.1:\(try String(contentsOf: portFile, encoding: .utf8))"
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
