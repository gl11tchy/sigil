import Foundation
import Observation
import SigilKit

/// Outbound-only encrypted remote control; no LAN listener and no persistent authorization.
@MainActor
@Observable
final class RemoteControl {
    private(set) var isEnabled = false
    private(set) var isPaired = false
    private(set) var pairingURL: URL?
    private(set) var expiresAt: Date?
    private(set) var status = "Off"
    private(set) var error: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var network: URLSession?

    static func origin(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil, components.password == nil, components.query == nil,
            components.fragment == nil, components.path.isEmpty || components.path == "/",
            let host = components.host, !host.isEmpty
        else { return nil }
        var allowed = components.scheme == "https"
        #if DEBUG
            allowed = allowed || (components.scheme == "http" && ["127.0.0.1", "localhost"].contains(host))
        #endif
        guard allowed else { return nil }
        var normalized = components
        normalized.path = ""
        return normalized.url
    }

    func start(urlText: String, model: AppModel) {
        stop()
        guard let origin = Self.origin(urlText) else {
            error = "Enter the HTTPS address of your Sidereal server."
            return
        }
        let network = URLSession(configuration: .ephemeral)
        self.network = network
        isEnabled = true
        status = "Connecting…"
        let current = generation
        task = Task { [weak self, weak model] in
            guard let self, self.generation == current, !Task.isCancelled else { return }
            do {
                var request = URLRequest(url: origin.appendingPathComponent("rooms"))
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                let (data, response) = try await network.data(for: request)
                guard self.generation == current, !Task.isCancelled else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 201, data.count <= 1024 else {
                    throw RemoteError.invalidMessage
                }
                let room = try JSONDecoder().decode(Room.self, from: data)
                guard room.room.count == 32, room.room.allSatisfy(\.isHexDigit), RemoteCrypto.isValidKey(room.hostToken)
                else {
                    throw RemoteError.invalidMessage
                }
                var session = RemoteSession()
                self.expiresAt = session.expiresAt
                var link = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
                link.path = "/"
                link.fragment = "room=\(room.room)&key=\(session.pairingKey)"
                let pairingURL = link.url
                var endpoint = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
                endpoint.scheme = origin.scheme == "https" ? "wss" : "ws"
                endpoint.path = "/connect"
                endpoint.queryItems = [
                    URLQueryItem(name: "room", value: room.room), URLQueryItem(name: "role", value: "host"),
                ]
                var retry = 1
                var failures = 0
                while !Task.isCancelled, self.generation == current {
                    guard Date() < session.expiresAt.addingTimeInterval(86_100), failures < 10 else {
                        self.stop()
                        self.error = "Remote session ended. Connect your phone again."
                        return
                    }
                    var socketRequest = URLRequest(url: endpoint.url!)
                    socketRequest.setValue("Bearer \(room.hostToken)", forHTTPHeaderField: "Authorization")
                    let socket = network.webSocketTask(with: socketRequest)
                    socket.maximumMessageSize = 110_000
                    self.socket = socket
                    socket.resume()
                    var peer: String?
                    do {
                        while !Task.isCancelled, self.generation == current {
                            let message = try await socket.receive()
                            guard self.generation == current, !Task.isCancelled else { return }
                            let bytes: Data
                            switch message {
                            case .string(let text): bytes = Data(text.utf8)
                            case .data(let data): bytes = data
                            @unknown default: throw RemoteError.invalidMessage
                            }
                            let frame = try JSONDecoder().decode(Frame.self, from: bytes)
                            if frame.type == "ready" {
                                retry = 1
                                failures = 0
                                self.status = session.isPaired ? "Phone disconnected" : "Scan to connect"
                                self.pairingURL = session.isPaired ? nil : pairingURL
                            } else if frame.type == "peer", let id = frame.peer, id.count <= 64 {
                                peer = id
                                session.resetConnection()
                                try await self.send(Frame(peer: id, hello: session.challenge), socket: socket)
                            } else if frame.type == "left", frame.peer == peer {
                                peer = nil
                                self.status = session.isPaired ? "Phone disconnected" : "Scan to connect"
                            } else if let id = frame.peer, id == peer, let ciphertext = frame.data {
                                do {
                                    let command = try session.accept(ciphertext)
                                    guard let model else {
                                        self.stop()
                                        return
                                    }
                                    self.isPaired = true
                                    self.pairingURL = nil
                                    self.status = "Phone connected"
                                    let reply = RemoteCommands.execute(command, model: model)
                                    let encrypted = try RemoteCrypto.seal(
                                        reply, key: session.deviceKey!, direction: "mac")
                                    try await self.send(Frame(peer: id, data: encrypted), socket: socket)
                                } catch {
                                    try await self.send(Frame(peer: id, error: "unauthorized"), socket: socket)
                                }
                            }
                        }
                    } catch {
                        socket.cancel(with: .goingAway, reason: nil)
                        guard self.generation == current, !Task.isCancelled else { return }
                        self.status = "Reconnecting…"
                        self.pairingURL = nil
                        try await Task.sleep(for: .seconds(retry))
                        retry = min(retry * 2, 30)
                        failures += 1
                    }
                }
            } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                self.stop()
                self.error = "Could not connect. Check the Sidereal address and try again."
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        network?.invalidateAndCancel()
        network = nil
        isEnabled = false
        isPaired = false
        pairingURL = nil
        expiresAt = nil
        status = "Off"
        error = nil
    }

    private func send(_ frame: Frame, socket: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(frame)
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    private struct Room: Decodable {
        let room: String
        let hostToken: String
    }
    private struct Frame: Codable {
        var type: String?
        var peer: String?
        var hello: String?
        var data: String?
        var error: String?
    }
}
