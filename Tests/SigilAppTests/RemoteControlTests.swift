import AppKit
import Foundation
import Network
import Security
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
struct RemoteControlTests {
    @Test @MainActor func cancellingPendingOriginBPreservesOriginAAndAnotherCopy() throws {
        let fixture = try PairingCancellationFixture()
        defer { fixture.cleanup() }
        let pairing = RemotePairing(
            origin: "https://pairing-a.invalid", deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey())
        let store = InMemoryRemotePairingStore()
        store.save(pairing)
        let center = NotificationCenter()
        let notices = PairingRevokeLog()
        let token = center.addObserver(forName: RemoteControl.revokedNotification, object: nil, queue: nil) { _ in
            notices.record()
        }
        defer { center.removeObserver(token) }
        let existing = RemoteControl(store: store, notifications: center)
        let pending = RemoteControl(store: store, notifications: center)
        defer {
            existing.stop()
            pending.stop()
        }
        // No actor suspension: these synthetic starts are cancelled before
        // their queued network tasks can execute or contact these .invalid hosts.
        existing.resumeIfPaired(model: fixture.model)
        pending.start(urlText: "https://pairing-b.invalid", model: fixture.model)
        #expect(existing.isPaired)
        #expect(!pending.isPaired)
        pending.cancelPairing()
        #expect(store.load() == pairing)
        #expect(notices.count == 0)
        #expect(existing.isEnabled && existing.isPaired)
        #expect(!pending.isEnabled)
        let reopened = RemoteControl(store: store, notifications: center)
        reopened.resumeIfPaired(model: fixture.model)
        defer { reopened.stop() }
        #expect(reopened.isPaired)
    }

    @Test @MainActor func anOldCancelCannotStopAReopenedPendingGeneration() throws {
        let fixture = try PairingCancellationFixture()
        defer { fixture.cleanup() }
        let saved = fakePairing(origin: "https://pairing-a.invalid")
        let store = PairingCancellationStore(saved: saved)
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.start(urlText: "https://pairing-b.invalid", model: fixture.model)
        let old = try #require(remote.pendingPairingGeneration)
        remote.cancelPairing(generation: old)
        #expect(!remote.isEnabled)
        remote.start(urlText: "https://pairing-b.invalid", model: fixture.model)
        let fresh = try #require(remote.pendingPairingGeneration)
        #expect(fresh != old)
        remote.cancelPairing(generation: old)
        #expect(remote.isEnabled && !remote.isPaired)
        #expect(remote.pendingPairingGeneration == fresh)
        #expect(store.saved == saved)
        #expect(store.clears == 0 && store.saves == 0)
        remote.cancelPairing(generation: fresh)
        #expect(!remote.isEnabled)
        remote.cancelPairing()
        #expect(store.clears == 0)
    }

    @Test @MainActor func cancelDoesNotReadOrClearAnUnreadableSavedPairing() throws {
        let fixture = try PairingCancellationFixture()
        defer { fixture.cleanup() }
        let saved = fakePairing(origin: "https://pairing-a.invalid")
        let store = PairingCancellationStore(saved: saved)
        store.readFails = true
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.start(urlText: "https://pairing-b.invalid", model: fixture.model)
        let reads = store.loads
        #expect(!remote.isPaired)
        remote.cancelPairing()
        #expect(store.loads == reads)
        #expect(store.clears == 0 && store.saves == 0)
        #expect(store.saved == saved)
        store.readFails = false
        remote.resumeIfPaired(model: fixture.model)
        #expect(remote.isPaired)
    }

    @Test(arguments: [RemoteControl.legacyRailwayOrigin, RemoteControl.legacyApexOrigin]) @MainActor
    func cancelKeepsARetiredOriginsSavedPairing(origin: String) throws {
        let fixture = try PairingCancellationFixture()
        defer { fixture.cleanup() }
        let saved = fakePairing(origin: origin)
        let store = PairingCancellationStore(saved: saved)
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        // This synchronous attempt never reaches the retired or live relay.
        remote.start(urlText: "https://pairing-b.invalid", model: fixture.model)
        #expect(remote.isEnabled && !remote.isPaired)
        remote.cancelPairing()
        #expect(store.saved == saved)
        #expect(store.clears == 0 && store.saves == 0)
        #expect(!remote.isEnabled)
    }

    @Test @MainActor func cancelPreservesTheFailedDisconnectRetryUntilExplicitDisconnectSucceeds() throws {
        let fixture = try PairingCancellationFixture()
        defer { fixture.cleanup() }
        let saved = fakePairing(origin: "https://pairing-a.invalid")
        let store = PairingCancellationStore(saved: saved)
        store.clearSucceeds = false
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.resumeIfPaired(model: fixture.model)
        remote.stop(revoke: true)
        #expect(store.revokeFailed && remote.revokeFailed)
        remote.start(urlText: "https://pairing-b.invalid", model: fixture.model)
        #expect(!remote.isPaired)
        let clears = store.clears
        remote.cancelPairing()
        #expect(store.clears == clears)
        #expect(store.saved == saved)
        #expect(store.revokeFailed && remote.revokeFailed)
        remote.cancelPairing()
        #expect(remote.revokeFailed)
        store.clearSucceeds = true
        remote.stop(revoke: true)
        #expect(store.saved == nil)
        #expect(!store.revokeFailed && !remote.revokeFailed)
    }

    @Test(arguments: [false, true]) @MainActor
    func confirmationJustBeforeCancelKeepsTheLivePairingEvenWhenSaveFails(saveSucceeds: Bool) async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let fixture = try PairingCancellationFixture()
        defer { fixture.cleanup() }
        let old = fakePairing(origin: "https://pairing-a.invalid")
        let store = PairingCancellationStore(saved: old)
        store.saveSucceeds = saveSucceeds
        let center = NotificationCenter()
        let notices = PairingRevokeLog()
        let observer = center.addObserver(forName: RemoteControl.revokedNotification, object: nil, queue: nil) { _ in
            notices.record()
        }
        defer { center.removeObserver(observer) }
        let remote = RemoteControl(store: store, notifications: center)
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: fixture.model)
        let pending = try #require(remote.pendingPairingGeneration)
        let renderedCancel = { remote.cancelPairing(generation: pending) }
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }
        renderedCancel()
        remote.cancelPairing()
        #expect(remote.isEnabled && remote.isPaired)
        #expect(remote.pendingPairingGeneration == nil)
        #expect(store.clears == 0 && store.saves == 1)
        #expect(notices.count == 0)
        let expected =
            saveSucceeds
            ? RemotePairing(origin: relay.origin, deviceKey: paired.device, ticket: paired.ticket) : old
        #expect(store.saved == expected)
        #expect((remote.error != nil) == !saveSucceeds)
        let state = try await paired.phone.request(
            RemoteRequest(challenge: paired.challenge, sequence: 2, action: "state"), key: paired.device)
        #expect(state.ok)
        #expect(remote.status == "Phone connected")
    }

    @Test @MainActor func cancellationBeforeConfirmationRejectsLateOldCodeTraffic() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let fixture = try PairingCancellationFixture()
        defer { fixture.cleanup() }
        let saved = fakePairing(origin: "https://pairing-a.invalid")
        let store = PairingCancellationStore(saved: saved)
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: fixture.model)
        try await waitForPairing { remote.pairingURL != nil }
        let link = try #require(remote.pairingURL)
        var parts = URLComponents()
        parts.query = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.fragment)
        let room = try #require(parts.queryItems?.first { $0.name == "room" }?.value)
        let key = try #require(parts.queryItems?.first { $0.name == "key" }?.value)
        let phone = try RelayPhone(relay: relay)
        defer { phone.close() }
        let challenge = try await phone.route(["room": room])
        let old = try #require(remote.pendingPairingGeneration)
        remote.cancelPairing(generation: old)
        #expect(!remote.isEnabled && !remote.isPaired)
        remote.start(urlText: relay.origin, model: fixture.model)
        try await waitForPairing { remote.pairingURL != nil }
        let freshLink = remote.pairingURL
        let fresh = try #require(remote.pendingPairingGeneration)
        #expect(fresh != old && freshLink != link)
        let late = RemoteRequest(challenge: challenge, sequence: 1, action: "pair", text: RemoteCrypto.randomKey())
        try? await phone.send(["data": RemoteCrypto.seal(late, key: key, direction: "phone")])
        try await Task.sleep(for: .milliseconds(100))
        #expect(remote.isEnabled && !remote.isPaired)
        #expect(remote.pendingPairingGeneration == fresh)
        #expect(remote.pairingURL == freshLink)
        #expect(store.saved == saved)
        #expect(store.saves == 0 && store.clears == 0)
    }

    @Test @MainActor func aCancelledGenerationsLateFailureCannotCloseTheReopenedSavedConnection() async throws {
        let a = try await RelayFixture()
        defer { a.stop() }
        let b = try await RelayFixture()
        defer { b.stop() }
        let fixture = try PairingCancellationFixture()
        defer { fixture.cleanup() }
        let saved = fakePairing(origin: a.origin)
        let store = PairingCancellationStore(saved: saved)
        let remote = RemoteControl(store: store)
        let gate = PairingFailureGate()
        defer {
            gate.release()
            remote.beforeConnectionFailureHandling = nil
            remote.stop()
        }
        remote.beforeConnectionFailureHandling = { await gate.hold() }
        remote.start(urlText: b.origin, model: fixture.model)
        try await waitForPairing { remote.pairingURL != nil }
        remote.cancelPairing()
        try await waitForPairing { gate.arrived }
        remote.beforeConnectionFailureHandling = nil
        remote.resumeIfPaired(model: fixture.model)
        try await waitForPairing { remote.status == "Phone disconnected" }
        let phone = try RelayPhone(relay: a)
        defer { phone.close() }
        let challenge = try await phone.route(["ticket": saved.ticket])
        let first = try await phone.request(
            RemoteRequest(challenge: challenge, sequence: 1, action: "state"), key: saved.deviceKey)
        #expect(first.ok && remote.isPaired)
        gate.release()
        try await waitForPairing { gate.returned }
        let after = try await phone.request(
            RemoteRequest(challenge: challenge, sequence: 2, action: "state"), key: saved.deviceKey)
        #expect(after.ok)
        #expect(remote.isEnabled && remote.isPaired)
        #expect(remote.status == "Phone connected")
        #expect(store.saved == saved && store.saves == 0 && store.clears == 0)
    }

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

    @Test @MainActor func copiedPairingLinkIsConcealedFromClipboardHistory() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sigil-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let link = try #require(URL(string: "https://example.com/#room=abc&key=def"))
        #expect(RemoteControlView.copy(link, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == link.absoluteString)
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
    }

    @Test @MainActor func disconnectStopsAnotherCopyUsingTheSamePairing() async throws {
        let origin = "http://127.0.0.1:9"
        let store = InMemoryRemotePairingStore()
        store.save(RemotePairing(origin: origin, deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey()))
        let center = NotificationCenter()
        let model = AppModel()
        let installed = RemoteControl(store: store, notifications: center)
        let other = RemoteControl(store: store, notifications: center)
        defer { other.stop() }
        installed.resumeIfPaired(model: model)
        other.resumeIfPaired(model: model)
        #expect(other.isPaired)
        installed.stop(revoke: true)
        for _ in 0..<50 where other.isEnabled {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!other.isEnabled)
        #expect(!installed.revokeFailed)
    }

    @Test @MainActor func aRevokeNoticeIsIgnoredWhileThePairingIsStillSaved() async throws {
        let store = InMemoryRemotePairingStore()
        store.save(
            RemotePairing(
                origin: "http://127.0.0.1:9", deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey()))
        let center = NotificationCenter()
        let remote = RemoteControl(store: store, notifications: center)
        defer { remote.stop() }
        remote.resumeIfPaired(model: AppModel())
        center.post(name: RemoteControl.revokedNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(remote.isEnabled)
        #expect(store.load() != nil)
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

    @Test func keychainReportsAStoredPairingItCannotDecode() throws {
        var badKey = RemotePairing(origin: "https://example.com", deviceKey: "short", ticket: RemoteCrypto.randomKey())
        let items: [CFTypeRef?] = [
            nil, "not data" as CFString, Data("{".utf8) as CFData,
            try JSONEncoder().encode(badKey) as CFData,
        ]
        badKey.deviceKey = RemoteCrypto.randomKey()
        badKey.ticket = "short"
        for item in items + [try JSONEncoder().encode(badKey) as CFData] {
            #expect(throws: KeychainRemotePairingStore.ReadError(status: errSecDecode)) {
                try KeychainRemotePairingStore.pairing(status: errSecSuccess, item: item)
            }
        }
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

@MainActor
private final class PairingCancellationFixture {
    let root: URL
    let suite: String
    let store: SessionStore
    let model: AppModel

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sigil-pairing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        suite = "sigil-pairing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.defaultDirectory = root.path
        settings.isTabMessagingEnabled = false
        store = SessionStore(root: root.appendingPathComponent("sessions"))
        model = AppModel(
            settings: settings, store: store, presentError: { _ in }, panel: RightPanel(defaults: defaults),
            pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(), providerInstallations: [:]
        )
    }

    func cleanup() {
        model.remoteControl.stop()
        model.closeAllTabsAndWait()
        store.stop()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class PairingRevokeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private final class PairingCancellationStore: RemotePairingStore {
    private let memory = InMemoryRemotePairingStore()
    var revokeFailed = false
    var readFails = false
    var saveSucceeds = true
    var clearSucceeds = true
    private(set) var loads = 0
    private(set) var saves = 0
    private(set) var clears = 0
    var saved: RemotePairing? { memory.load() }
    init(saved: RemotePairing) { memory.save(saved) }
    func load() throws -> RemotePairing? {
        loads += 1
        if readFails { throw KeychainRemotePairingStore.ReadError(status: errSecAuthFailed) }
        return memory.load()
    }
    func save(_ pairing: RemotePairing) -> Bool {
        saves += 1
        return saveSucceeds && memory.save(pairing)
    }
    func clear() -> Bool {
        clears += 1
        return clearSucceeds && memory.clear()
    }
}

@MainActor
private final class PairingFailureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var arrived = false
    private(set) var returned = false
    func hold() async {
        arrived = true
        await withCheckedContinuation { continuation = $0 }
        returned = true
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func fakePairing(origin: String) -> RemotePairing {
    RemotePairing(origin: origin, deviceKey: RemoteCrypto.randomKey(), ticket: RemoteCrypto.randomKey())
}

@MainActor
private func waitForPairing(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition())
    guard condition() else { throw RemoteError.invalidMessage }
}

private final class FailingClearStore: RemotePairingStore {
    private var pairing: RemotePairing?
    var clearSucceeds = false
    var revokeFailed = false
    init(pairing: RemotePairing) { self.pairing = pairing }
    func load() -> RemotePairing? { pairing }
    @discardableResult func save(_ pairing: RemotePairing) -> Bool {
        self.pairing = pairing
        return true
    }
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
    func save(_: RemotePairing) -> Bool { true }
    func clear() -> Bool { true }
}

private final class UnreadableStore: RemotePairingStore {
    var revokeFailed = false
    func load() throws -> RemotePairing? { throw KeychainRemotePairingStore.ReadError(status: errSecAuthFailed) }
    func save(_: RemotePairing) -> Bool { true }
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
