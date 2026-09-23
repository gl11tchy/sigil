import Foundation
import Network
import Security
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
struct RemoteControlTests {
    @Test @MainActor func memoryStoreRoundTripsAndClearsPairing() {
        let store = InMemoryRemotePairingStore()
        let pairing = RemotePairing(
            origin: "https://example.com", deviceKey: RemoteCrypto.randomKey(),
            ticket: RemoteCrypto.randomKey())
        store.save(pairing)
        #expect(store.load() == pairing)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test @MainActor func keychainStoreRoundTripsAndClearsPairing() throws {
        let service = "app.sigil.remote.test.\(UUID().uuidString)"
        let store = KeychainRemotePairingStore(service: service)
        defer { store.clear() }
        #expect(try store.load() == nil)
        let pairing = RemotePairing(
            origin: "https://example.com", deviceKey: RemoteCrypto.randomKey(),
            ticket: RemoteCrypto.randomKey())
        store.save(pairing)
        #expect(try store.load() == pairing)
        store.clear()
        #expect(try store.load() == nil)
    }

    @Test @MainActor func failedRevokeKeepsTheStoredPairing() {
        let store = FailingClearStore(
            pairing: RemotePairing(
                origin: "https://example.com", deviceKey: RemoteCrypto.randomKey(),
                ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        let model = AppModel()
        remote.start(urlText: "https://example.com", model: model)
        remote.stop(revoke: true)
        #expect(store.load() != nil)
        #expect(remote.error == "Could not forget this phone. Try Disconnect again.")
        #expect(!remote.isEnabled)
    }

    @Test @MainActor func failedRevokeIsNotRestoredByConnectOrAtLaunch() {
        let origin = "http://127.0.0.1:9"
        let store = FailingClearStore(
            pairing: RemotePairing(
                origin: origin, deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey()))
        let model = AppModel()
        let remote = RemoteControl(store: store)
        remote.start(urlText: origin, model: model)
        #expect(remote.isPaired)
        remote.stop(revoke: true)
        remote.start(urlText: origin, model: model)
        #expect(!remote.isPaired)
        remote.stop()
        let relaunched = RemoteControl(store: store)
        relaunched.resumeIfPaired(model: model)
        #expect(!relaunched.isEnabled)
        store.clearSucceeds = true
        relaunched.stop(revoke: true)
        store.save(
            RemotePairing(origin: origin, deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey()))
        relaunched.resumeIfPaired(model: model)
        #expect(relaunched.isPaired)
        relaunched.stop()
    }

    @Test @MainActor func failedRevokeKeepsDisconnectAvailableUntilItSucceeds() {
        let store = FailingClearStore(
            pairing: RemotePairing(
                origin: "http://127.0.0.1:9", deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        #expect(!remote.revokeFailed)
        remote.start(urlText: "http://127.0.0.1:9", model: AppModel())
        remote.stop(revoke: true)
        #expect(remote.revokeFailed)
        #expect(RemoteControl(store: store).revokeFailed)
        store.clearSucceeds = true
        remote.stop(revoke: true)
        #expect(!remote.revokeFailed)
        #expect(remote.error == nil)
    }

    @Test @MainActor func launchReadsTheSavedPairingOnlyOnce() {
        let store = CountingStore(
            pairing: RemotePairing(
                origin: "http://127.0.0.1:9", deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        remote.resumeIfPaired(model: AppModel())
        defer { remote.stop() }
        #expect(remote.isPaired)
        #expect(store.loads == 1)
    }

    @Test @MainActor func unreadableSavedPairingIsReportedAtLaunch() {
        let remote = RemoteControl(store: UnreadableStore())
        remote.resumeIfPaired(model: AppModel())
        #expect(!remote.isEnabled)
        #expect(remote.error == "Sigil could not read the saved phone pairing. Connect your phone again.")
    }

    @Test func keychainTreatsOnlyAMissingItemAsNotPaired() throws {
        #expect(try KeychainRemotePairingStore.pairing(status: errSecItemNotFound, item: nil) == nil)
        #expect(throws: KeychainRemotePairingStore.ReadError(status: errSecAuthFailed)) {
            try KeychainRemotePairingStore.pairing(status: errSecAuthFailed, item: nil)
        }
        #expect(throws: KeychainRemotePairingStore.ReadError(status: errSecUserCanceled)) {
            try KeychainRemotePairingStore.pairing(status: errSecUserCanceled, item: nil)
        }
        let pairing = RemotePairing(
            origin: "https://example.com", deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey())
        let item = try JSONEncoder().encode(pairing) as CFData
        #expect(try KeychainRemotePairingStore.pairing(status: errSecSuccess, item: item) == pairing)
    }

    @Test @MainActor func restoredPairingDoesNotShowAQRAndSurvivesStop() {
        let store = InMemoryRemotePairingStore()
        store.save(
            RemotePairing(
                origin: "https://example.com", deviceKey: RemoteCrypto.randomKey(),
                ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        let model = AppModel()
        remote.start(urlText: "https://example.com", model: model)
        #expect(remote.isEnabled)
        #expect(remote.isPaired)
        #expect(remote.pairingURL == nil)
        #expect(remote.expiresAt == nil)
        remote.stop()
        #expect(store.load() != nil)
        #expect(!remote.isEnabled)
        remote.stop(revoke: true)
        #expect(store.load() == nil)
    }

    @Test @MainActor func resumeStartsOnlyWhenPairingExists() {
        let store = InMemoryRemotePairingStore()
        let remote = RemoteControl(store: store)
        let model = AppModel()
        remote.resumeIfPaired(model: model)
        #expect(!remote.isEnabled)
        store.save(
            RemotePairing(
                origin: "https://example.com", deviceKey: RemoteCrypto.randomKey(),
                ticket: RemoteCrypto.randomKey()))
        remote.resumeIfPaired(model: model)
        #expect(remote.isEnabled)
        #expect(remote.isPaired)
        remote.stop(revoke: true)
    }

    @Test @MainActor func retiredOriginDoesNotResume() {
        let store = InMemoryRemotePairingStore()
        store.save(
            RemotePairing(
                origin: RemoteControl.legacyRailwayOrigin, deviceKey: RemoteCrypto.randomKey(),
                ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        let model = AppModel()
        remote.resumeIfPaired(model: model)
        #expect(!remote.isEnabled)
        #expect(!remote.isPaired)
        #expect(store.load() != nil)
        store.save(
            RemotePairing(
                origin: RemoteControl.legacyApexOrigin, deviceKey: RemoteCrypto.randomKey(),
                ticket: RemoteCrypto.randomKey()))
        remote.resumeIfPaired(model: model)
        #expect(!remote.isEnabled)
        #expect(!remote.isPaired)
    }

    @Test @MainActor func retiredOriginDoesNotRestoreWhenStartingAtProduction() {
        let store = InMemoryRemotePairingStore()
        store.save(
            RemotePairing(
                origin: RemoteControl.legacyRailwayOrigin, deviceKey: RemoteCrypto.randomKey(),
                ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        let model = AppModel()
        remote.start(urlText: RemoteControl.productionOrigin, model: model)
        #expect(remote.isEnabled)
        #expect(!remote.isPaired)
        remote.stop()
    }

    @Test @MainActor func startRewritesRetiredOriginOntoALivePairing() {
        let store = InMemoryRemotePairingStore()
        store.save(
            RemotePairing(
                origin: RemoteControl.productionOrigin, deviceKey: RemoteCrypto.randomKey(),
                ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        let model = AppModel()
        remote.start(urlText: RemoteControl.legacyRailwayOrigin, model: model)
        #expect(remote.isEnabled)
        #expect(remote.isPaired)
        remote.stop(revoke: true)
    }

    @Test @MainActor func productionOriginPairingStillResumes() {
        let store = InMemoryRemotePairingStore()
        store.save(
            RemotePairing(
                origin: RemoteControl.productionOrigin, deviceKey: RemoteCrypto.randomKey(),
                ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        let model = AppModel()
        remote.resumeIfPaired(model: model)
        #expect(remote.isEnabled)
        #expect(remote.isPaired)
        remote.stop(revoke: true)
    }

    @Test func reconnectPolicyNeverGivesUpAndReallocatesEveryThreeFailures() {
        #expect(RemoteReconnectPolicy.retrySeconds(failures: 1) == 1)
        #expect(RemoteReconnectPolicy.retrySeconds(failures: 2) == 2)
        #expect(RemoteReconnectPolicy.retrySeconds(failures: 5) == 16)
        #expect(RemoteReconnectPolicy.retrySeconds(failures: 8) == 30)
        #expect(!RemoteReconnectPolicy.shouldReallocate(failures: 1))
        #expect(RemoteReconnectPolicy.shouldReallocate(failures: 3))
        #expect(RemoteReconnectPolicy.shouldReallocate(failures: 6))
        #expect(!RemoteReconnectPolicy.shouldGiveUp(failures: 100))
    }

    @Test func keepAliveCancelsASocketWhosePingsGoUnanswered() async throws {
        let server = try LocalWebSocketServer(answersPings: false)
        defer { server.stop() }
        let socket = URLSession(configuration: .ephemeral)
            .webSocketTask(with: URL(string: "ws://127.0.0.1:\(try await server.port())/")!)
        socket.resume()
        let keepAlive = Task {
            await RemoteControl.keepAlive(socket, interval: .milliseconds(100), timeout: .milliseconds(300))
        }
        let fallback = Task {
            try await Task.sleep(for: .seconds(10))
            socket.cancel()
        }
        defer {
            keepAlive.cancel()
            fallback.cancel()
        }
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) { _ = try await socket.receive() }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func keepAliveLeavesAnAnsweringSocketOpen() async throws {
        let server = try LocalWebSocketServer(answersPings: true)
        defer { server.stop() }
        let socket = URLSession(configuration: .ephemeral)
            .webSocketTask(with: URL(string: "ws://127.0.0.1:\(try await server.port())/")!)
        socket.resume()
        // URLSession reads pongs only while a receive is pending, as in the host loop.
        let receiving = Task { try? await socket.receive() }
        let keepAlive = Task {
            await RemoteControl.keepAlive(socket, interval: .milliseconds(100), timeout: .milliseconds(300))
        }
        try await Task.sleep(for: .seconds(1.5))
        #expect(socket.state == .running)
        keepAlive.cancel()
        socket.cancel()
        _ = await receiving.value
    }

    @Test func remoteReplyCarriesAnOptionalTicket() throws {
        var reply = RemoteReply(challenge: "c", sequence: 1)
        reply.ticket = String(repeating: "ab", count: 32)
        let decoded = try JSONDecoder().decode(RemoteReply.self, from: try JSONEncoder().encode(reply))
        #expect(decoded.ticket == reply.ticket)
        let bare = try JSONDecoder().decode(
            RemoteReply.self, from: try JSONEncoder().encode(RemoteReply(challenge: "c", sequence: 2)))
        #expect(bare.ticket == nil)
    }
}

private final class FailingClearStore: RemotePairingStore {
    private var pairing: RemotePairing?
    var clearSucceeds = false
    var revokeFailed = false
    init(pairing: RemotePairing) { self.pairing = pairing }
    func load() -> RemotePairing? { pairing }
    func save(_ pairing: RemotePairing) { self.pairing = pairing }
    func clear() -> Bool {
        guard clearSucceeds else { return false }
        pairing = nil
        return true
    }
}

private final class CountingStore: RemotePairingStore {
    private let pairing: RemotePairing
    private(set) var loads = 0
    var revokeFailed = false
    init(pairing: RemotePairing) { self.pairing = pairing }
    func load() -> RemotePairing? {
        loads += 1
        return pairing
    }
    func save(_: RemotePairing) {}
    func clear() -> Bool { true }
}

private final class UnreadableStore: RemotePairingStore {
    var revokeFailed = false
    func load() throws -> RemotePairing? { throw KeychainRemotePairingStore.ReadError(status: errSecAuthFailed) }
    func save(_: RemotePairing) {}
    func clear() -> Bool { true }
}

/// A WebSocket server on loopback that can ignore pings, like a relay that
/// dropped this Mac while it slept.
private final class LocalWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "sigil.test.websocket")
    private var connections: [NWConnection] = []

    init(answersPings: Bool) throws {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = answersPings
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            Self.drain(connection)
        }
    }

    func port() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            for connection in connections { connection.cancel() }
            connections = []
        }
        listener.cancel()
    }

    private static func drain(_ connection: NWConnection) {
        connection.receiveMessage { _, _, _, error in
            if error == nil { drain(connection) }
        }
    }
}
