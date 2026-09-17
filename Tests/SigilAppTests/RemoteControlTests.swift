import Foundation
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
        #expect(store.load() == nil)
        let pairing = RemotePairing(
            origin: "https://example.com", deviceKey: RemoteCrypto.randomKey(),
            ticket: RemoteCrypto.randomKey())
        store.save(pairing)
        #expect(store.load() == pairing)
        store.clear()
        #expect(store.load() == nil)
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
                origin: RemoteControl.legacyApexOrigin, deviceKey: RemoteCrypto.randomKey(),
                ticket: RemoteCrypto.randomKey()))
        let remote = RemoteControl(store: store)
        let model = AppModel()
        remote.resumeIfPaired(model: model)
        #expect(!remote.isEnabled)
        #expect(!remote.isPaired)
        #expect(store.load() != nil)
    }

    @Test @MainActor func retiredOriginDoesNotRestoreWhenStartingAtProduction() {
        let store = InMemoryRemotePairingStore()
        store.save(
            RemotePairing(
                origin: RemoteControl.legacyApexOrigin, deviceKey: RemoteCrypto.randomKey(),
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
        remote.start(urlText: RemoteControl.legacyApexOrigin, model: model)
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
    init(pairing: RemotePairing) { self.pairing = pairing }
    func load() -> RemotePairing? { pairing }
    func save(_ pairing: RemotePairing) { self.pairing = pairing }
    func clear() -> Bool { false }
}
