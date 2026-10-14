import AppKit
import Foundation
import Network
import Security
import SigilKit
import SwiftTerm
import Testing

@testable import SigilApp

@Suite(.serialized)
struct RemoteControlTests {
    @Test(arguments: [false, true], [false, true])
    @MainActor func alertPathSkipsPromptReadsWithoutConsumers(enabled: Bool, suppressAlerts: Bool) async throws {
        let context = try await AlertEvaluationContext()
        defer { context.cleanup() }
        let remote = context.remote
        if !enabled { remote.stop() }
        let gate = AlertEvaluationGate()
        defer { gate.release() }
        remote.beforeAlertEvaluation = { await gate.hold() }
        var reads = 0
        remote.beforeAlertPromptRead = { _ in reads += 1 }
        for _ in 0..<25 {
            remote.noteTab(context.tab, model: context.fixture.model, suppressAlerts: suppressAlerts)
        }
        let scheduled = remote.pendingAlertEvaluationCount
        // Flush any wrongly scheduled work through the deterministic gate;
        // cleanup must not conceal a delayed no-consumer prompt read.
        if scheduled > 0 {
            try await alertEvaluationUntil { gate.arrivals == scheduled }
            gate.release()
            try await alertEvaluationUntil { gate.returned == scheduled }
        }
        #expect(reads == 0, "Twenty-five generated events need no alert-path prompt read without a consumer")
        #expect(scheduled == 0 && remote.pendingAlertEvaluationCount == 0)
    }

    @Test @MainActor func firstEligibleAlertObservationIsSilentAndTheNextTransitionAlerts() async throws {
        let context = try await AlertEvaluationContext()
        defer { context.cleanup() }
        try await context.command("notify", text: context.pushToken)
        try await context.closePhone()
        context.observe(context.tab)
        #expect(context.reads[context.tab.id] == 1)
        #expect(context.remote.pendingPushCount == 0 && context.requests.isEmpty)
        context.tab.noteInterrupted()
        try await context.evaluateChange(context.tab)
        try await alertEvaluationUntil { context.requests.count == 1 }
        #expect(context.reads[context.tab.id] == 2)
        #expect(try context.alerts().map(\.kind) == [.stopped])
    }

    @Test(arguments: [false, true])
    @MainActor func registeringOneConsumerPreservesTheOtherBaseline(addPush: Bool) async throws {
        let context = try await AlertEvaluationContext()
        defer { context.cleanup() }
        if addPush {
            try await context.command("activity", tab: context.tab, text: context.activityToken)
        } else {
            try await context.command("notify", text: context.pushToken)
        }
        context.observe(context.tab)
        if addPush {
            let other = try context.addTab()
            try await context.command("activity", tab: other, text: String(repeating: "ef", count: 40))
            try await context.command("notify", text: context.pushToken)
            try await context.command("activity", tab: other, text: "")
        } else {
            try await context.command("activity", tab: context.tab, text: context.activityToken)
        }
        try await context.closePhone()
        context.tab.noteInterrupted()
        try await context.evaluateChange(context.tab)
        try await alertEvaluationUntil { context.requests.count == 1 }
        if addPush {
            #expect(try context.alerts().isEmpty)
            #expect(context.activityStatuses == ["interrupted"])
        } else {
            #expect(try context.alerts().map(\.kind) == [.stopped])
            #expect(context.activityStatuses.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    @MainActor func refreshingAnUnchangedConsumerKeepsItsBaseline(activity: Bool) async throws {
        let context = try await AlertEvaluationContext()
        defer { context.cleanup() }
        let action = activity ? "activity" : "notify"
        let token = activity ? context.activityToken : context.pushToken
        try await context.command(action, tab: activity ? context.tab : nil, text: token)
        context.observe(context.tab)
        try await context.command(action, tab: activity ? context.tab : nil, text: token)
        try await context.closePhone()
        context.tab.noteInterrupted()
        try await context.evaluateChange(context.tab)
        #expect(context.reads[context.tab.id] == 2)
        if activity {
            #expect(context.remote.pendingPushCount == 1)
        } else {
            try await alertEvaluationUntil { context.requests.count == 1 }
            #expect(try context.alerts().map(\.kind) == [.stopped])
        }
    }

    @Test(arguments: [false, true])
    @MainActor func lastConsumerRemovalCancelsEvaluationWithoutClearingItsReplacement(activity: Bool) async throws {
        let context = try await AlertEvaluationContext()
        defer { context.cleanup() }
        let action = activity ? "activity" : "notify"
        let token = activity ? context.activityToken : context.pushToken
        let target = activity ? context.tab : nil
        try await context.command(action, tab: target, text: token)
        context.observe(context.tab)
        let old = AlertEvaluationGate()
        let replacement = AlertEvaluationGate()
        defer {
            old.release()
            replacement.release()
        }
        context.remote.beforeAlertEvaluation = { await old.hold() }
        context.remote.noteTab(context.tab, model: context.fixture.model)
        try await alertEvaluationUntil { old.arrivals == 1 }
        #expect(context.remote.pendingAlertEvaluationCount == 1)
        try await context.command(action, tab: target, text: "")
        #expect(context.remote.pendingAlertEvaluationCount == 0)
        try await context.command(action, tab: target, text: token)
        context.remote.beforeAlertEvaluation = { await replacement.hold() }
        context.remote.noteTab(context.tab, model: context.fixture.model)
        try await alertEvaluationUntil { replacement.arrivals == 1 }
        #expect(context.reads[context.tab.id] == 2)
        old.release()
        try await alertEvaluationUntil { old.returned == 1 }
        #expect(context.reads[context.tab.id] == 2)
        #expect(context.remote.hasPendingAlertEvaluation(for: context.tab.id))
        replacement.release()
        try await alertEvaluationUntil { replacement.returned == 1 }
        #expect(context.reads[context.tab.id] == 3)
        #expect(context.remote.pendingAlertEvaluationCount == 0)
    }

    @Test @MainActor func removingAlertsRetainsOnlyTheActiveActivityEvaluation() async throws {
        let context = try await AlertEvaluationContext()
        defer { context.cleanup() }
        let other = try context.addTab()
        try await context.command("notify", text: context.pushToken)
        try await context.command("activity", tab: context.tab, text: context.activityToken)
        context.observe(context.tab)
        context.observe(other)
        let gate = AlertEvaluationGate()
        defer { gate.release() }
        context.remote.beforeAlertEvaluation = { await gate.hold() }
        context.remote.noteTab(context.tab, model: context.fixture.model)
        context.remote.noteTab(other, model: context.fixture.model)
        try await alertEvaluationUntil { gate.arrivals == 2 }
        try await context.command("notify", text: "")
        #expect(context.remote.hasPendingAlertEvaluation(for: context.tab.id))
        #expect(!context.remote.hasPendingAlertEvaluation(for: other.id))
        try await context.closePhone()
        context.tab.noteInterrupted()
        gate.release()
        try await alertEvaluationUntil { gate.returned == 2 }
        #expect(context.reads[context.tab.id] == 2 && context.reads[other.id] == 1)
        #expect(context.remote.pendingPushCount == 1)
        #expect(context.remote.pendingAlertEvaluationCount == 0)
    }

    @Test @MainActor func activityOnlyReadsItsTabAndEndingWorkRetainsTheQueuedEnd() async throws {
        let context = try await AlertEvaluationContext()
        defer { context.cleanup() }
        let other = try context.addTab()
        try await context.command("activity", tab: context.tab, text: context.activityToken)
        for _ in 0..<25 { context.observe(other) }
        #expect(context.reads[other.id] == nil)
        context.observe(context.tab)
        try await context.closePhone()
        context.tab.noteInterrupted()
        try await context.evaluateChange(context.tab)
        #expect(context.reads[context.tab.id] == 2 && context.remote.pendingPushCount == 1)
        let gate = AlertEvaluationGate()
        defer { gate.release() }
        context.remote.beforeAlertEvaluation = { await gate.hold() }
        context.remote.noteTab(context.tab, model: context.fixture.model)
        try await alertEvaluationUntil { gate.arrivals == 1 }
        context.fixture.model.closeTab(context.tab.id)
        context.remote.forgetTab(context.tab.id)
        #expect(context.remote.pendingAlertEvaluationCount == 0 && context.remote.pendingPushCount == 1)
        gate.release()
        try await alertEvaluationUntil { gate.returned == 1 }
        for _ in 0..<25 { context.observe(context.tab) }
        #expect(context.reads[context.tab.id] == 2)
        #expect(context.remote.pendingPushCount == 1)
    }

    @Test @MainActor func selectedWatchStreamsWithoutAnyAlertConsumer() async throws {
        let context = try await AlertEvaluationContext(useModelRemote: true)
        defer { context.cleanup() }
        try await context.command("watch")
        let view = try #require(context.tab.controller.view as? LocalProcessTerminalView)
        view.feed(text: "REA_1217_SELECTED_WATCH")
        context.tab.controller.onRemoteOutput?()
        await context.remote.changesSent()
        let pair = try #require(context.pair)
        let phone = try #require(context.phone)
        let event: RemoteReply = try RemoteCrypto.open(
            try #require(try await phone.receive()["data"]), key: pair.device, direction: "mac")
        #expect(event.event == true && event.state?.terminal.contains("REA_1217_SELECTED_WATCH") == true)
        #expect(context.reads.isEmpty && context.remote.pendingAlertEvaluationCount == 0)
    }

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

    @Test @MainActor func cancelKeepsARetiredOriginsSavedPairing() throws {
        let fixture = try PairingCancellationFixture()
        defer { fixture.cleanup() }
        for origin in [RemoteControl.legacyRailwayOrigin, RemoteControl.legacyApexOrigin] {
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
private final class AlertEvaluationContext {
    let relay: RelayFixture
    let fixture: PhoneCommandFixture
    let tab: TerminalTab
    let remote: RemoteControl
    let pushToken = String(repeating: "ab", count: 32)
    let activityToken = String(repeating: "cd", count: 40)
    var pair: PairedPhone?
    var phone: RelayPhone?
    var reads: [TerminalTab.ID: Int] = [:]
    private var challenge = ""
    private var sequence = 2

    init(useModelRemote: Bool = false) async throws {
        relay = try await RelayFixture(captureAPNs: true)
        fixture = try PhoneCommandFixture()
        tab = try #require(fixture.model.newTab(in: fixture.directory("alert-consumers")))
        remote = useModelRemote ? fixture.model.remoteControl : RemoteControl(store: InMemoryRemotePairingStore())
        remote.start(urlText: relay.origin, model: fixture.model)
        let paired = try await relay.pair(remote)
        pair = paired
        phone = paired.phone
        challenge = paired.challenge
        remote.beforeAlertPromptRead = { [weak self] id in
            guard let self else { return }
            self.reads[id, default: 0] += 1
        }
    }

    func addTab() throws -> TerminalTab {
        try #require(fixture.model.newTab(in: fixture.directory("alert-other-\(UUID().uuidString)")))
    }

    func command(_ action: String, tab: TerminalTab? = nil, text: String? = nil) async throws {
        let phone = try #require(phone)
        let pair = try #require(pair)
        let reply = try await phone.request(
            RemoteRequest(
                challenge: challenge, sequence: sequence, action: action, tabID: tab?.id.uuidString,
                text: text, name: action == "notify" ? "development" : nil), key: pair.device)
        sequence += 1
        try #require(reply.ok)
    }

    func closePhone() async throws {
        phone?.close()
        phone = nil
        try await alertEvaluationUntil { remote.status == "Phone disconnected" }
    }

    func observe(_ tab: TerminalTab) {
        remote.noteTab(tab, model: fixture.model, suppressAlerts: true)
    }

    func evaluateChange(_ tab: TerminalTab) async throws {
        let gate = AlertEvaluationGate()
        defer { gate.release() }
        remote.beforeAlertEvaluation = { await gate.hold() }
        remote.noteTab(tab, model: fixture.model)
        try await alertEvaluationUntil { gate.arrivals == 1 }
        gate.release()
        try await alertEvaluationUntil { gate.returned == 1 && !remote.hasPendingAlertEvaluation(for: tab.id) }
        remote.beforeAlertEvaluation = nil
    }

    var requests: [[String: Any]] {
        guard let text = try? String(contentsOf: relay.apnsCapture, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    var activityStatuses: [String] {
        requests.filter { $0["pushType"] as? String == "liveactivity" }.compactMap {
            let payload = $0["payload"] as? [String: Any]
            let aps = payload?["aps"] as? [String: Any]
            let state = aps?["content-state"] as? [String: Any]
            return state?["status"] as? String
        }
    }

    func alerts() throws -> [RemoteAlert] {
        let pair = try #require(pair)
        return try requests.filter { $0["pushType"] as? String == "alert" }.map {
            let payload = $0["payload"] as? [String: Any]
            let sigil = payload?["sigil"] as? [String: Any]
            return try RemoteCrypto.open(
                try #require(sigil?["data"] as? String), key: pair.device, direction: RemoteAlert.direction)
        }
    }

    func cleanup() {
        remote.beforeAlertEvaluation = nil
        remote.beforeAlertPromptRead = nil
        phone?.close()
        pair?.phone.close()
        remote.stop()
        fixture.cleanup()
        relay.stop()
    }
}

@MainActor
private final class AlertEvaluationGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    private(set) var returned = 0

    func hold() async {
        arrivals += 1
        await withCheckedContinuation { waiting.append($0) }
        returned += 1
    }

    func release() {
        let continuations = waiting
        waiting.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

@MainActor
private func alertEvaluationUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(predicate())
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
