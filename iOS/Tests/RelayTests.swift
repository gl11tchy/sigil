import Foundation

/// Drives `RemoteConnection` through the real Sidereal relay against a stand-in Mac
/// that follows `RemoteControl.swift`: pair on the QR room, retire it, re-register
/// the ticket on a new room, and expect the phone back by ticket alone.
/// Runs only under `scripts/relay-e2e.sh`, which starts the relay.
@MainActor
enum RelayTests {
    static func pairsAndReconnectsByTicket(port: String) async throws {
        let origin = URL(string: "http://localhost:\(port)")!
        let mac = FakeMac(origin: origin)
        let room = try await mac.register()
        let link = "http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)"
        guard case .success(let parsed) = PairingLink.parse(link) else { throw TestFailure("link did not parse") }

        let phone = RemoteConnection()
        let watcher = Watcher()
        phone.delegate = watcher
        phone.pair(parsed)

        try await until("paired and connected") { watcher.saved?.ticket != nil && phone.phase == .connected }
        try Expect.equal(watcher.saved?.ticket, mac.ticket, "phone keeps the Mac's ticket")
        try Expect.equal(mac.deviceKey, watcher.saved?.deviceKey, "Mac holds the phone's device key")

        // The Mac retires the QR room after pairing; the phone must find it by ticket.
        mac.retireAndReRegister()
        try await until("reconnected by ticket") { mac.connections >= 2 && phone.phase == .connected }

        let reply = try await phone.request("input", text: "hello", tabID: "T1")
        try Expect.equal(reply.state?.terminal, "echo: hello", "command round trip")
        try Expect.equal(watcher.lastState?.selectedTabID, "T1", "delegate saw the snapshot")

        do {
            _ = try await phone.request("select", tabID: "missing")
            throw TestFailure("a Mac error must throw")
        } catch RemoteConnectionError.mac(let message) {
            try Expect.equal(message, "This tab is closed.", "Mac error text is shown as sent")
        }

        mac.revoke()
        try await until("revoked") { phone.phase == .revoked }
        phone.stop(forget: true)
        mac.stop()
    }

    /// The Mac accepts the phone and retires the QR room, but the reply with the ticket is lost.
    static func lostPairingReplyAsksForANewCode(port: String) async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        mac.dropPairReply = true
        let room = try await mac.register()
        guard case .success(let link) = PairingLink.parse("http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)")
        else { throw TestFailure("link did not parse") }
        let phone = RemoteConnection()
        let watcher = Watcher()
        phone.delegate = watcher
        phone.pair(link)
        try await until("Mac accepted the device key") { mac.deviceKey != nil }
        mac.retireAndReRegister()
        try await until("phone gives up and asks for a new code", timeout: 20) { phone.phase == .revoked }
        try Expect.true(watcher.saved == nil, "nothing saved without a ticket")
        try Expect.equal(watcher.failure, "Pairing did not finish. Scan a new code in Sigil.", "told to scan again")
        phone.stop(forget: true)
        mac.stop()
    }

    private static func until(_ what: String, timeout: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TestFailure("timed out waiting: \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    final class Watcher: RemoteConnectionDelegate {
        var saved: PairingCredential?
        var lastState: RemoteState?
        var failure: String?
        func connection(_ connection: RemoteConnection, didChange phase: RemoteConnection.Phase) {}
        func connection(_ connection: RemoteConnection, didReceive reply: RemoteReply, for action: String, tabID: String?) {
            lastState = reply.state
        }
        func connection(_ connection: RemoteConnection, didSave credential: PairingCredential) { saved = credential }
        func connection(_ connection: RemoteConnection, didFail message: String) { failure = message }
    }
}

/// The host half of the protocol, reduced to what the phone can observe.
@MainActor
final class FakeMac {
    struct Registered: Decodable {
        let room: String
        let hostToken: String
    }

    struct Request: Decodable {
        let challenge: String
        let sequence: Int
        let action: String
        let tabID: String?
        let text: String?
    }

    struct Reply: Encodable {
        struct Tab: Encodable {
            let id: String
            let title: String
            let status: String
        }
        struct State: Encodable {
            let tabs: [Tab]
            let selectedTabID: String?
            let terminal: String
            let capabilities = ["restart"]
            let tabsTruncated = false
        }
        let challenge: String
        let sequence: Int
        var ok = true
        var error: String?
        var state: State?
        var ticket: String?
    }

    let origin: URL
    let pairingKey = RemoteCrypto.randomKey()
    let ticket = RemoteCrypto.randomKey()
    private(set) var deviceKey: String?
    var dropPairReply = false
    private(set) var connections = 0
    private var socket: URLSessionWebSocketTask?
    private var peer: String?
    private var challenge = RemoteCrypto.randomKey()
    private var lastSequence = 0
    private var revoked = false
    private let session = URLSession(configuration: .ephemeral)

    init(origin: URL) { self.origin = origin }

    func register() async throws -> String {
        var request = URLRequest(url: origin.appendingPathComponent("rooms"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw TestFailure("room not created") }
        let registered = try JSONDecoder().decode(Registered.self, from: data)
        connect(registered)
        return registered.room
    }

    func retireAndReRegister() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        Task { _ = try? await register() }
    }

    /// Disconnect in Sigil tells the phone at once, then closes.
    func revoke() {
        revoked = true
        guard let socket, let peer else { return }
        Task { try? await send(["peer": peer, "error": "unauthorized"], on: socket) }
    }

    func stop() {
        socket?.cancel(with: .goingAway, reason: nil)
    }

    private func connect(_ registered: Registered) {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.scheme = "ws"
        parts.path = "/connect"
        parts.queryItems = [URLQueryItem(name: "role", value: "host")]
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(registered.hostToken)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: request)
        socket = ws
        peer = nil
        ws.resume()
        Task { @MainActor in
            while let message = try? await ws.receive() {
                guard case .string(let text) = message,
                    let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                else { continue }
                if let route = frame["route"] as? String {
                    let sealed = try RemoteCrypto.seal(
                        ["room": registered.room, "ticket": ticket], key: route, direction: "relay-host")
                    try await send(["route": sealed], on: ws)
                } else if frame["type"] as? String == "peer", let id = frame["peer"] as? String {
                    peer = id
                    connections += 1
                    challenge = RemoteCrypto.randomKey()
                    lastSequence = 0
                    try await send(["peer": id, "hello": challenge], on: ws)
                } else if let id = frame["peer"] as? String, id == peer, let data = frame["data"] as? String {
                    try await handle(data, peer: id, on: ws)
                }
            }
        }
    }

    private func handle(_ data: String, peer id: String, on ws: URLSessionWebSocketTask) async throws {
        guard !revoked,
            let request: Request = try? RemoteCrypto.open(data, key: deviceKey ?? pairingKey, direction: "phone"),
            request.challenge == challenge, request.sequence > lastSequence
        else {
            try await send(["peer": id, "error": "unauthorized"], on: ws)
            return
        }
        lastSequence = request.sequence
        if deviceKey == nil {
            guard request.action == "pair", let key = request.text, RemoteCrypto.isValidKey(key) else {
                try await send(["peer": id, "error": "unauthorized"], on: ws)
                return
            }
            deviceKey = key
        }
        if request.action == "pair", dropPairReply { return }
        var reply = Reply(challenge: request.challenge, sequence: request.sequence, ticket: ticket)
        switch request.action {
        case "pair", "state":
            reply.state = state("ready")
        case "input":
            reply.state = state("echo: \(request.text ?? "")")
        default:
            reply.ok = false
            reply.error = "This tab is closed."
        }
        let sealed = try RemoteCrypto.seal(reply, key: deviceKey!, direction: "mac")
        try await send(["peer": id, "data": sealed], on: ws)
    }

    private func state(_ terminal: String) -> Reply.State {
        Reply.State(tabs: [Reply.Tab(id: "T1", title: "Test", status: "idle")], selectedTabID: "T1", terminal: terminal)
    }

    private func send(_ object: [String: String], on ws: URLSessionWebSocketTask) async throws {
        try await ws.send(.string(String(decoding: try JSONEncoder().encode(object), as: UTF8.self)))
    }
}
