import Foundation

enum RemoteConnectionError: LocalizedError, Equatable {
    case notConnected
    case changed
    case noResponse
    case lost
    case mac(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        case .changed: return "Connection changed. Check the terminal before sending again."
        case .noResponse: return "No response. Check the terminal before sending again."
        case .lost: return "Connection lost. Check the terminal before sending again."
        case .mac(let message): return message
        }
    }
}

@MainActor
protocol RemoteConnectionDelegate: AnyObject {
    func connection(_ connection: RemoteConnection, didChange phase: RemoteConnection.Phase)
    /// Every successful reply that carries a snapshot, in order.
    func connection(_ connection: RemoteConnection, didReceive reply: RemoteReply, for action: String, tabID: String?)
    /// The pairing to keep. Called when the Mac first accepts the phone and when it rotates the ticket.
    func connection(_ connection: RemoteConnection, didSave credential: PairingCredential)
    func connection(_ connection: RemoteConnection, didFail message: String)
}

/// One phone connection through the Sidereal relay, the same protocol the web
/// companion speaks: route, hello, then sealed requests with a rising sequence.
@MainActor
final class RemoteConnection {
    enum Phase: Equatable {
        case offline
        case connecting
        case connected
        /// The Mac refused this phone. Only a new pairing gets back in.
        case revoked
    }

    weak var delegate: RemoteConnectionDelegate?
    private(set) var phase: Phase = .offline {
        didSet { if phase != oldValue { delegate?.connection(self, didChange: phase) } }
    }
    private(set) var credential: PairingCredential?

    private struct Pending {
        let continuation: CheckedContinuation<RemoteReply, Error>
        let action: String
        let tabID: String?
        let timeout: Task<Void, Never>
    }

    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var commandEpoch = 0
    private var challenge: String?
    private var sequence = 0
    private var pending: [Int: Pending] = [:]
    private var queue: Task<Void, Never>?
    private var bootstrapKey: String?
    private var unsaved = false
    /// Set once a pair request goes out. Without a ticket back, that QR room is gone.
    private var pairSent = false
    private var stopped = true
    private var reconnectDelay: Double = 0.5
    private var reconnectTask: Task<Void, Never>?
    private var helloTimeout: Task<Void, Never>?

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    /// Reconnect with a pairing the Mac already accepted.
    func resume(_ credential: PairingCredential) {
        self.credential = credential
        bootstrapKey = nil
        unsaved = false
        pairSent = false
        start()
    }

    /// Pair with a fresh code. The previous pairing stays saved until the Mac accepts this one.
    func pair(_ link: PairingLink) {
        credential = PairingCredential(
            origin: link.origin, room: link.room, deviceKey: RemoteCrypto.randomKey(), ticket: nil)
        bootstrapKey = link.key
        unsaved = true
        pairSent = false
        start()
    }

    func reconnect() {
        guard credential != nil else { return }
        start()
    }

    /// Stops reconnecting. `forget` also drops the pairing from memory.
    func stop(forget: Bool = false) {
        stopped = true
        generation += 1
        reconnectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        goOffline(.offline)
        if forget {
            credential = nil
            bootstrapKey = nil
            unsaved = false
        }
    }

    // MARK: Requests

    /// Sends in order. A second tap waits behind the first instead of racing it.
    func request(
        _ action: String, text: String? = nil, tabID: String? = nil, name: String? = nil,
        index: Int? = nil, count: Int? = nil, transfer: String? = nil, provider: String? = nil,
        model: String? = nil, effort: String? = nil
    ) async throws -> RemoteReply {
        let previous = queue
        let current = generation
        let epoch = commandEpoch
        let work = Task { @MainActor () throws -> RemoteReply in
            await previous?.value
            guard current == self.generation, epoch == self.commandEpoch else { throw RemoteConnectionError.changed }
            return try await self.transmit(
                RequestFields(
                    action: action, text: text, tabID: tabID, name: name, index: index, count: count,
                    transfer: transfer, provider: provider, model: model, effort: effort),
                pairing: false)
        }
        queue = Task { _ = try? await work.value }
        return try await work.value
    }

    private struct RequestFields {
        var action: String
        var text: String?
        var tabID: String?
        var name: String?
        var index: Int?
        var count: Int?
        var transfer: String?
        var provider: String?
        var model: String?
        var effort: String?
    }

    private func transmit(_ fields: RequestFields, pairing: Bool) async throws -> RemoteReply {
        guard let socket, let challenge, let credential,
            phase == .connected || pairing || fields.action == "state"
        else { throw RemoteConnectionError.notConnected }
        let key = pairing ? (bootstrapKey ?? "") : credential.deviceKey
        sequence += 1
        let seq = sequence
        let request = RemoteRequest(
            challenge: challenge, sequence: seq, action: fields.action, tabID: fields.tabID, text: fields.text,
            name: fields.name, index: fields.index, count: fields.count, transfer: fields.transfer,
            provider: fields.provider, model: fields.model, effort: fields.effort)
        let sealed = try RemoteCrypto.seal(request, key: key, direction: "phone")
        let frame = try Self.json(["data": sealed])
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, let item = self.pending.removeValue(forKey: seq) else { return }
                item.continuation.resume(throwing: RemoteConnectionError.noResponse)
                // A silent socket may be half-open after a network change. Drop it so the
                // receive loop ends and a fresh connection is made.
                self.socket?.cancel(with: .goingAway, reason: nil)
            }
            pending[seq] = Pending(
                continuation: continuation, action: fields.action, tabID: fields.tabID, timeout: timeout)
            socket.send(.string(frame)) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    guard let self, let item = self.pending.removeValue(forKey: seq) else { return }
                    item.timeout.cancel()
                    item.continuation.resume(throwing: RemoteConnectionError.lost)
                }
            }
        }
    }

    // MARK: Socket

    private func start() {
        reconnectTask?.cancel()
        guard let credential, let url = credential.connectURL else { return }
        stopped = false
        generation += 1
        let current = generation
        socket?.cancel(with: .goingAway, reason: nil)
        goOffline(.connecting)
        challenge = nil
        sequence = 0
        var request = URLRequest(url: url)
        // The relay only lets a phone in with the companion's own origin.
        request.setValue(credential.originString, forHTTPHeaderField: "Origin")
        request.timeoutInterval = 10
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 1 << 20
        socket = ws
        ws.resume()
        helloTimeout?.cancel()
        helloTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, current == self.generation, self.phase != .connected else { return }
            self.delegate?.connection(self, didFail: "The Mac did not respond. Keep Sigil open and try again.")
            ws.cancel(with: .goingAway, reason: nil)
        }
        Task { @MainActor [weak self] in
            var routed = false
            while true {
                let message: URLSessionWebSocketTask.Message
                do { message = try await ws.receive() } catch { break }
                guard let self, current == self.generation else { return }
                guard case .string(let text) = message, text.utf8.count <= 110_000 else {
                    self.delegate?.connection(self, didFail: "Could not verify the connection.")
                    ws.cancel(with: .policyViolation, reason: nil)
                    break
                }
                do {
                    try await self.handle(text, socket: ws, routed: &routed)
                } catch {
                    guard current == self.generation else { return }
                    self.delegate?.connection(self, didFail: "Could not verify the connection.")
                    ws.cancel(with: .policyViolation, reason: nil)
                    break
                }
            }
            self?.closed(generation: current)
        }
    }

    private func handle(_ text: String, socket ws: URLSessionWebSocketTask, routed: inout Bool) async throws {
        guard let credential else { return }
        let frame = try JSONDecoder().decode(RelayFrame.self, from: Data(text.utf8))
        if let route = frame.route, RemoteCrypto.isValidKey(route) {
            guard !routed else { return }
            routed = true
            // Routing is sealed to this relay connection, never with the device key.
            let envelope = try RemoteCrypto.seal(
                RouteEnvelope(room: credential.room, ticket: credential.ticket), key: route, direction: "relay-phone")
            try await ws.send(.string(try Self.json(["route": envelope])))
        } else if let hello = frame.hello, RemoteCrypto.isValidKey(hello) {
            guard challenge != hello else { return }
            commandEpoch += 1
            failPending(RemoteConnectionError.changed)
            challenge = hello
            sequence = 0
            authorize(generation: generation)
        } else if frame.error == "unauthorized" {
            if bootstrapKey != nil {
                // A dropped pairing acknowledgement can leave the Mac already on the device key.
                bootstrapKey = nil
                ws.cancel(with: .goingAway, reason: nil)
            } else {
                stopped = true
                goOffline(.revoked)
                delegate?.connection(self, didFail: "Pairing expired or was disconnected. Scan a new code in Sigil.")
                ws.cancel(with: .goingAway, reason: nil)
            }
        } else if let data = frame.data {
            let reply: RemoteReply = try RemoteCrypto.open(data, key: credential.deviceKey, direction: "mac")
            guard let item = pending[reply.sequence] else { return }
            // A delayed reply from an earlier Mac epoch.
            guard reply.challenge == challenge else { return }
            pending[reply.sequence] = nil
            item.timeout.cancel()
            guard reply.ok != false else {
                item.continuation.resume(
                    throwing: RemoteConnectionError.mac(reply.error ?? "The Mac could not complete this action."))
                return
            }
            if let state = reply.state { try state.validate() }
            if let ticket = reply.ticket, RemoteCrypto.isValidKey(ticket), ticket != credential.ticket {
                self.credential?.ticket = ticket
                if !unsaved, let saved = self.credential { delegate?.connection(self, didSave: saved) }
            }
            if reply.state != nil { delegate?.connection(self, didReceive: reply, for: item.action, tabID: item.tabID) }
            item.continuation.resume(returning: reply)
        } else {
            throw RemoteCryptoError.invalidMessage
        }
    }

    private func authorize(generation current: Int) {
        let pairing = bootstrapKey != nil
        if pairing { pairSent = true }
        let fields =
            pairing
            ? RequestFields(action: "pair", text: credential?.deviceKey)
            : RequestFields(action: "state")
        Task { @MainActor in
            do {
                _ = try await self.transmit(fields, pairing: pairing)
                guard current == self.generation else { return }
                self.bootstrapKey = nil
                self.reconnectDelay = 0.5
                self.helloTimeout?.cancel()
                self.phase = .connected
                // After the phase change, so a save failure is not cleared by "connected".
                if self.unsaved, let saved = self.credential {
                    self.unsaved = false
                    self.delegate?.connection(self, didSave: saved)
                }
            } catch {
                // After a refusal the reason is already shown; "connection lost" would hide it.
                guard current == self.generation, self.phase != .revoked else { return }
                self.delegate?.connection(self, didFail: error.localizedDescription)
            }
        }
    }

    private func closed(generation current: Int) {
        guard current == generation else { return }
        socket = nil
        if pairSent, credential?.ticket == nil {
            // The Mac may have accepted the phone and retired the QR room, but the reply
            // with the ticket never arrived. Nothing can route back in; ask for a new code.
            stopped = true
            goOffline(.revoked)
            delegate?.connection(self, didFail: "Pairing did not finish. Scan a new code in Sigil.")
            return
        }
        if stopped {
            if phase != .revoked { goOffline(.offline) }
            return
        }
        goOffline(.connecting)
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 8)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, current == self.generation, !self.stopped else { return }
            self.start()
        }
    }

    private func goOffline(_ next: Phase) {
        helloTimeout?.cancel()
        failPending(RemoteConnectionError.lost)
        phase = next
    }

    private func failPending(_ error: Error) {
        let items = pending.values
        pending.removeAll()
        for item in items {
            item.timeout.cancel()
            item.continuation.resume(throwing: error)
        }
    }

    private static func json(_ object: [String: String]) throws -> String {
        String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
    }
}
