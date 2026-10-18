#if canImport(Sigil)
@testable import Sigil
#endif
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
        try await mac.retireAndReRegister()
        try await until("reconnected by ticket") { mac.connections >= 2 && phone.phase == .connected }

        let reply = try await phone.request("input", text: "hello", tabID: "T1")
        try Expect.equal(reply.state?.terminal, "echo: hello", "command round trip")
        try Expect.equal(watcher.lastState?.selectedTabID, "T1", "delegate saw the snapshot")

        // An unasked frame with sequence 0 is an event, not a stray reply.
        try await mac.pushEvent(rows: ["from mac"])
        try await until("event delivered") { watcher.events.count == 1 }
        try Expect.equal(watcher.events[0].state?.screen?.rows.map(\.t), ["from mac"], "event rows")
        try Expect.equal(phone.phase, .connected, "an event does not disturb the connection")

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
        try await mac.retireAndReRegister()
        try await until("phone gives up and asks for a new code", timeout: 20) { phone.phase == .revoked }
        try Expect.true(watcher.saved == nil, "nothing saved without a ticket")
        try Expect.equal(watcher.failure, "Pairing did not finish. Scan a new code in Sigil.", "told to scan again")
        phone.stop(forget: true)
        mac.stop()
    }

    static func rejectsReplayedEvents(port: String) async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        let room = try await mac.register()
        guard case .success(let link) = PairingLink.parse("http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)")
        else { throw TestFailure("link did not parse") }
        let phone = RemoteConnection()
        let watcher = Watcher()
        phone.delegate = watcher
        defer { phone.stop(forget: true); mac.stop() }
        phone.pair(link)
        try await until("connected") { phone.phase == .connected }
        try await mac.pushEvent(rows: ["current"], eventSequence: 2)
        try await until("current event") { watcher.events.count == 1 }
        try await mac.pushEvent(rows: ["replayed"], eventSequence: 2)
        try await mac.pushEvent(rows: ["older"], eventSequence: 1)
        _ = try await phone.request("state") // Same socket: all earlier events were processed.
        try Expect.equal(watcher.events.count, 1, "replayed events must not replace current output")
        try await mac.pushEvent(rows: ["new"], eventSequence: 3)
        try await until("next event") { watcher.events.count == 2 }
    }

    static func malformedReplyFailsThePendingRequest(port: String) async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        let room = try await mac.register()
        guard case .success(let link) = PairingLink.parse("http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)")
        else { throw TestFailure("link did not parse") }
        let phone = RemoteConnection()
        phone.pair(link)
        defer { phone.stop(forget: true); mac.stop() }
        try await until("connected") { phone.phase == .connected }
        var resolved = false
        var accepted = false
        Task { @MainActor in
            do { _ = try await phone.request("malformed"); accepted = true } catch {}
            resolved = true
        }
        try await until("malformed reply fails without leaking its continuation", timeout: 2) { resolved }
        try Expect.true(!accepted, "malformed state is never accepted")
    }

    static func legacyEventsCannotReplaceOutput(port: String) async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        mac.orderedEvents = false
        let room = try await mac.register()
        guard case .success(let link) = PairingLink.parse("http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)")
        else { throw TestFailure("link did not parse") }
        let phone = RemoteConnection()
        let watcher = Watcher()
        phone.delegate = watcher
        defer { phone.stop(forget: true); mac.stop() }
        phone.pair(link)
        try await until("connected") { phone.phase == .connected }
        try await mac.pushEvent(rows: ["unprotected"], eventSequence: nil)
        _ = try await phone.request("state")
        try Expect.equal(watcher.events.count, 0, "legacy push events cannot replace authenticated polled state")
        try Expect.true(!phone.supportsOrderedEvents, "legacy streaming disabled")
    }

    static func missingEventCounterFailsClosed(port: String) async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        let room = try await mac.register()
        guard case .success(let link) = PairingLink.parse("http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)")
        else { throw TestFailure("link did not parse") }
        let phone = RemoteConnection()
        let watcher = Watcher()
        phone.delegate = watcher
        defer { phone.stop(forget: true); mac.stop() }
        phone.pair(link)
        try await until("connected") { phone.phase == .connected }
        try await mac.pushEvent(rows: ["missing counter"], eventSequence: nil)
        try await until("protocol error") { watcher.failure != nil }
        try Expect.equal(watcher.events.count, 0, "missing counter never reaches the screen")
    }

    static func oldHelloAndOldStateCannotAuthorizeReconnect(port: String) async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        let room = try await mac.register()
        guard case .success(let link) = PairingLink.parse("http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)")
        else { throw TestFailure("link did not parse") }
        let phone = RemoteConnection()
        let watcher = Watcher()
        phone.delegate = watcher
        defer { phone.stop(forget: true); mac.stop() }
        phone.pair(link)
        try await until("paired") { phone.phase == .connected }
        mac.rememberHandshake()
        try await mac.retireAndReRegister()
        try await until("fresh connection") { mac.connections >= 2 && phone.phase == .connected }
        try await mac.replayOldHandshake()
        try await until("old sealed state rejected", timeout: 2) { watcher.failure != nil }
        try Expect.equal(watcher.failure, "Update Sigil and the phone companion, then reconnect.", "replayed or old protocol cannot authorize a connection")
    }

    static func pendingInputQueueIsBounded(port: String) async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        mac.pauseInput = true
        let room = try await mac.register()
        guard case .success(let link) = PairingLink.parse("http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)")
        else { throw TestFailure("link did not parse") }
        let phone = RemoteConnection()
        defer { phone.stop(forget: true); mac.stop() }
        phone.pair(link)
        try await until("connected") { phone.phase == .connected }
        var failures = 0
        let requests = (0..<40).map { index in
            Task { @MainActor in
                do { _ = try await phone.request("input", text: "queued-\(index)", tabID: "T1") }
                catch { failures += 1 }
            }
        }
        try await until("first input reached the host") { mac.requests.contains { $0.action == "input" } }
        try await until("excess queued input rejected before timeout", timeout: 2) { failures >= 8 }
        phone.stop()
        for request in requests { await request.value }
        try Expect.equal(mac.requests.filter { $0.action == "input" }.count, 1, "disconnect drops queued input without retry")
    }

    static func oldSendFailureCannotConsumeNewHandshake(port: String) async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        let room = try await mac.register()
        guard case .success(let link) = PairingLink.parse("http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)")
        else { throw TestFailure("link did not parse") }
        var delayedCompletion: (@Sendable (Error?) -> Void)?
        let phone = RemoteConnection(send: { socket, frame, completion in
            if delayedCompletion == nil {
                delayedCompletion = completion
                socket.send(.string(frame)) { _ in }
            } else {
                socket.send(.string(frame), completionHandler: completion)
            }
        })
        let watcher = Watcher()
        phone.delegate = watcher
        defer { phone.stop(forget: true); mac.stop() }
        phone.pair(link)
        try await until("paired") { phone.phase == .connected }
        try await mac.rotateHandshakeAndPause()
        try await until("new state request pending") { mac.requests.contains { $0.action == "state" } }
        try Expect.equal(phone.phase, .connecting, "input disabled until new hello is authenticated")
        do {
            _ = try await phone.request("input", text: "must not send", tabID: "T1")
            throw TestFailure("input was accepted before the fresh handshake")
        } catch RemoteConnectionError.notConnected {}
        delayedCompletion?(URLError(.networkConnectionLost))
        try await Task.sleep(for: .milliseconds(50))
        try await mac.releaseState()
        try await until("fresh state still resolves") { phone.phase == .connected }
        try Expect.equal(watcher.failure, nil, "an old write completion cannot fail the new request with sequence 1")
        try Expect.true(!mac.requests.contains { $0.action == "input" }, "unauthenticated input never reached the host")
    }

    static func oldAuthorizationCannotConnectNewEpoch(port: String) async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        let room = try await mac.register()
        guard case .success(let link) = PairingLink.parse("http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)")
        else { throw TestFailure("link did not parse") }
        var coalesceNextReply = false
        var buffered: URLSessionWebSocketTask.Message?
        let phone = RemoteConnection(receive: { socket in
            if let ready = buffered { buffered = nil; return ready }
            let message = try await socket.receive()
            if coalesceNextReply, case .string(let text) = message,
                let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                object["data"] != nil {
                // These are real relay frames. Deliver the reply and immediately
                // following hello together, before the old auth task can resume.
                buffered = try await socket.receive()
                coalesceNextReply = false
            }
            return message
        })
        defer { phone.stop(forget: true); mac.stop() }
        phone.pair(link)
        try await until("paired") { phone.phase == .connected }
        coalesceNextReply = true
        mac.rotateAfterState = true
        try await mac.retireAndReRegister()
        try await until("newest auth is pending") { mac.requests.filter { $0.action == "state" }.count >= 2 }
        try await Task.sleep(for: .milliseconds(50))
        try Expect.equal(phone.phase, .connecting, "old auth continuation must not connect an unacknowledged newer epoch")
        try await mac.releaseState()
        try await until("only current auth connects") { phone.phase == .connected }
    }

    static func until(_ what: String, timeout: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TestFailure("timed out waiting: \(what)") }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { throw TestFailure("cancelled waiting: \(what): \(error)") }
        }
    }

    final class Watcher: RemoteConnectionDelegate {
        var saved: PairingCredential?
        var lastState: RemoteState?
        var events: [RemoteReply] = []
        var failure: String?
        func connection(_ connection: RemoteConnection, didChange phase: RemoteConnection.Phase) {}
        func connection(_ connection: RemoteConnection, didReceive reply: RemoteReply, for action: String, tabID: String?) {
            lastState = reply.state
        }
        func connection(_ connection: RemoteConnection, didReceiveEvent reply: RemoteReply) { events.append(reply) }
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
        let name: String?
        let clientNonce: String?
        let index: Int?
        let count: Int?
        let transfer: String?
    }

    struct Reply: Encodable {
        struct Tab: Encodable {
            let id: String
            let title: String
            let status: String
            var provider: String?
            var sessionID: String?
            var cwd: String?
        }
        struct Row: Encodable {
            let i: Int
            let t: String
        }
        struct Screen: Encodable {
            let gen = 1
            let first: Int
            let end: Int
            let rows: [Row]
        }
        struct State: Encodable {
            let tabs: [Tab]
            let selectedTabID: String?
            let terminal: String
            var capabilities = ["restart", "screen", "eventSequence"]
            var tabsTruncated = false
            var screen: Screen?
            var prompt: Prompt?
        }
        struct Prompt: Encodable {
            struct Choice: Encodable { let label: String; let key: String }
            let id = "terminal-hint"
            let question = "Choose an action"
            let operation = "Preview the proposed change without changing files."
            let style = "menu"
            let choices = [Choice(label: "Preview only", key: "1"), Choice(label: "Cancel", key: "2")]
            let verified = false
        }
        let challenge: String
        let sequence: Int
        var ok = true
        var error: String?
        var state: State?
        var ticket: String?
        var event: Bool?
        var eventSequence: Int?
        var clientNonce: String?
        var restartedTabID: String?
        var restartedSession: ProviderSessionReference?
        var earlier: String?
    }

    let origin: URL
    let pairingKey = RemoteCrypto.randomKey()
    let ticket = RemoteCrypto.randomKey()
    private(set) var deviceKey: String?
    var dropPairReply = false
    var presentTerminalMenu = false
    var orderedEvents = true
    var pauseInput = false
    var pauseFile = false
    var pauseEnter = false
    var optionsError = "Unknown action."
    var rotateAfterInput = false
    var pauseState = false
    var rotateAfterState = false
    var pauseRestart = false
    var truncatedTabs = false
    private var delayedRestart: Request?
    private var delayedState: Request?
    private var delayedInput: Request?
    private var delayedFile: Request?
    private(set) var requests: [Request] = []
    var firstTab = Reply.Tab(id: "T1", title: "Test", status: "idle") {
        didSet { if selected == oldValue.id { selected = firstTab.id } }
    }
    private var selected = "T1"
    private var clientNonce: String?
    private var savedHello: String?
    private var savedReply: String?
    private var latestReply: String?
    private var ignoreRequests = false
    private(set) var connections = 0
    private var socket: URLSessionWebSocketTask?
    private var peer: String?
    private var challenge = RemoteCrypto.randomKey()
    private var lastSequence = 0
    private var revoked = false
    private let session = URLSession(configuration: .ephemeral)

    init(origin: URL) { self.origin = origin }

    func register() async throws -> String {
        // The real relay has a five-token burst/refill and a 20-room active cap.
        // Native cases rotate over a fresh relay pool so room grace does not
        // exhaust one suite-wide budget. Retry refused setup only, never
        // a command or transport failure; keep workflow deadlines unchanged.
        let deadline = Date().addingTimeInterval(75)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TestFailure("relay room setup deadline expired") }
            var request = URLRequest(url: origin.appendingPathComponent("rooms"))
            request.timeoutInterval = min(15, remaining)
            request.httpMethod = "POST"
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 429 {
                let header = http?.value(forHTTPHeaderField: "Retry-After")
                let format = DateFormatter()
                format.locale = Locale(identifier: "en_US_POSIX")
                format.timeZone = TimeZone(secondsFromGMT: 0)
                format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                let wait = max(0.1, header.flatMap(Double.init)
                    ?? header.flatMap { format.date(from: $0)?.timeIntervalSinceNow } ?? 60)
                guard wait <= deadline.timeIntervalSinceNow else { throw TestFailure("relay room setup rate limit did not clear") }
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            guard http?.statusCode == 201 else { throw TestFailure("room not created: HTTP \(http?.statusCode ?? 0)") }
            let registered = try JSONDecoder().decode(Registered.self, from: data)
            connect(registered)
            return registered.room
        }
    }

    func retireAndReRegister() async throws {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        _ = try await register()
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

    /// What Sigil sends after `watch`: a sealed frame nobody asked for.
    func pushEvent(rows: [String], eventSequence: Int? = 1) async throws {
        guard let socket, let peer, let deviceKey else { throw TestFailure("no phone to push to") }
        var reply = Reply(challenge: challenge, sequence: 0, ticket: ticket, event: true, eventSequence: eventSequence, clientNonce: clientNonce)
        var state = state("")
        state.screen = Reply.Screen(
            first: 0, end: rows.count, rows: rows.enumerated().map { Reply.Row(i: $0.offset, t: $0.element) })
        reply.state = state
        let sealed = try RemoteCrypto.seal(reply, key: deviceKey, direction: "mac")
        try await send(["peer": peer, "data": sealed], on: socket)
    }

    func selectOnMac(_ tabID: String, eventSequence: Int) async throws {
        guard tabID == firstTab.id || tabID == "T2" else { throw TestFailure("unknown fixture tab") }
        selected = tabID
        try await pushEvent(rows: ["selected: \(tabID)"], eventSequence: eventSequence)
    }

    func releaseState() async throws {
        guard let request = delayedState, let socket, let peer, let deviceKey else { throw TestFailure("no delayed state") }
        delayedState = nil
        pauseState = false
        let reply = Reply(challenge: request.challenge, sequence: request.sequence,
                          state: state("ready"), ticket: ticket, clientNonce: request.clientNonce)
        let sealed = try RemoteCrypto.seal(reply, key: deviceKey, direction: "mac")
        try await send(["peer": peer, "data": sealed], on: socket)
    }

    func releaseInput() async throws {
        guard let request = delayedInput, let socket, let peer, let deviceKey else { throw TestFailure("no delayed input") }
        delayedInput = nil
        pauseInput = false
        let reply = Reply(challenge: request.challenge, sequence: request.sequence,
                          state: state("echo: \(request.text ?? "")"), ticket: ticket, clientNonce: request.clientNonce)
        let sealed = try RemoteCrypto.seal(reply, key: deviceKey, direction: "mac")
        try await send(["peer": peer, "data": sealed], on: socket)
    }

    func releaseFile() async throws {
        guard let request = delayedFile, let socket, let peer, let deviceKey else { throw TestFailure("no delayed file") }
        delayedFile = nil
        pauseFile = false
        let reply = Reply(challenge: request.challenge, sequence: request.sequence,
                          state: state("file: \(request.name ?? "")"), ticket: ticket, clientNonce: request.clientNonce)
        let sealed = try RemoteCrypto.seal(reply, key: deviceKey, direction: "mac")
        try await send(["peer": peer, "data": sealed], on: socket)
    }

    func releaseRestart() async throws {
        guard let request = delayedRestart, let socket, let peer, let deviceKey else { throw TestFailure("no delayed restart") }
        delayedRestart = nil
        let reference = firstTab.provider.flatMap { provider in
            firstTab.sessionID.flatMap { sessionID in firstTab.cwd.map { ProviderSessionReference(provider: provider, sessionID: sessionID, cwd: $0) } }
        }
        let reply = Reply(challenge: request.challenge, sequence: request.sequence,
                          state: state("restarted"), ticket: ticket, clientNonce: request.clientNonce,
                          restartedTabID: firstTab.id, restartedSession: reference)
        let sealed = try RemoteCrypto.seal(reply, key: deviceKey, direction: "mac")
        try await send(["peer": peer, "data": sealed], on: socket)
    }

    func rotateHandshakeAndPause() async throws {
        guard let socket, let peer else { throw TestFailure("no connection") }
        pauseState = true
        challenge = RemoteCrypto.randomKey()
        lastSequence = 0
        try await send(["peer": peer, "hello": challenge], on: socket)
    }

    func rememberHandshake() {
        savedHello = challenge
        savedReply = latestReply
    }

    func replayOldHandshake() async throws {
        guard let socket, let peer, let savedHello, let savedReply else { throw TestFailure("no saved handshake") }
        ignoreRequests = true
        try await send(["peer": peer, "hello": savedHello], on: socket)
        try await send(["peer": peer, "data": savedReply], on: socket)
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
        if ignoreRequests { return }
        guard !revoked,
            let request: Request = try? RemoteCrypto.open(data, key: deviceKey ?? pairingKey, direction: "phone"),
            request.challenge == challenge, request.sequence > lastSequence
        else {
            try await send(["peer": id, "error": "unauthorized"], on: ws)
            return
        }
        lastSequence = request.sequence
        clientNonce = request.clientNonce
        if deviceKey == nil {
            guard request.action == "pair", let key = request.text, RemoteCrypto.isValidKey(key) else {
                try await send(["peer": id, "error": "unauthorized"], on: ws)
                return
            }
            deviceKey = key
        }
        if request.action == "pair", dropPairReply { return }
        var reply = Reply(challenge: request.challenge, sequence: request.sequence, ticket: ticket, clientNonce: request.clientNonce)
        requests.append(request)
        if pauseInput, request.action == "input" { delayedInput = request; return }
        if pauseFile, request.action == "file" { delayedFile = request; return }
        if pauseEnter, request.action == "key", request.text == "enter" { return }
        if pauseState, request.action == "state" { delayedState = request; return }
        if pauseRestart, request.action == "restart" {
            delayedRestart = request
            firstTab = Reply.Tab(id: firstTab.id + "-restarted", title: firstTab.title, status: "idle",
                                 provider: firstTab.provider, sessionID: firstTab.sessionID, cwd: firstTab.cwd)
            try await pushEvent(rows: ["restart event before receipt"])
            return
        }
        switch request.action {
        case "pair", "state", "watch":
            reply.state = state("ready")
        case "malformed":
            reply.state = Reply.State(tabs: [], selectedTabID: "missing", terminal: "bad")
        case "select" where request.tabID == firstTab.id || request.tabID == "T2":
            selected = request.tabID!
            reply.state = state("selected: \(selected)")
        case "input":
            reply.state = state("echo: \(request.text ?? "")")
        case "file":
            // Synthetic attachment acknowledgement; no file is written or opened.
            reply.state = state("file: \(request.name ?? "")")
        case "options":
            // This fixture models the supported legacy options fallback.
            reply.ok = false
            reply.error = optionsError
        case "earlier":
            // A short synthetic terminal has no earlier page. Rendering it
            // must not invent a closed-tab error for a normal history read.
            reply.earlier = ""
            reply.state = state("ready")
        case "key" where request.tabID == selected:
            reply.state = state("key: \(request.text ?? "")")
        default:
            reply.ok = false
            reply.error = "This tab is closed."
        }
        let sealed = try RemoteCrypto.seal(reply, key: deviceKey!, direction: "mac")
        latestReply = sealed
        try await send(["peer": id, "data": sealed], on: ws)
        if rotateAfterState, request.action == "state" {
            rotateAfterState = false
            pauseState = true
            challenge = RemoteCrypto.randomKey()
            lastSequence = 0
            try await send(["peer": id, "hello": challenge], on: ws)
        }
        if rotateAfterInput, request.action == "input" {
            challenge = RemoteCrypto.randomKey()
            lastSequence = 0
            try await send(["peer": id, "hello": challenge], on: ws)
        }
    }

    private func state(_ terminal: String) -> Reply.State {
        var state = Reply.State(
            tabs: [firstTab, Reply.Tab(id: "T2", title: "Second", status: "unknown")],
            selectedTabID: selected, terminal: terminal)
        state.tabsTruncated = truncatedTabs
        if !orderedEvents { state.capabilities.removeAll { $0 == "eventSequence" } }
        if presentTerminalMenu { state.prompt = Reply.Prompt() }
        return state
    }

    private func send(_ object: [String: String], on ws: URLSessionWebSocketTask) async throws {
        try await ws.send(.string(String(decoding: try JSONEncoder().encode(object), as: UTF8.self)))
    }
}
