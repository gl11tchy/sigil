import XCTest
import SwiftUI
@testable import Sigil

/// Hosted by the real app in an isolated simulator. The host is a protocol fixture;
/// encryption, transport, relay and the app's connection implementation are real.
@MainActor
final class NativeFlowTests: XCTestCase {
    private var relayPort: String {
        get throws {
            let value = ProcessInfo.processInfo.environment["SIGIL_RELAY_PORT"] ?? ""
            return try XCTUnwrap(Int(value).map(String.init), "Run scripts/native-test.sh to start the real relay.")
        }
    }

    func testNativePairingReconnectInputAndError() async throws {
        try await RelayTests.pairsAndReconnectsByTicket(port: relayPort)
    }

    func testLostPairAcknowledgementRequiresNewCode() async throws {
        try await RelayTests.lostPairingReplyAsksForANewCode(port: relayPort)
    }

    func testEventReplayCannotReplaceOutput() async throws {
        try await RelayTests.rejectsReplayedEvents(port: relayPort)
        try await RelayTests.oldHelloAndOldStateCannotAuthorizeReconnect(port: relayPort)
        try await RelayTests.oldSendFailureCannotConsumeNewHandshake(port: relayPort)
        try await RelayTests.oldAuthorizationCannotConnectNewEpoch(port: relayPort)
    }

    func testMalformedReplyDoesNotHangCommand() async throws {
        try await RelayTests.malformedReplyFailsThePendingRequest(port: relayPort)
    }

    func testNotificationForUnknownMacCannotOpenCurrentMac() {
        let store = RemoteStore(isDemo: true)
        let original = store.selectedTabID
        store.open(tabID: "demo-2", macID: "forgotten-mac")
        XCTAssertEqual(store.selectedTabID, original)
        XCTAssertEqual(store.errorMessage, "Pair this Mac again before opening its session.")
    }

    func testReconnectCannotMoveDraftToUnrelatedConversation() throws {
        let store = RemoteStore(isDemo: true)
        let connection = RemoteConnection()
        store.draft = "private draft for the original conversation"
        store.connection(connection, didChange: .connecting)
        let payload = #"{"challenge":"test","sequence":1,"state":{"tabs":[{"id":"unrelated","title":"Another conversation","status":"unknown"}],"selectedTabID":"unrelated","terminal":""}}"#
        let reply = try JSONDecoder().decode(RemoteReply.self, from: Data(payload.utf8))
        store.connection(connection, didReceive: reply, for: "state", tabID: nil)
        XCTAssertEqual(store.draft, "", "A newly selected tab is not proof of conversation identity")
    }

    func testReconnectPreservesDraftOnlyForExactNativeIdentity() throws {
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false)
        let connection = RemoteConnection()
        func state(_ id: String, cwd: String) throws -> RemoteReply {
            let object: [String: Any] = ["challenge": "test", "sequence": 1, "state": [
                "tabs": [["id": id, "title": "Work", "status": "unknown", "provider": "codex", "sessionID": "native-123", "cwd": cwd]],
                "selectedTabID": id, "terminal": ""]]
            return try JSONDecoder().decode(RemoteReply.self, from: JSONSerialization.data(withJSONObject: object))
        }
        store.connection(connection, didReceive: try state("old-tab", cwd: "/project"), for: "state", tabID: nil)
        store.draft = "unsent work"
        store.connection(connection, didChange: .connecting)
        store.connection(connection, didReceive: try state("new-tab", cwd: "/project"), for: "state", tabID: nil)
        XCTAssertEqual(store.draft, "unsent work")
        store.connection(connection, didChange: .connecting)
        store.connection(connection, didReceive: try state("different-project", cwd: "/other"), for: "state", tabID: nil)
        XCTAssertEqual(store.draft, "")
    }

    func testCappedRestartMovesDraftOnlyWithExactNativeReference() throws {
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false)
        let connection = RemoteConnection()
        let first = #"{"challenge":"test","sequence":1,"state":{"tabs":[{"id":"old","title":"Work","status":"exited","provider":"codex","sessionID":"native","cwd":"/project"}],"selectedTabID":"old","terminal":""}}"#
        store.connection(connection, didReceive: try JSONDecoder().decode(RemoteReply.self, from: Data(first.utf8)), for: "state", tabID: nil)
        store.draft = "saved draft"
        let file = Attachment(name: "remove-me.txt", data: Data("synthetic".utf8), preview: nil)
        XCTAssertNil(store.attach([file]))
        let sameID = first.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":2,\"restartedTabID\":\"old\"")
        store.connection(connection, didReceive: try JSONDecoder().decode(RemoteReply.self, from: Data(sameID.utf8)), for: "restart", tabID: "old")
        XCTAssertEqual(store.draft, "saved draft", "A same-ID receipt cannot retire its own unsent work")
        XCTAssertEqual(store.selectedAttachments, [file])
        let restarted = #"{"challenge":"test","sequence":2,"restartedTabID":"replacement","restartedSession":{"provider":"codex","sessionID":"native","cwd":"/project"},"state":{"tabs":[],"tabsTruncated":true,"terminal":""}}"#
        store.connection(connection, didReceive: try JSONDecoder().decode(RemoteReply.self, from: Data(restarted.utf8)), for: "restart", tabID: "old")
        XCTAssertEqual(store.drafts["replacement"], "saved draft")
        XCTAssertNil(store.drafts["old"])
        XCTAssertNil(store.attachments["old"], "An accepted restart retires the old attachment bucket")
        XCTAssertEqual(store.attachments["replacement"], [file])
        let selected = #"{"challenge":"test","sequence":3,"state":{"tabs":[{"id":"replacement","title":"Work","status":"idle","provider":"codex","sessionID":"native","cwd":"/project"}],"selectedTabID":"replacement","tabsTruncated":true,"terminal":""}}"#
        store.connection(connection, didReceive: try JSONDecoder().decode(RemoteReply.self, from: Data(selected.utf8)), for: "state", tabID: nil)
        store.removeAttachment(file)
        XCTAssertTrue(store.selectedAttachments.isEmpty)
        store.connection(connection, didChange: .connecting)
        let afterReconnect = selected.replacingOccurrences(of: "replacement", with: "next-tab").replacingOccurrences(of: "\"tabsTruncated\":true", with: "\"tabsTruncated\":false")
        store.connection(connection, didReceive: try JSONDecoder().decode(RemoteReply.self, from: Data(afterReconnect.utf8)), for: "state", tabID: nil)
        XCTAssertEqual(store.draft, "saved draft")
        XCTAssertTrue(store.selectedAttachments.isEmpty, "An obsolete reference cannot restore a removed attachment")
    }

    func testCappedRestartWithoutMatchingIdentityRetainsUnsentWork() throws {
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false)
        let connection = RemoteConnection()
        let first = #"{"challenge":"test","sequence":1,"state":{"tabs":[{"id":"old","title":"Work","status":"exited","provider":"codex","sessionID":"native","cwd":"/project"}],"selectedTabID":"old","terminal":""}}"#
        store.connection(connection, didReceive: try JSONDecoder().decode(RemoteReply.self, from: Data(first.utf8)), for: "state", tabID: nil)
        store.draft = "do not discard"
        let file = Attachment(name: "keep-me.txt", data: Data("synthetic".utf8), preview: nil)
        XCTAssertNil(store.attach([file]))
        let mismatch = #"{"challenge":"test","sequence":2,"restartedTabID":"replacement","restartedSession":{"provider":"codex","sessionID":"other-session","cwd":"/project"},"state":{"tabs":[],"tabsTruncated":true,"terminal":""}}"#
        store.connection(connection, didReceive: try JSONDecoder().decode(RemoteReply.self, from: Data(mismatch.utf8)), for: "restart", tabID: "old")
        XCTAssertEqual(store.drafts["old"], "do not discard")
        XCTAssertEqual(store.attachments["old"], [file])
        XCTAssertNil(store.drafts["replacement"])
        XCTAssertNil(store.attachments["replacement"])
    }

    func testRestartEventBeforeReceiptPreservesOldAndNewUnsentWork() async throws {
        for capped in [false, true] {
            let mac = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
            mac.firstTab = .init(id: "T1", title: "Work", status: "exited", provider: "codex", sessionID: "native", cwd: "/project")
            mac.pauseRestart = true
            mac.truncatedTabs = capped
            let room = try await mac.register()
            let store = RemoteStore(isDemo: false, restoreSavedPairings: false)
            defer {
                store.enterBackground(); mac.stop()
                for credential in store.macs { CredentialStore.delete(id: credential.id); ScreenCache.delete(for: credential) }
            }
            XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room)&key=\(mac.pairingKey)"))
            try await RelayTests.until("restart fixture paired") { store.isConnected && store.selectedTabID == "T1" }
            store.draft = "before restart"
            let oldFile = Attachment(name: "before.txt", data: Data("before".utf8), preview: nil)
            let newFile = Attachment(name: "after.txt", data: Data("after".utf8), preview: nil)
            XCTAssertNil(store.attach([oldFile]))
            store.restart()
            try await RelayTests.until("replacement event before receipt") { store.selectedTabID == "T1-restarted" }
            store.draft = "typed while restarting"
            XCTAssertNil(store.attach([newFile, oldFile]))
            try await mac.releaseRestart()
            try await RelayTests.until("restart receipt applied") { !store.busy }
            XCTAssertEqual(store.draft, "before restart\n\ntyped while restarting", "Both drafts survive a \(capped ? "capped" : "complete") event before the acknowledgement")
            XCTAssertEqual(store.selectedAttachments, [oldFile, newFile])
            XCTAssertNil(store.drafts["T1"])
            XCTAssertNil(store.attachments["T1"])
        }
    }

    func testDraftsStayWithTheirPairedMac() async throws {
        let first = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
        let second = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
        let room1 = try await first.register()
        let room2 = try await second.register()
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false)
        defer { store.enterBackground(); first.stop(); second.stop() }
        XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room1)&key=\(first.pairingKey)"))
        try await RelayTests.until("first Mac") { store.isConnected && store.activeMacID != nil }
        let firstID = try XCTUnwrap(store.activeMacID)
        store.draft = "first Mac draft"
        XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room2)&key=\(second.pairingKey)"))
        try await RelayTests.until("second Mac") { store.isConnected && store.activeMacID != nil && store.activeMacID != firstID }
        XCTAssertEqual(store.draft, "", "Identical tab IDs from two Macs do not share drafts")
        store.draft = "second Mac draft"
        XCTAssertEqual(store.macs.count, 2, "A Keychain write failure must not discard an existing in-memory pairing")
        store.switchTo(macID: firstID)
        do {
            try await RelayTests.until("first Mac again") { store.isConnected && store.activeMacID == firstID }
        } catch {
            throw TestFailure("Switch failed: phase=\(store.phase), pairings=\(store.macs.count), hostConnections=\(first.connections), error=\(store.errorMessage ?? "none")")
        }
        XCTAssertEqual(store.draft, "first Mac draft")
        for credential in store.macs { CredentialStore.delete(id: credential.id); ScreenCache.delete(for: credential) }
    }

    func testLiveReconnectBeforeCacheRetainsExactConversationDraftAndAttachments() async throws {
        let first = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
        let second = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
        first.firstTab = .init(id: "T1", title: "Work", status: "idle", provider: "codex", sessionID: "native-session", cwd: "/project")
        let room1 = try await first.register()
        let room2 = try await second.register()
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false)
        defer {
            store.enterBackground(); first.stop(); second.stop()
            for credential in store.macs { CredentialStore.delete(id: credential.id); ScreenCache.delete(for: credential) }
        }
        XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room1)&key=\(first.pairingKey)"))
        try await RelayTests.until("first Mac paired") { store.isConnected && store.activeMacID != nil }
        let firstID = try XCTUnwrap(store.activeMacID)
        let credential = try XCTUnwrap(store.macs.first { $0.id == firstID })
        store.draft = "keep this conversation's draft"
        let file = Attachment(name: "fixture.txt", data: Data("synthetic attachment".utf8), preview: nil)
        XCTAssertNil(store.attach([file]))
        try await first.pushEvent(rows: ["cached before restart"])
        try await RelayTests.until("original output") { store.output.contains("cached before restart") }
        XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room2)&key=\(second.pairingKey)"))
        try await RelayTests.until("second Mac paired") { store.isConnected && store.activeMacID != nil && store.activeMacID != firstID }
        store.draft = "second Mac stays separate"
        let oldCache: CachedScreen? = await withCheckedContinuation { continuation in
            ScreenCache.read(for: credential) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(oldCache?.selectedTabID, "T1")
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        ScreenCache.writer.queue.async { held.signal(); release.wait() }
        XCTAssertEqual(held.wait(timeout: .now() + 2), .success)
        defer { release.signal() }
        first.firstTab = .init(id: "replacement", title: "Renamed", status: "idle", provider: "codex", sessionID: "native-session", cwd: "/project")
        store.switchTo(macID: firstID)
        try await RelayTests.until("live state before cache") { store.isConnected && store.selectedTabID == "replacement" }
        XCTAssertEqual(store.draft, "keep this conversation's draft")
        XCTAssertEqual(store.selectedAttachments, [file])
        XCTAssertNil(store.drafts["T1"])
        try await first.pushEvent(rows: ["live after restart"])
        try await RelayTests.until("new live output") { store.output.contains("live after restart") }
        release.signal()
        // Drain the disk read, then let its off-main renderer return to the store.
        await withCheckedContinuation { continuation in
            ScreenCache.writer.queue.async { continuation.resume() }
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.selectedTabID, "replacement")
        XCTAssertTrue(store.output.contains("live after restart"), "A late cache cannot replace authenticated live output")
        XCTAssertFalse(store.output.contains("cached before restart"))
        XCTAssertNil(store.cachedAt)
        XCTAssertEqual(store.draft, "keep this conversation's draft")
        XCTAssertEqual(store.selectedAttachments, [file])
    }

    func testLegacyAndMalformedEventsFailClosed() async throws {
        try await RelayTests.legacyEventsCannotReplaceOutput(port: relayPort)
        try await RelayTests.missingEventCounterFailsClosed(port: relayPort)
    }

    func testLateSendCompletionCannotClearAnotherMacDraft() async throws {
        let first = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
        let second = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
        let room1 = try await first.register()
        let room2 = try await second.register()
        let connection = RemoteConnection()
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false, connection: connection)
        let delegate = SwitchingDelegate(store: store)
        connection.delegate = delegate
        defer { store.enterBackground(); first.stop(); second.stop() }
        XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room1)&key=\(first.pairingKey)"))
        try await RelayTests.until("first Mac paired") { store.isConnected && store.activeMacID != nil }
        let firstID = try XCTUnwrap(store.activeMacID)
        store.draft = "same draft"
        XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room2)&key=\(second.pairingKey)"))
        try await RelayTests.until("second Mac paired") { store.isConnected && store.activeMacID != nil && store.activeMacID != firstID }
        let secondID = try XCTUnwrap(store.activeMacID)
        store.draft = "same draft"
        store.switchTo(macID: firstID)
        try await RelayTests.until("first Mac selected") { store.isConnected && store.activeMacID == firstID }
        // A real Enter acknowledgement arrives; switch Macs before the suspended
        // sender resumes. Both Macs intentionally use the same tab ID and text.
        delegate.switchOnKey = secondID
        store.sendDraft()
        try await RelayTests.until("completion after switch") { !store.busy && store.isConnected && store.activeMacID == secondID }
        XCTAssertEqual(store.draft, "same draft", "Old success cannot clear the current Mac's draft")
        for credential in store.macs { CredentialStore.delete(id: credential.id); ScreenCache.delete(for: credential) }
    }

    func testSendDoesNotSubmitAfterConnectionEpochChanges() async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
        mac.rotateAfterInput = true
        let room = try await mac.register()
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false)
        defer { store.forget(); mac.stop() }
        XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room)&key=\(mac.pairingKey)"))
        try await RelayTests.until("paired") { store.isConnected && store.selectedTabID == "T1" }
        store.draft = "do not submit after reconnect"
        store.sendDraft()
        try await RelayTests.until("send finished") { !store.busy }
        XCTAssertEqual(mac.requests.filter { $0.action == "input" }.count, 1)
        XCTAssertFalse(mac.requests.contains { $0.action == "key" && $0.text == "enter" }, "A new connection cannot finish the old multi-step command")
        XCTAssertFalse(store.draft.isEmpty, "Uncertain submission retains the draft")
    }

    func testBackgroundFinishesThreePhotoSendBeforeClosing() async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
        let room = try await mac.register()
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false)
        defer {
            store.enterBackground(); mac.stop()
            for credential in store.macs { CredentialStore.delete(id: credential.id); ScreenCache.delete(for: credential) }
        }
        XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room)&key=\(mac.pairingKey)"))
        try await RelayTests.until("background send fixture paired") { store.isConnected && store.selectedTabID == "T1" }
        let photos = (1...3).map {
            Attachment(name: "photo-\($0).jpg", data: Data(repeating: UInt8($0), count: RemoteFile.chunkBytes + 7), preview: nil)
        }
        store.draft = "Three synthetic photos"
        XCTAssertNil(store.attach(photos))
        store.sendDraft()
        store.enterBackground()
        try await RelayTests.until("background send settled") { !store.busy }
        let dispatched = mac.requests.filter { $0.action == "file" || $0.action == "input" || $0.action == "key" }
        let chunks = dispatched.filter { $0.action == "file" }
        print("REA-1198 background fixture: actions=\(dispatched.map(\.action)), draftRetained=\(!store.draft.isEmpty), connected=\(store.isConnected)")
        XCTAssertEqual(dispatched.map(\.action), Array(repeating: "file", count: 6) + ["input", "key"])
        XCTAssertEqual(chunks.compactMap(\.index), [0, 1, 0, 1, 0, 1])
        XCTAssertEqual(chunks.compactMap(\.count), Array(repeating: 2, count: 6))
        XCTAssertEqual(Set(chunks.compactMap(\.transfer)).count, 3)
        XCTAssertEqual(dispatched.first { $0.action == "input" }?.text, " Three synthetic photos")
        XCTAssertEqual(dispatched.last?.text, "enter")
        XCTAssertEqual(store.draft, "")
        XCTAssertTrue(store.selectedAttachments.isEmpty)
        XCTAssertFalse(store.isConnected, "The background connection closes after the send settles")
    }

    func testNativeStorePairSelectSendTerminalControlsAndReconnect() async throws {
        let mac = FakeMac(origin: URL(string: "http://localhost:\(try relayPort)")!)
        mac.presentTerminalMenu = true
        let room = try await mac.register()
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false)
        defer { store.forget(); mac.stop() }
        XCTAssertNil(store.pair(with: "http://localhost:\(try relayPort)/#room=\(room)&key=\(mac.pairingKey)"))
        try await RelayTests.until("native store paired") { store.isConnected && store.tabs.count == 2 }
        let second = try XCTUnwrap(store.tabs.first { $0.id == "T2" })
        store.select(second)
        try await RelayTests.until("selected exact session") { store.selectedTabID == "T2" && !store.busy }
        store.draft = "native test message"
        store.sendDraft()
        try await RelayTests.until("sent draft and Enter") {
            !store.busy && mac.requests.contains { $0.action == "key" && $0.text == "enter" }
        }
        XCTAssertEqual(mac.requests.filter { $0.action == "input" && $0.text == "native test message" }.map(\.tabID), ["T2"])
        store.answer("1")
        try await RelayTests.until("raw terminal choice dispatched") { !store.busy && mac.requests.contains { $0.action == "key" && $0.text == "1" } }
        XCTAssertFalse(mac.requests.contains { $0.action == "answer" }, "Unverified output must never use structured approval")
        XCTAssertFalse(mac.requests.contains { $0.action == "key" && $0.text == "yes" }, "No invented affirmative shortcut")
        try await mac.retireAndReRegister()
        try await RelayTests.until("native store reconnected") { mac.connections >= 2 && store.isConnected }
        XCTAssertEqual(mac.requests.filter { $0.action == "input" && $0.text == "native test message" }.count, 1, "Reconnect does not retry work")
        store.select(RemoteTab(id: "missing", title: "Closed", status: .exited))
        try await RelayTests.until("native error shown") { store.errorMessage == "This tab is closed." }
    }

    func testNativeProtocolAndOutput() throws {
        try ProtocolTests.alertsRejectExpiredAndLegacyPayloads()
        try ProtocolTests.alertReceiptsRejectDuplicatesAndStayBounded()
        try ProtocolTests.selectionMenuHasNoInventedApproval()
        try ProtocolTests.cryptoRoundTrip()
        try ProtocolTests.cryptoRejectsWrongDirectionKeyAndTampering()
        try ProtocolTests.pairingLinkTable()
        try ProtocolTests.stateValidation()
        try OutputTests.readableOutputMatchesCompanion()
        try ScreenTests.modelAppliesWindowsAndDiffs()
        try ScreenTests.alertOpensWithTheRightKeyOnly()
    }

    func testComposerKeepsFocusedInputVisibleAtAccessibilitySize() async throws {
        let store = RemoteStore(isDemo: true)
        let controller = UIHostingController(rootView: SessionScreen().environment(store).dynamicTypeSize(.accessibility3))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let field = try XCTUnwrap(descendants(controller.view).first { ($0 as? UITextView)?.isEditable == true || $0 is UITextField })
        XCTAssertTrue(field.becomeFirstResponder(), "The composer can receive keyboard focus")
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()
        let frame = field.convert(field.bounds, to: window)
        let keyboard = controller.view.keyboardLayoutGuide.layoutFrame
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertLessThanOrEqual(frame.maxY, keyboard.minY + 1, "Composer stays above the keyboard")
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in window.layer.render(in: context.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Native composer at accessibility size"
        attachment.lifetime = .keepAlways
        add(attachment)
        field.resignFirstResponder()
        window.isHidden = true
    }
}

@MainActor
private final class SwitchingDelegate: RemoteConnectionDelegate {
    let store: RemoteStore
    var switchOnKey: String?
    init(store: RemoteStore) { self.store = store }
    func connection(_ connection: RemoteConnection, didChange phase: RemoteConnection.Phase) {
        store.connection(connection, didChange: phase)
    }
    func connection(_ connection: RemoteConnection, didReceive reply: RemoteReply, for action: String, tabID: String?) {
        store.connection(connection, didReceive: reply, for: action, tabID: tabID)
        if action == "key", let target = switchOnKey {
            switchOnKey = nil
            store.switchTo(macID: target)
        }
    }
    func connection(_ connection: RemoteConnection, didReceiveEvent reply: RemoteReply) { store.connection(connection, didReceiveEvent: reply) }
    func connection(_ connection: RemoteConnection, didSave credential: PairingCredential) { store.connection(connection, didSave: credential) }
    func connection(_ connection: RemoteConnection, didFail message: String) { store.connection(connection, didFail: message) }
}
