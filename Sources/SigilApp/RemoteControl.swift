import Foundation
import Observation
import SigilKit
import os

/// Outbound-only encrypted remote control; no LAN listener.
@MainActor
@Observable
final class RemoteControl {
    private(set) var isEnabled = false
    private(set) var isPaired = false
    private(set) var pairingURL: URL?
    private(set) var expiresAt: Date?
    private(set) var status = "Off"
    private(set) var error: String?
    /// A Disconnect could not delete the pairing, so the view keeps offering it.
    private(set) var revokeFailed: Bool

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var peer: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var network: URLSession?
    @ObservationIgnored private let store: any RemotePairingStore
    @ObservationIgnored private let notifications: NotificationCenter
    /// The phone asked to watch: changes go out as events until it leaves.
    @ObservationIgnored private var watcher: Watcher?
    @ObservationIgnored private var stream = RemoteScreenStream()
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var lastSentTabs: [RemoteState.Tab]?
    @ObservationIgnored private var lastSentSelection: String?
    @ObservationIgnored private weak var watchedModel: AppModel?
    /// Changes are batched this long, so a burst of output is one frame.
    static let changeDelay: Duration = .milliseconds(80)
    /// Rows per event frame, so a full window stays under the sealed-frame cap.
    static let rowsPerEvent = 60

    /// Posted after a revoke, so another running copy of Sigil stops using the pairing.
    static let revokedNotification = Notification.Name("com.gl11tchy.sigil.remote.revoked")

    /// Production passes DistributedNotificationCenter; the default stays in this process.
    init(
        store: any RemotePairingStore = KeychainRemotePairingStore(),
        notifications: NotificationCenter = NotificationCenter()
    ) {
        self.store = store
        self.notifications = notifications
        revokeFailed = store.revokeFailed
        notifications.addObserver(forName: Self.revokedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revokedElsewhere() }
        }
    }

    static let productionOrigin = "https://remote.sigilapp.dev"
    static let legacyRailwayOrigin = "https://sidereal-production-587c.up.railway.app"
    static let legacyApexOrigin = "https://sigilapp.dev"

    static func preferredOrigin(_ text: String) -> String {
        guard let normalized = origin(text)?.absoluteString else { return text }
        return normalized == legacyRailwayOrigin || normalized == legacyApexOrigin ? productionOrigin : text
    }

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
        normalized.host = host.lowercased()
        if (normalized.scheme == "https" && normalized.port == 443)
            || (normalized.scheme == "http" && normalized.port == 80)
        {
            normalized.port = nil
        }
        return normalized.url
    }

    func resumeIfPaired(model: AppModel) {
        guard !store.revokeFailed else { return }
        let saved: RemotePairing?
        do {
            saved = try store.load()
        } catch {
            self.error = "Sigil could not read the saved phone pairing. Connect your phone again."
            return
        }
        guard let pairing = saved, Self.origin(pairing.origin) != nil else { return }
        guard Self.preferredOrigin(pairing.origin) == pairing.origin else { return }
        start(urlText: pairing.origin, model: model, saved: pairing)
    }

    func start(urlText: String, model: AppModel) {
        start(urlText: urlText, model: model, saved: store.revokeFailed ? nil : try? store.load())
    }

    /// Takes the pairing already read, so one launch reads Keychain once.
    private func start(urlText: String, model: AppModel, saved: RemotePairing?) {
        stop()
        guard let origin = Self.origin(Self.preferredOrigin(urlText)) else {
            error = "Enter the HTTPS address of your Sidereal server."
            return
        }
        let restored = restoredSession(for: origin, saved: saved)
        let network = URLSession(configuration: .ephemeral)
        self.network = network
        isEnabled = true
        isPaired = restored.isPaired
        pairingURL = nil
        expiresAt = restored.isPaired ? nil : restored.expiresAt
        status = restored.isPaired ? "Waiting for phone" : "Connecting…"
        let current = generation
        task = Task { [weak self, weak model] in
            guard let self, self.generation == current, !Task.isCancelled else { return }
            var session = restored
            var room: Room?
            var unsaved: String?
            // After the first pairing the QR's room ID must stop routing phones.
            var retireRoom = false
            var pairingURL: URL?
            var failures = 0
            var ready = false
            while !Task.isCancelled, self.generation == current {
                do {
                    if retireRoom {
                        room = nil
                        retireRoom = false
                    }
                    if room == nil {
                        let allocated = try await self.allocate(origin: origin, network: network)
                        guard self.generation == current, !Task.isCancelled else { return }
                        room = allocated
                        if !session.isPaired {
                            var link = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
                            link.path = "/"
                            link.fragment = "room=\(allocated.room)&key=\(session.pairingKey)"
                            pairingURL = link.url
                            self.expiresAt = session.expiresAt
                        }
                    }
                    guard let room else { return }
                    var endpoint = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
                    endpoint.scheme = origin.scheme == "https" ? "wss" : "ws"
                    endpoint.path = "/connect"
                    endpoint.queryItems = [
                        URLQueryItem(name: "role", value: "host")
                    ]
                    var socketRequest = URLRequest(url: endpoint.url!)
                    socketRequest.setValue("Bearer \(room.hostToken)", forHTTPHeaderField: "Authorization")
                    let socket = network.webSocketTask(with: socketRequest)
                    socket.maximumMessageSize = 110_000
                    self.socket = socket
                    ready = false
                    socket.resume()
                    let keepAlive = Task { await Self.keepAlive(socket) }
                    defer { keepAlive.cancel() }
                    self.peer = nil
                    var routed = false
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
                        if let key = frame.route {
                            guard !routed, RemoteCrypto.isValidKey(key) else { throw RemoteError.invalidMessage }
                            routed = true
                            let route = try RemoteCrypto.seal(
                                ["room": room.room, "ticket": session.ticket], key: key, direction: "relay-host")
                            try await self.send(Frame(route: route), socket: socket)
                        } else if frame.type == "ready" {
                            ready = true
                            failures = 0
                            self.status = session.isPaired ? "Phone disconnected" : "Scan to connect"
                            self.pairingURL = session.isPaired ? nil : pairingURL
                            self.error = unsaved
                        } else if frame.type == "peer", let id = frame.peer, id.count <= 64 {
                            if retireRoom { break }
                            self.peer = id
                            self.stopWatching()
                            session.resetConnection()
                            // A new peer is not the phone until it authenticates.
                            self.status = session.isPaired ? "Phone disconnected" : "Scan to connect"
                            try await self.send(Frame(peer: id, hello: session.challenge), socket: socket)
                        } else if frame.type == "left", frame.peer == self.peer {
                            self.peer = nil
                            self.stopWatching()
                            self.status = session.isPaired ? "Phone disconnected" : "Scan to connect"
                            if retireRoom { break }
                        } else if let id = frame.peer, id == self.peer, let ciphertext = frame.data {
                            do {
                                let firstPair = !session.isPaired
                                let command = try session.accept(ciphertext)
                                guard let model else {
                                    self.stop()
                                    return
                                }
                                self.isPaired = true
                                self.pairingURL = nil
                                self.expiresAt = nil
                                self.status = "Phone connected"
                                if firstPair, let key = session.deviceKey {
                                    retireRoom = true
                                    if self.store.save(
                                        RemotePairing(
                                            origin: origin.absoluteString, deviceKey: key, ticket: session.ticket))
                                    {
                                        // Saving deleted the old item, so no unrevoked pairing is left.
                                        self.store.revokeFailed = false
                                        self.revokeFailed = false
                                    } else {
                                        unsaved =
                                            "Sigil could not save this pairing in Keychain. It ends when Sigil quits."
                                        self.error = unsaved
                                    }
                                }
                                var reply: RemoteReply
                                if command.action == "watch" {
                                    reply = self.startWatching(
                                        command, model: model, socket: socket, peer: id, session: session)
                                } else {
                                    if command.action == "options" {
                                        await RemoteCommands.refreshModels(model: model)
                                    }
                                    switch await RemoteCommands.prepareWorktree(command, model: model) {
                                    case .failed(let failed): reply = failed
                                    case .folder(let folder):
                                        reply = RemoteCommands.execute(command, model: model, worktreeFolder: folder)
                                    }
                                }
                                reply.ticket = session.ticket
                                let encrypted = try RemoteCrypto.seal(
                                    reply, key: session.deviceKey!, direction: "mac")
                                try await self.send(Frame(peer: id, data: encrypted), socket: socket)
                            } catch RemoteError.outOfBounds(let sequence) {
                                // The pairing is fine; only this request was too large.
                                let reply = RemoteReply(
                                    challenge: session.challenge, sequence: sequence, ok: false,
                                    error: "Too long to send. Shorten it and try again.")
                                let encrypted = try RemoteCrypto.seal(
                                    reply, key: session.deviceKey!, direction: "mac")
                                try await self.send(Frame(peer: id, data: encrypted), socket: socket)
                            } catch {
                                try await self.send(Frame(peer: id, error: "unauthorized"), socket: socket)
                            }
                        }
                    }
                    guard self.generation == current, !Task.isCancelled else { return }
                    // Reached only to retire the room. The phone reconnects by ticket.
                    socket.cancel(with: .goingAway, reason: nil)
                    self.peer = nil
                    self.stopWatching()
                } catch {
                    self.stopWatching()
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    guard self.generation == current, !Task.isCancelled else { return }
                    failures += 1
                    // A route refused before ready means the relay no longer has the room.
                    let refused = !ready && self.socket?.closeCode == .policyViolation
                    if refused || RemoteReconnectPolicy.shouldReallocate(failures: failures) { room = nil }
                    self.status = "Reconnecting…"
                    if !session.isPaired {
                        self.pairingURL = nil
                        self.error = "Could not reach the companion. Retrying."
                    }
                    try? await Task.sleep(for: .seconds(RemoteReconnectPolicy.retrySeconds(failures: failures)))
                }
            }
        }
    }

    func stop(revoke: Bool = false) {
        let forgotten = !revoke || store.clear()
        if revoke {
            store.revokeFailed = !forgotten
            revokeFailed = !forgotten
        }
        generation = UUID()
        task?.cancel()
        task = nil
        stopWatching()
        if revoke, let socket, let peer {
            // The relay forwards this and closes the phone, which then stops
            // reconnecting and asks for a new scan. A plain stop stays silent.
            Self.send(Frame(peer: peer, error: "unauthorized"), thenClose: socket, network: network)
        } else {
            socket?.cancel(with: .goingAway, reason: nil)
            network?.invalidateAndCancel()
        }
        socket = nil
        peer = nil
        network = nil
        RemoteCommands.uploads = RemoteUpload.Inbox()
        isEnabled = false
        isPaired = false
        pairingURL = nil
        expiresAt = nil
        status = "Off"
        error = forgotten ? nil : "Could not forget this phone. Try Disconnect again."
        guard revoke, forgotten else { return }
        if let distributed = notifications as? DistributedNotificationCenter {
            distributed.postNotificationName(Self.revokedNotification, object: nil, deliverImmediately: true)
        } else {
            notifications.post(name: Self.revokedNotification, object: nil)
        }
    }

    // MARK: Events

    private struct Watcher {
        let socket: URLSessionWebSocketTask
        let peer: String
        let challenge: String
        let deviceKey: String
    }

    /// Any change the phone should see: output, status, tabs, selection, titles.
    func noteChange() {
        guard watcher != nil, changeTask == nil else { return }
        changeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.changeDelay)
            guard let self, !Task.isCancelled else { return }
            self.changeTask = nil
            await self.flushChanges()
        }
    }

    private func startWatching(
        _ command: RemoteRequest, model: AppModel, socket: URLSessionWebSocketTask, peer: String,
        session: RemoteSession
    ) -> RemoteReply {
        guard let deviceKey = session.deviceKey else {
            return RemoteReply(
                challenge: command.challenge, sequence: command.sequence, ok: false, error: "Not paired.")
        }
        watcher = Watcher(socket: socket, peer: peer, challenge: session.challenge, deviceKey: deviceKey)
        watchedModel = model
        stream.reset()
        let window = model.selectedTab?.controller.remoteScreenWindow()
        let selected = model.selectedTab?.id.uuidString
        // Prime the stream with what the reply carries, so the next event is a diff.
        if let window { _ = stream.update(window, tabID: selected, force: true) }
        var reply = RemoteReply(challenge: command.challenge, sequence: command.sequence)
        reply.state = RemoteCommands.snapshot(model, screen: window)
        reply = RemoteCommands.fitting(reply)
        lastSentTabs = reply.state?.tabs
        lastSentSelection = selected
        observeModel(model)
        return reply
    }

    private func stopWatching() {
        watcher = nil
        watchedModel = nil
        changeTask?.cancel()
        changeTask = nil
        stream.reset()
        lastSentTabs = nil
        lastSentSelection = nil
    }

    /// Tabs, selection and titles are observable; output and status arrive through the tab hooks.
    private func observeModel(_ model: AppModel) {
        withObservationTracking {
            _ = model.tabs.map { model.title(for: $0) }
            _ = model.selectedTabID
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model, self.watchedModel === model else { return }
                self.noteChange()
                self.observeModel(model)
            }
        }
    }

    private func flushChanges() async {
        guard let watcher, let model = watchedModel else { return }
        let tabs = RemoteCommands.visibleTabs(
            RemoteCommands.tabRecords(model), selectedID: model.selectedTab?.id.uuidString)
        let selected = model.selectedTab?.id.uuidString
        let window = model.selectedTab?.controller.remoteScreenWindow() ?? .empty
        let screen = stream.update(window, tabID: selected)
        let tabsChanged = tabs != lastSentTabs || selected != lastSentSelection
        guard tabsChanged || screen != nil else { return }
        lastSentTabs = tabs
        lastSentSelection = selected
        var frames: [RemoteReply] = []
        var base = RemoteReply(challenge: watcher.challenge, sequence: 0, event: true)
        base.state = RemoteState(
            tabs: tabs, selectedTabID: selected, terminal: "", tabsTruncated: model.tabs.count > 100,
            screen: nil, mac: RemoteCommands.macName)
        if let screen, screen.rows.count > Self.rowsPerEvent {
            // The first frame carries the bounds and theme; the rest only rows.
            var chunks = stride(from: 0, to: screen.rows.count, by: Self.rowsPerEvent).map {
                Array(screen.rows[$0..<min($0 + Self.rowsPerEvent, screen.rows.count)])
            }
            var first = base
            first.state?.screen = screen
            first.state?.screen?.rows = chunks.removeFirst()
            frames.append(first)
            for chunk in chunks {
                var next = base
                next.state?.screen = RemoteScreen(
                    gen: screen.gen, alt: screen.alt, first: screen.first, end: screen.end, rows: chunk)
                frames.append(next)
            }
        } else {
            base.state?.screen = screen
            frames.append(base)
        }
        for frame in frames {
            guard self.watcher?.peer == watcher.peer else { return }
            do {
                let encrypted = try RemoteCrypto.seal(frame, key: watcher.deviceKey, direction: "mac")
                try await send(Frame(peer: watcher.peer, data: encrypted), socket: watcher.socket)
            } catch {
                // The socket loop notices a dead connection and reconnects; the phone re-watches.
                return
            }
        }
    }

    private func revokedElsewhere() {
        // Any local process can post the notice, so act only once the saved pairing is gone.
        guard isEnabled, isPaired, case .success(nil) = Result(catching: { try store.load() }) else { return }
        stop(revoke: true)
    }

    /// The relay drops a silent host while this Mac sleeps, and the FIN can be
    /// lost. receive() then waits forever on a half-open socket. Cancel the
    /// socket when a ping goes unanswered, so the loop reconnects.
    nonisolated static func keepAlive(
        _ socket: URLSessionWebSocketTask, interval: Duration = .seconds(15), timeout: Duration = .seconds(10)
    ) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            let answered = OSAllocatedUnfairLock(initialState: false)
            socket.sendPing { error in answered.withLock { $0 = error == nil } }
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard answered.withLock({ $0 }) else {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func restoredSession(for origin: URL, saved: RemotePairing?) -> RemoteSession {
        guard let saved,
            Self.preferredOrigin(saved.origin) == saved.origin,
            RemoteControl.origin(saved.origin)?.absoluteString == origin.absoluteString,
            RemoteCrypto.isValidKey(saved.deviceKey), RemoteCrypto.isValidKey(saved.ticket)
        else { return RemoteSession() }
        return RemoteSession(deviceKey: saved.deviceKey, ticket: saved.ticket)
    }

    private func allocate(origin: URL, network: URLSession) async throws -> Room {
        var request = URLRequest(url: origin.appendingPathComponent("rooms"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let (data, response) = try await network.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201, data.count <= 1024 else {
            throw RemoteError.invalidMessage
        }
        let room = try JSONDecoder().decode(Room.self, from: data)
        guard room.room.count == 32, room.room.allSatisfy(\.isHexDigit), RemoteCrypto.isValidKey(room.hostToken)
        else { throw RemoteError.invalidMessage }
        return room
    }

    private func send(_ frame: Frame, socket: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(frame)
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    private static func send(_ frame: Frame, thenClose socket: URLSessionWebSocketTask, network: URLSession?) {
        let bytes = (try? JSONEncoder().encode(frame)) ?? Data()
        socket.send(.string(String(decoding: bytes, as: UTF8.self))) { _ in
            socket.cancel(with: .goingAway, reason: nil)
            network?.invalidateAndCancel()
        }
    }

    private struct Room: Decodable {
        let room: String
        let hostToken: String
    }
    private struct Frame: Codable {
        var type: String?
        var route: String?
        var peer: String?
        var hello: String?
        var data: String?
        var error: String?
    }
}
