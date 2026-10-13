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
    @ObservationIgnored private var eventSequence = 0
    @ObservationIgnored private var stream = RemoteScreenStream()
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var changePending = false
    @ObservationIgnored private var flushesInFlight = 0
    @ObservationIgnored private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    /// A deterministic socket-write pause for revocation race tests.
    @ObservationIgnored var afterPushRegistrationSend: (@MainActor () async -> Void)?
    #if DEBUG
        /// Holds an old connection failure while a test reopens a new generation.
        @ObservationIgnored var beforeConnectionFailureHandling: (@MainActor () async -> Void)?
    #endif
    @ObservationIgnored private var lastSentTabs: [RemoteState.Tab]?
    @ObservationIgnored private var lastSentSelection: String?
    @ObservationIgnored private var lastSentPrompt: RemotePrompt?
    @ObservationIgnored private weak var watchedModel: AppModel?
    /// Changes are batched this long, so a burst of output is one frame.
    static let changeDelay: Duration = .milliseconds(80)
    /// The phone's push token, kept with the pairing and re-sent to the relay on every connect.
    @ObservationIgnored private var push: (token: String, environment: String)?
    /// Live Activity push tokens by tab id, for as long as the phone keeps one running.
    @ObservationIgnored private var activities: [String: String] = [:]
    @ObservationIgnored private var planner = RemoteAlertPlanner()
    @ObservationIgnored private var alertTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var deviceKey: String?
    /// The relay's answer to the last push, for tests and the settings page.
    @ObservationIgnored private(set) var lastPushResult: String?
    /// Plaintext bytes per event frame: under the sealed-frame cap with room for the tab list.
    nonisolated static let bytesPerEvent = 44_000
    /// Frames of one flush go out this far apart; the relay closes a socket over 30 frames a second.
    nonisolated static let frameSpacing: Duration = .milliseconds(50)

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
        deviceKey = restored.deviceKey
        if let saved, let token = saved.pushToken, let environment = saved.pushEnvironment,
            RemoteControl.origin(saved.origin)?.absoluteString == origin.absoluteString
        {
            push = (token, environment)
        } else {
            push = nil
        }
        // Tabs keep their alert baseline and activity tokens across relay connections.
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
                            // The relay forgets the token with the room; a fresh room hears it again.
                            if let push = self.push {
                                try await self.send(
                                    Frame(pushToken: push.token, pushEnvironment: push.environment), socket: socket)
                            }
                        } else if frame.type == "peer", let id = frame.peer, id.count <= 64 {
                            if retireRoom { break }
                            self.peer = id
                            self.stopWatching()
                            session.resetConnection()
                            self.eventSequence = 0
                            RemoteCommands.uploads = RemoteUpload.Inbox()
                            // A new peer is not the phone until it authenticates.
                            self.status = session.isPaired ? "Phone disconnected" : "Scan to connect"
                            try await self.send(Frame(peer: id, hello: session.challenge), socket: socket)
                        } else if frame.type == "push" {
                            self.lastPushResult =
                                frame.ok == true ? "ok" : (frame.reason ?? frame.status.map(String.init) ?? "failed")
                        } else if frame.type == "left", frame.peer == self.peer {
                            self.peer = nil
                            self.stopWatching()
                            RemoteCommands.uploads = RemoteUpload.Inbox()
                            self.status = session.isPaired ? "Phone disconnected" : "Scan to connect"
                            if retireRoom { break }
                        } else if let id = frame.peer, id == self.peer, let ciphertext = frame.data {
                            do {
                                let firstPair = !session.isPaired
                                var accepted = session
                                let command: RemoteRequest
                                do {
                                    command = try accepted.accept(ciphertext)
                                } catch {
                                    // Authenticated bounds errors consume their sequence
                                    // and retain the nonce used by the error receipt.
                                    session = accepted
                                    throw error
                                }
                                guard let clientNonce = command.clientNonce else {
                                    let upgrade = RemoteReply(
                                        challenge: command.challenge, sequence: command.sequence,
                                        ok: false, error: "Update Sigil and the phone companion to reconnect securely.")
                                    let sealed = try RemoteCrypto.seal(
                                        upgrade,
                                        key: accepted.deviceKey ?? accepted.pairingKey, direction: "mac")
                                    try await self.send(Frame(peer: id, data: sealed), socket: socket)
                                    continue
                                }
                                session = accepted
                                guard let model else {
                                    self.stop()
                                    return
                                }
                                self.isPaired = true
                                self.pairingURL = nil
                                self.expiresAt = nil
                                self.status = "Phone connected"
                                self.deviceKey = session.deviceKey
                                if firstPair, let key = session.deviceKey {
                                    retireRoom = true
                                    self.push = nil
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
                                } else if command.action == "notify" {
                                    reply = try await self.registerPush(
                                        command, model: model, origin: origin, session: session, socket: socket)
                                } else if command.action == "activity" {
                                    reply = self.registerActivity(command, model: model)
                                } else {
                                    if command.action == "options" {
                                        await RemoteCommands.refreshModels(model: model)
                                    }
                                    guard self.generation == current, !Task.isCancelled,
                                        self.peer == id, self.socket === socket
                                    else { return }
                                    reply = await RemoteCommands.execute(command, model: model)
                                }
                                guard self.generation == current, !Task.isCancelled,
                                    self.peer == id, self.socket === socket
                                else { return }
                                reply.ticket = session.ticket
                                reply.clientNonce = clientNonce
                                let encrypted = try RemoteCrypto.seal(
                                    reply, key: session.deviceKey!, direction: "mac")
                                try await self.send(Frame(peer: id, data: encrypted), socket: socket)
                            } catch RemoteError.outOfBounds(let sequence) {
                                // The pairing is fine; only this request was too large.
                                let reply = RemoteReply(
                                    challenge: session.challenge, sequence: sequence, ok: false,
                                    error: "Too long to send. Shorten it and try again.",
                                    clientNonce: session.acceptedClientNonce)
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
                    #if DEBUG
                        if let beforeConnectionFailureHandling { await beforeConnectionFailureHandling() }
                    #endif
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.stopWatching()
                    self.socket?.cancel(with: .goingAway, reason: nil)
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

    /// A rendered Cancel is bound to the pending attempt, not a saved pairing.
    var pendingPairingGeneration: UUID? { isEnabled && !isPaired ? generation : nil }

    func cancelPairing() {
        guard let pending = pendingPairingGeneration else { return }
        cancelPairing(generation: pending)
    }

    func cancelPairing(generation pending: UUID) {
        guard pendingPairingGeneration == pending else { return }
        stop()
    }

    func stop(revoke: Bool = false) {
        let forgotten = !revoke || store.clear()
        if revoke {
            store.revokeFailed = !forgotten
            revokeFailed = !forgotten
            // The next phone must not inherit this one's alerts or Lock Screen cards.
            push = nil
            activities = [:]
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

    // MARK: Alerts

    /// `notify`: the phone's APNs token, or empty to stop alerts. Saved with the
    /// pairing and told to the relay now and on every reconnect.
    private func registerPush(
        _ command: RemoteRequest, model: AppModel, origin: URL, session: RemoteSession,
        socket: URLSessionWebSocketTask
    ) async throws -> RemoteReply {
        let token = (command.text ?? "").lowercased()
        let environment = command.name ?? "production"
        let registration: Frame
        if token.isEmpty {
            push = nil
            registration = Frame(pushTokenCleared: true)
        } else {
            guard token.utf8.count >= 64, token.utf8.count <= 200, RemoteCrypto.isLowerHex(token),
                ["production", "development"].contains(environment)
            else {
                return RemoteReply(
                    challenge: command.challenge, sequence: command.sequence, ok: false,
                    error: "That alert token is not usable.")
            }
            push = (token, environment)
            registration = Frame(pushToken: token, pushEnvironment: environment)
        }
        if let key = session.deviceKey {
            _ = store.save(
                RemotePairing(
                    origin: origin.absoluteString, deviceKey: key, ticket: session.ticket, pushToken: push?.token,
                    pushEnvironment: push?.environment))
        }
        // Persist before suspension. Revocation during the socket write must
        // never be undone by saving an old key when that write returns.
        try await send(registration, socket: socket)
        await afterPushRegistrationSend?()
        var reply = RemoteReply(challenge: command.challenge, sequence: command.sequence)
        reply.state = RemoteCommands.snapshot(model)
        return RemoteCommands.fitting(reply)
    }

    /// `activity`: a Live Activity push token for one tab, or empty when the activity ended.
    private func registerActivity(_ command: RemoteRequest, model: AppModel) -> RemoteReply {
        guard let tabID = command.tabID, model.tabs.contains(where: { $0.id.uuidString == tabID }) else {
            return RemoteReply(
                challenge: command.challenge, sequence: command.sequence, ok: false, error: "This tab is closed.")
        }
        let token = (command.text ?? "").lowercased()
        if token.isEmpty {
            activities[tabID] = nil
        } else {
            guard token.utf8.count >= 64, token.utf8.count <= 200, RemoteCrypto.isLowerHex(token) else {
                return RemoteReply(
                    challenge: command.challenge, sequence: command.sequence, ok: false,
                    error: "That activity token is not usable.")
            }
            activities[tabID] = token
        }
        var reply = RemoteReply(challenge: command.challenge, sequence: command.sequence)
        reply.state = RemoteCommands.snapshot(model)
        return RemoteCommands.fitting(reply)
    }

    /// A tab's status or screen changed. Reads the tab shortly after, so a burst
    /// of output is one look, and sends what the phone would otherwise miss.
    func noteTab(_ tab: TerminalTab, model: AppModel, suppressAlerts: Bool = false) {
        if suppressAlerts {
            evaluate(tab, model: model, allowAlerts: false)
            return
        }
        let id = tab.id.uuidString
        // The first look sets the baseline at once, so the next change is a transition.
        if !planner.knownTabs.contains(id) { evaluate(tab, model: model) }
        guard alertTasks[id] == nil else { return }
        alertTasks[id] = Task { @MainActor [weak self, weak tab, weak model] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.alertTasks[id] = nil
            guard !Task.isCancelled, let tab, let model else { return }
            self.evaluate(tab, model: model)
        }
    }

    private func evaluate(_ tab: TerminalTab, model: AppModel, allowAlerts: Bool = true) {
        let id = tab.id.uuidString
        let prompt = RemoteCommands.prompt(for: tab)
        let snapshot = RemoteAlertPlanner.Snapshot(
            status: tab.activity.statusName, since: Int((tab.workingSince ?? Date()).timeIntervalSince1970),
            question: prompt?.question, title: RemoteCommands.bounded(model.title(for: tab), bytes: 96),
            interactionID: prompt?.id, verified: prompt?.verified == true)
        let plan = planner.plan(tabID: id, snapshot)
        // A phone on the socket sees the change itself; alerts are for a phone that is away.
        guard allowAlerts, peer == nil, let socket else { return }
        if let alert = plan.alert, push != nil, let deviceKey {
            if let sealed = try? RemoteCrypto.seal(alert, key: deviceKey, direction: RemoteAlert.direction) {
                let frame = Frame(push: .init(data: sealed, thread: id))
                Task { try? await self.send(frame, socket: socket) }
            }
        }
        if let state = plan.activity, let token = activities[id] {
            let frame = Frame(push: .init(activity: token, state: state, event: plan.ends ? "end" : "update"))
            if plan.ends { activities[id] = nil }
            Task { try? await self.send(frame, socket: socket) }
        }
    }

    /// A closed tab neither alerts nor updates again.
    func forgetTab(_ id: TerminalTab.ID) {
        let key = id.uuidString
        // Closed while the phone was away: its card ends now, or it would outlive the tab.
        if let token = activities[key], peer == nil, let socket {
            let state = RemoteActivityState(
                status: "exited", since: Int(Date().timeIntervalSince1970), asking: false)
            let frame = Frame(push: .init(activity: token, state: state, event: "end"))
            Task { try? await self.send(frame, socket: socket) }
        }
        planner.forget(tabID: key)
        activities[key] = nil
        alertTasks[key]?.cancel()
        alertTasks[key] = nil
    }

    // MARK: Events

    private struct Watcher {
        let id = UUID()
        let socket: URLSessionWebSocketTask
        let peer: String
        let challenge: String
        let deviceKey: String
        let clientNonce: String
    }

    /// Any change the phone should see: output, status, tabs, selection, titles.
    func noteChange() {
        guard let watcher else { return }
        changePending = true
        guard changeTask == nil else { return }
        changeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.changePending {
                try? await Task.sleep(for: Self.changeDelay)
                guard !Task.isCancelled, self.watcher?.id == watcher.id else { return }
                self.changePending = false
                await self.flushChanges()
                guard !Task.isCancelled, self.watcher?.id == watcher.id else { return }
            }
            self.changeTask = nil
        }
    }

    /// Waits until every change noted so far has gone out, for ordering tests.
    /// It waits for every flush, not only the change loop, so it holds even if flushes overlap.
    func changesSent() async {
        var finished: Task<Void, Never>?
        while true {
            // An early return leaves the finished task in place; do not wait on it again.
            if let task = changeTask, task != finished {
                await task.value
                finished = task
            } else if flushesInFlight > 0 {
                await withCheckedContinuation { flushWaiters.append($0) }
            } else {
                return
            }
        }
    }

    private func startWatching(
        _ command: RemoteRequest, model: AppModel, socket: URLSessionWebSocketTask, peer: String,
        session: RemoteSession
    ) -> RemoteReply {
        guard let deviceKey = session.deviceKey, let clientNonce = command.clientNonce else {
            return RemoteReply(
                challenge: command.challenge, sequence: command.sequence, ok: false, error: "Not paired.")
        }
        stopWatching()
        watcher = Watcher(
            socket: socket, peer: peer, challenge: session.challenge, deviceKey: deviceKey, clientNonce: clientNonce)
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
        lastSentPrompt = reply.state?.prompt
        observeModel(model)
        return reply
    }

    private func stopWatching() {
        watcher = nil
        watchedModel = nil
        changeTask?.cancel()
        changeTask = nil
        changePending = false
        stream.reset()
        lastSentTabs = nil
        lastSentSelection = nil
        lastSentPrompt = nil
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
        flushesInFlight += 1
        defer {
            flushesInFlight -= 1
            if flushesInFlight == 0 {
                for waiter in flushWaiters { waiter.resume() }
                flushWaiters = []
            }
        }
        guard let watcher, let model = watchedModel else { return }
        let tabs = RemoteCommands.visibleTabs(
            RemoteCommands.tabRecords(model), selectedID: model.selectedTab?.id.uuidString)
        let selected = model.selectedTab?.id.uuidString
        let window = model.selectedTab?.controller.remoteScreenWindow() ?? .empty
        let screen = stream.update(window, tabID: selected)
        let prompt = model.selectedTab.flatMap(RemoteCommands.prompt(for:))
        let tabsChanged = tabs != lastSentTabs || selected != lastSentSelection || prompt != lastSentPrompt
        guard tabsChanged || screen != nil else { return }
        lastSentTabs = tabs
        lastSentSelection = selected
        lastSentPrompt = prompt
        let frames: [RemoteReply]
        var base = RemoteReply(challenge: watcher.challenge, sequence: 0, event: true)
        base.clientNonce = watcher.clientNonce
        base.state = RemoteState(
            tabs: tabs, selectedTabID: selected, terminal: "", tabsTruncated: model.tabs.count > 100,
            screen: nil, mac: RemoteCommands.macName, prompt: prompt)
        frames = Self.frames(base: base, screen: screen)
        for (index, value) in frames.enumerated() {
            if index > 0 { try? await Task.sleep(for: Self.frameSpacing) }
            guard self.watcher?.id == watcher.id, self.watcher?.challenge == watcher.challenge,
                self.watcher?.socket === watcher.socket, !Task.isCancelled
            else { return }
            guard eventSequence < 9_007_199_254_740_991 else {
                watcher.socket.cancel(with: .goingAway, reason: nil)
                return
            }
            eventSequence += 1
            var frame = value
            frame.eventSequence = eventSequence
            do {
                let encrypted = try RemoteCrypto.seal(frame, key: watcher.deviceKey, direction: "mac")
                try await send(Frame(peer: watcher.peer, data: encrypted), socket: watcher.socket)
            } catch {
                // The socket loop notices a dead connection and reconnects; the phone re-watches.
                return
            }
        }
    }

    /// Splits the changed rows over as many frames as their encoded size needs.
    /// The first frame carries the bounds and theme; the rest only rows. A row too
    /// big for a frame on its own loses its styles, then its tail.
    nonisolated static func frames(base: RemoteReply, screen: RemoteScreen?, limit: Int = bytesPerEvent)
        -> [RemoteReply]
    {
        guard let screen else { return [base] }
        let encoder = JSONEncoder()
        func size<T: Encodable>(_ value: T) -> Int { (try? encoder.encode(value).count) ?? limit }
        var header = screen
        header.rows = []
        var headerFrame = base
        headerFrame.state?.screen = header
        let tail = RemoteScreen(
            tab: screen.tab, gen: screen.gen, alt: screen.alt, first: screen.first, end: screen.end, rows: [])
        var tailFrame = base
        tailFrame.state?.screen = tail
        let budgets = [limit - size(headerFrame), limit - size(tailFrame)]
        var frames: [RemoteReply] = []
        var rows: [RemoteScreen.Row] = []
        var used = 0
        func flush() {
            var frame = frames.isEmpty ? headerFrame : tailFrame
            frame.state?.screen?.rows = rows
            frames.append(frame)
            rows = []
            used = 0
        }
        for var row in screen.rows {
            var cost = size(row) + 1
            let budget = max(budgets[frames.isEmpty ? 0 : 1], 1_024)
            if cost > budget {
                row.s = nil
                cost = size(row) + 1
                if cost > budget {
                    row.t = String(row.t.prefix(max(budget / 4, 16)))
                    cost = size(row) + 1
                }
            }
            if !rows.isEmpty, used + cost > budget { flush() }
            rows.append(row)
            used += cost
        }
        if !rows.isEmpty || frames.isEmpty { flush() }
        return frames
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
    struct Frame: Codable {
        struct Push: Codable {
            var data: String?
            var thread: String?
            var activity: String?
            var state: RemoteActivityState?
            var event: String?

            init(data: String, thread: String) {
                self.data = data
                self.thread = thread
            }

            init(activity: String, state: RemoteActivityState, event: String) {
                self.activity = activity
                self.state = state
                self.event = event
            }
        }

        var type: String?
        var route: String?
        var peer: String?
        var hello: String?
        var data: String?
        var error: String?
        var pushToken: String?
        var pushEnvironment: String?
        var push: Push?
        var ok: Bool?
        var status: Int?
        var reason: String?
        /// `{"pushToken": null}` tells the relay to forget the token; nil would drop the key.
        var pushTokenCleared = false

        init(
            type: String? = nil, route: String? = nil, peer: String? = nil, hello: String? = nil,
            data: String? = nil, error: String? = nil, pushToken: String? = nil, pushEnvironment: String? = nil,
            push: Push? = nil, pushTokenCleared: Bool = false
        ) {
            self.type = type
            self.route = route
            self.peer = peer
            self.hello = hello
            self.data = data
            self.error = error
            self.pushToken = pushToken
            self.pushEnvironment = pushEnvironment
            self.push = push
            self.pushTokenCleared = pushTokenCleared
        }

        private enum CodingKeys: String, CodingKey {
            case type, route, peer, hello, data, error, pushToken, pushEnvironment, push, ok, status, reason
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(type, forKey: .type)
            try c.encodeIfPresent(route, forKey: .route)
            try c.encodeIfPresent(peer, forKey: .peer)
            try c.encodeIfPresent(hello, forKey: .hello)
            try c.encodeIfPresent(data, forKey: .data)
            try c.encodeIfPresent(error, forKey: .error)
            if pushTokenCleared {
                try c.encodeNil(forKey: .pushToken)
            } else {
                try c.encodeIfPresent(pushToken, forKey: .pushToken)
            }
            try c.encodeIfPresent(pushEnvironment, forKey: .pushEnvironment)
            try c.encodeIfPresent(push, forKey: .push)
        }
    }
}
