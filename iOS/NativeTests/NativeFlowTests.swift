import XCTest
import SwiftUI
@testable import Sigil

/// Hosted by the real app in an isolated simulator. The host is a protocol fixture;
/// encryption, transport, relay and the app's connection implementation are real.
@MainActor
final class NativeFlowTests: XCTestCase {
    private static var nextRelay = 0
    private var assignedRelay: String?
    private var relayPort: String {
        get throws {
            if let assignedRelay { return assignedRelay }
            let environment = ProcessInfo.processInfo.environment
            let values = (environment["SIGIL_RELAY_PORTS"] ?? environment["SIGIL_RELAY_PORT"] ?? "").split(separator: ",")
            let ports = values.compactMap { value -> String? in
                guard let port = Int(value), (1...65535).contains(port) else { return nil }
                return String(port)
            }
            guard !ports.isEmpty, ports.count == values.count else {
                throw TestFailure("Run scripts/native-test.sh to start the real relay.")
            }
            let port = ports[Self.nextRelay % ports.count]
            Self.nextRelay += 1
            assignedRelay = port
            return port
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

    func testBusyTerminalKeysCannotInterleaveWithMultipartSend() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseFile = true
        fixture.store.draft = "Generated busy-key regression"
        XCTAssertNil(fixture.store.attach(Array(syntheticPhotos().prefix(1))))
        fixture.store.sendDraft()
        try await RelayTests.until("first file chunk held") {
            fixture.store.busy && fixture.mac.requests.filter { $0.action == "file" }.count == 1
        }
        for key in [RemoteKey.escape, .tab, .up, .down, .left, .right, .backspace, .enter] {
            fixture.store.send(key: key)
        }
        try await Task.sleep(for: .milliseconds(100))
        try await fixture.mac.releaseFile()
        try await RelayTests.until("multipart send completed") { !fixture.store.busy && fixture.inputCount == 1 }
        let dispatch = fixture.mac.requests.filter { ["file", "input", "key"].contains($0.action) }
        let keys = dispatch.filter { $0.action == "key" }.compactMap(\.text)
        print("REA-1199 busy-key baseline: actions=\(dispatch.map(\.action)), keys=\(keys)")
        XCTAssertEqual(dispatch.map(\.action), ["file", "file", "input", "key"])
        XCTAssertEqual(keys, [RemoteKey.enter.rawValue])
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertEqual(fixture.budget.ended, [0])
        let previousKeys = keys.count
        let ordinary = [RemoteKey.escape, .tab, .up, .down, .left, .right, .backspace, .enter]
        for key in ordinary { fixture.store.send(key: key) }
        try await RelayTests.until("ordinary keys available after Send") {
            fixture.mac.requests.filter { $0.action == "key" }.count == previousKeys + ordinary.count
        }
        _ = try await fixture.connection.request("state")
        let recovered = fixture.mac.requests.filter { $0.action == "key" }.dropFirst(previousKeys).compactMap(\.text)
        XCTAssertEqual(recovered.sorted(), ordinary.map(\.rawValue).sorted())
    }

    func testStopCancelsRemainingMultipartSend() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseFile = true
        fixture.store.draft = "Generated multipart Stop regression"
        XCTAssertNil(fixture.store.attach(Array(syntheticPhotos().prefix(1))))
        fixture.store.sendDraft()
        try await RelayTests.until("first chunk awaiting reply before Stop") {
            fixture.store.busy && fixture.mac.requests.filter { $0.action == "file" }.count == 1
        }
        fixture.store.interrupt()
        try await Task.sleep(for: .milliseconds(100))
        try await fixture.mac.releaseFile()
        try await RelayTests.until("Stop delivered and send settled") {
            !fixture.store.busy
                && fixture.mac.requests.contains { $0.action == "key" && $0.text == RemoteKey.interrupt.rawValue }
        }
        _ = try await fixture.connection.request("state")
        let dispatch = fixture.mac.requests.filter { ["file", "input", "key"].contains($0.action) }
        let keys = dispatch.filter { $0.action == "key" }.compactMap(\.text)
        print("REA-1199 Stop baseline: actions=\(dispatch.map(\.action)), keys=\(keys)")
        XCTAssertEqual(dispatch.map(\.action), ["file", "key"])
        XCTAssertEqual(keys, [RemoteKey.interrupt.rawValue])
        XCTAssertEqual(fixture.inputCount, 0)
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertEqual(fixture.store.draft, "Generated multipart Stop regression")
        XCTAssertEqual(fixture.store.selectedAttachments.count, 1)
        XCTAssertTrue(fixture.store.sendMayBeIncomplete)
        XCTAssertEqual(fixture.budget.ended, [0])
    }

    func testCancelledQueuedEnterNeverDispatches() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseState = true
        let previousReads = fixture.mac.requests.filter { $0.action == "state" }.count
        let blocked = Task { try await fixture.connection.request("state") }
        defer { blocked.cancel() }
        try await RelayTests.until("state request held ahead of Enter") {
            fixture.mac.requests.filter { $0.action == "state" }.count > previousReads
        }
        let enter = Task {
            try await fixture.connection.request("key", text: RemoteKey.enter.rawValue, tabID: "T1")
        }
        defer { enter.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        enter.cancel()
        try await fixture.mac.releaseState()
        _ = try await blocked.value
        switch await enter.result {
        case .success:
            XCTFail("Cancellation must prevent a queued Enter from being transmitted")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        // A cancelled caller could otherwise leave an orphaned queue task.
        _ = try await fixture.connection.request("state")
        print("REA-1199 cancelled-Enter baseline: deliveredEnterCount=\(fixture.enterCount)")
        XCTAssertEqual(fixture.enterCount, 0)
    }

    func testStopWhileInputWaitsRetainsDraftAndRejectsChangedSelection() async throws {
        for changeSelection in [false, true] {
            let fixture = try await backgroundFixture()
            defer { fixture.stop() }
            fixture.mac.pauseInput = true
            fixture.store.draft = "Generated pending input"
            fixture.store.sendDraft()
            try await RelayTests.until("input awaiting acknowledgement") { fixture.inputCount == 1 }
            fixture.store.interrupt()
            try await Task.sleep(for: .milliseconds(100))
            if changeSelection {
                try await fixture.mac.selectOnMac("T2", eventSequence: 1)
                try await RelayTests.until("Mac selected another tab") { fixture.store.selectedTabID == "T2" }
                try await fixture.mac.selectOnMac("T1", eventSequence: 2)
                try await RelayTests.until("Mac returned to the original tab") { fixture.store.selectedTabID == "T1" }
            }
            try await fixture.mac.releaseInput()
            try await RelayTests.until("interrupted input settled") { !fixture.store.busy }
            if !changeSelection {
                try await RelayTests.until("current Stop dispatched") {
                    fixture.mac.requests.contains { $0.action == "key" && $0.text == RemoteKey.interrupt.rawValue }
                }
            }
            _ = try await fixture.connection.request("state")
            XCTAssertEqual(fixture.inputCount, 1)
            XCTAssertEqual(fixture.enterCount, 0)
            XCTAssertEqual(fixture.store.draft, "Generated pending input")
            XCTAssertTrue(fixture.store.sendMayBeIncomplete)
            let interrupts = fixture.mac.requests.filter { $0.action == "key" && $0.text == RemoteKey.interrupt.rawValue }
            XCTAssertEqual(interrupts.count, changeSelection ? 0 : 1)
            XCTAssertEqual(fixture.budget.ended, [0])
        }
    }

    func testStopAtInputAcknowledgementDoesNotPressEnter() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        let delegate = SwitchingDelegate(store: fixture.store)
        fixture.connection.delegate = delegate
        delegate.afterReply = { [weak delegate] action in
            guard action == "input" else { return }
            delegate?.afterReply = nil
            fixture.store.interrupt()
        }
        fixture.store.draft = "Generated Stop in the Enter delay"
        fixture.store.sendDraft()
        try await RelayTests.until("input acknowledged and Stop settled") {
            fixture.inputCount == 1 && !fixture.store.busy
                && fixture.mac.requests.contains { $0.action == "key" && $0.text == RemoteKey.interrupt.rawValue }
        }
        _ = try await fixture.connection.request("state")
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertEqual(fixture.mac.requests.filter { $0.action == "key" }.compactMap(\.text), [RemoteKey.interrupt.rawValue])
        XCTAssertEqual(fixture.store.draft, "Generated Stop in the Enter delay")
        XCTAssertTrue(fixture.store.sendMayBeIncomplete)
        XCTAssertEqual(fixture.budget.ended, [0])
    }

    func testStopAtFileReceiptKeepsNewerWorkAndDoesNotRepeatTheFile() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        let delegate = SwitchingDelegate(store: fixture.store)
        fixture.connection.delegate = delegate
        let newer = Attachment(name: "newer.txt", data: Data("generated".utf8), preview: nil)
        delegate.afterReply = { [weak delegate] action in
            guard action == "file", fixture.mac.requests.filter({ $0.action == "file" }).count == 2 else { return }
            delegate?.afterReply = nil
            fixture.store.draft = "Edited while the photo uploaded"
            XCTAssertNil(fixture.store.attach([newer]))
            fixture.store.interrupt()
        }
        fixture.store.draft = "Original generated caption"
        XCTAssertNil(fixture.store.attach(Array(syntheticPhotos().prefix(1))))
        fixture.store.sendDraft()
        try await RelayTests.until("full file receipt and interrupted continuation settled") {
            fixture.mac.requests.filter { $0.action == "file" }.count == 2 && !fixture.store.busy
                && fixture.mac.requests.contains { $0.action == "key" && $0.text == RemoteKey.interrupt.rawValue }
        }
        _ = try await fixture.connection.request("state")
        XCTAssertEqual(fixture.inputCount, 0)
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertEqual(fixture.mac.requests.filter { $0.action == "key" }.compactMap(\.text), [RemoteKey.interrupt.rawValue])
        XCTAssertEqual(fixture.store.draft, "Edited while the photo uploaded")
        XCTAssertEqual(fixture.store.selectedAttachments.map(\.id), [newer.id])
        XCTAssertTrue(fixture.store.sendMayBeIncomplete)
        XCTAssertEqual(fixture.budget.ended, [0])
    }

    func testStopCancelsEnterQueuedBehindAnotherRequest() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseInput = true
        fixture.mac.pauseState = true
        fixture.store.draft = "Generated Enter held in the queue"
        fixture.store.sendDraft()
        try await RelayTests.until("input held before queueing a state read") { fixture.inputCount == 1 }
        let previousReads = fixture.mac.requests.filter { $0.action == "state" }.count
        let blocked = Task { try await fixture.connection.request("state") }
        defer { blocked.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        try await fixture.mac.releaseInput()
        try await RelayTests.until("state read blocks the Enter stage") {
            fixture.mac.requests.filter { $0.action == "state" }.count > previousReads
        }
        // The send's existing 100ms Enter delay elapses behind the held read.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(fixture.enterCount, 0)
        fixture.store.interrupt()
        try await fixture.mac.releaseState()
        _ = try await blocked.value
        try await RelayTests.until("cancelled queued Enter settled") {
            !fixture.store.busy
                && fixture.mac.requests.contains { $0.action == "key" && $0.text == RemoteKey.interrupt.rawValue }
        }
        _ = try await fixture.connection.request("state")
        XCTAssertEqual(fixture.inputCount, 1)
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertEqual(fixture.mac.requests.filter { $0.action == "key" }.compactMap(\.text), [RemoteKey.interrupt.rawValue])
        XCTAssertEqual(fixture.store.draft, "Generated Enter held in the queue")
        XCTAssertTrue(fixture.store.sendMayBeIncomplete)
        XCTAssertEqual(fixture.budget.ended, [0])
    }

    func testOldQueuedStopCannotInterruptNewBusySend() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseInput = true
        fixture.mac.pauseState = true
        fixture.store.draft = "Old generated send"
        fixture.store.sendDraft()
        try await RelayTests.until("old input held") { fixture.inputCount == 1 }
        let previousReads = fixture.mac.requests.filter { $0.action == "state" }.count
        let blocked = Task { try await fixture.connection.request("state") }
        defer { blocked.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        fixture.store.interrupt()
        try await Task.sleep(for: .milliseconds(100))
        try await fixture.mac.releaseInput()
        try await RelayTests.until("old send released busy while Stop waits behind a read") {
            !fixture.store.busy && fixture.mac.requests.filter { $0.action == "state" }.count > previousReads
        }
        fixture.mac.pauseInput = true
        fixture.store.draft = "New generated send"
        fixture.store.sendDraft()
        try await fixture.mac.releaseState()
        _ = try await blocked.value
        try await RelayTests.until("new input owns busy") { fixture.inputCount == 2 }
        XCTAssertTrue(fixture.store.busy)
        XCTAssertEqual(fixture.store.draft, "New generated send")
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertFalse(fixture.mac.requests.contains { $0.action == "key" && $0.text == RemoteKey.interrupt.rawValue })
        try await fixture.mac.releaseInput()
        try await RelayTests.until("new send completed") { !fixture.store.busy }
        _ = try await fixture.connection.request("state")
        XCTAssertEqual(fixture.enterCount, 1)
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertFalse(fixture.mac.requests.contains { $0.action == "key" && $0.text == RemoteKey.interrupt.rawValue })
        XCTAssertEqual(fixture.budget.ended, [0, 1])
    }

    func testQueuedKeyCannotFollowAChangedSelection() async throws {
        for returnToOriginal in [false, true] {
            let fixture = try await backgroundFixture()
            defer { fixture.stop() }
            fixture.mac.pauseState = true
            let previousReads = fixture.mac.requests.filter { $0.action == "state" }.count
            let blocked = Task { try await fixture.connection.request("state") }
            defer { blocked.cancel() }
            try await RelayTests.until("read held ahead of ordinary key") {
                fixture.mac.requests.filter { $0.action == "state" }.count > previousReads
            }
            fixture.store.send(key: .enter)
            try await Task.sleep(for: .milliseconds(100))
            try await fixture.mac.selectOnMac("T2", eventSequence: 1)
            try await RelayTests.until("new tab selected") { fixture.store.selectedTabID == "T2" }
            if returnToOriginal {
                try await fixture.mac.selectOnMac("T1", eventSequence: 2)
                try await RelayTests.until("original ID selected again") { fixture.store.selectedTabID == "T1" }
            }
            fixture.store.errorMessage = "New selection marker"
            try await fixture.mac.releaseState()
            _ = try await blocked.value
            _ = try await fixture.connection.request("state")
            XCTAssertEqual(fixture.enterCount, 0)
            XCTAssertEqual(fixture.store.errorMessage, "New selection marker")
        }
    }

    func testBusyTerminalControlsRenderDisabledWithStopAvailable() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        let keys = [RemoteKey.escape, .tab, .up, .down, .left, .right, .backspace, .enter]
        let identifiers = keys.map { "key-" + $0.rawValue }
        let modes: [(String, DynamicTypeSize)] = [("regular", .large), ("accessibility", .accessibility3)]
        for (name, size) in modes {
            fixture.mac.pauseFile = true
            let previousFiles = fixture.mac.requests.filter { $0.action == "file" }.count
            fixture.store.draft = "Generated \(name) upload"
            XCTAssertNil(fixture.store.attach(Array(syntheticPhotos().prefix(1))))
            fixture.store.sendDraft()
            try await RelayTests.until("upload held while controls render") {
                fixture.store.busy && fixture.mac.requests.filter { $0.action == "file" }.count > previousFiles
            }
            // The provider is still idle: Stop must be available for the owned send itself.
            XCTAssertEqual(fixture.store.selectedTab?.status, .idle)
            let observed = TerminalControlStates()
            let controller = UIHostingController(rootView:
                SessionScreen(initiallyShowingKeys: true)
                    .environment(fixture.store)
                    .environment(\.terminalControlEnabledObserver, { id, enabled in observed.values[id] = enabled })
                    .dynamicTypeSize(size))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await RelayTests.until("all real controls reported their environment") {
                identifiers.allSatisfy { observed.values[$0] != nil } && observed.values["stop"] != nil
            }
            try await Task.sleep(for: .milliseconds(350))
            controller.view.layoutIfNeeded()
            XCTAssertTrue(fixture.store.busy)
            for id in identifiers { XCTAssertEqual(observed.values[id], false, id) }
            XCTAssertEqual(observed.values["stop"], true)
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { context in window.layer.render(in: context.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "REA-1199 busy terminal controls \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try await fixture.mac.releaseFile()
            try await RelayTests.until("send completed and actual keys re-enabled") {
                !fixture.store.busy && identifiers.allSatisfy { observed.values[$0] == true }
            }
            _ = try await fixture.connection.request("state")
            XCTAssertEqual(fixture.store.draft, "")
            XCTAssertTrue(fixture.store.selectedAttachments.isEmpty)
        }
        XCTAssertEqual(fixture.budget.ended, [0, 1])
    }

    func testBackgroundFinishesThreePhotoSendBeforeClosing() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        let store = fixture.store, mac = fixture.mac
        let photos = syntheticPhotos()
        store.draft = "Three synthetic photos"
        XCTAssertNil(store.attach(photos))
        store.sendDraft()
        store.enterBackground(finishingSend: true)
        try await RelayTests.until("background send settled") { !store.busy }
        let dispatched = mac.requests.filter { $0.action == "file" || $0.action == "input" || $0.action == "key" }
        let chunks = dispatched.filter { $0.action == "file" }
        print("REA-1198 background fixture: actions=\(dispatched.map(\.action)), draftRetained=\(!store.draft.isEmpty), connected=\(store.isConnected)")
        XCTAssertEqual(dispatched.map(\.action), Array(repeating: "file", count: 6) + ["input", "key"])
        XCTAssertEqual(chunks.compactMap(\.index), [0, 1, 0, 1, 0, 1])
        XCTAssertEqual(chunks.compactMap(\.count), Array(repeating: 2, count: 6))
        XCTAssertEqual(Set(chunks.compactMap(\.transfer)).count, 3)
        for photo in photos {
            let parts = chunks.filter { $0.name == photo.name }
            var received = Data()
            for part in parts { received.append(Data(base64Encoded: part.text ?? "") ?? Data()) }
            XCTAssertEqual(received, photo.data)
            XCTAssertEqual(Set(parts.compactMap(\.tabID)), ["T1"])
        }
        XCTAssertEqual(dispatched.first { $0.action == "input" }?.text, " Three synthetic photos")
        XCTAssertEqual(dispatched.last?.text, "enter")
        XCTAssertEqual(store.draft, "")
        XCTAssertTrue(store.selectedAttachments.isEmpty)
        XCTAssertFalse(store.isConnected, "The background connection closes after the send settles")
        XCTAssertEqual(fixture.budget.expirations.count, 1)
        XCTAssertEqual(fixture.budget.ended, [0])
        XCTAssertFalse(store.sendMayBeIncomplete)
    }

    func testBackgroundWithoutSendStopsImmediately() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.store.enterBackground(finishingSend: true)
        XCTAssertEqual(fixture.store.phase, .offline)
        XCTAssertTrue(fixture.budget.expirations.isEmpty)
        XCTAssertFalse(fixture.store.sendMayBeIncomplete)
    }

    func testBackgroundTeardownStopsPendingSendImmediately() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseInput = true
        fixture.store.draft = "Keep this draft"
        fixture.store.sendDraft()
        try await RelayTests.until("teardown input dispatched") { fixture.inputCount == 1 }
        fixture.store.enterBackground()
        XCTAssertEqual(fixture.store.phase, .offline)
        XCTAssertFalse(fixture.store.busy)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertEqual(fixture.store.draft, "Keep this draft")
        XCTAssertEqual(fixture.budget.ended, [0])
    }

    func testBackgroundDeniedTimeRetainsDraftWithoutDispatch() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.budget.granted = false
        fixture.store.draft = "Time was not granted"
        fixture.store.sendDraft()
        fixture.store.enterBackground(finishingSend: true)
        XCTAssertEqual(fixture.store.phase, .offline)
        XCTAssertFalse(fixture.store.busy)
        XCTAssertTrue(fixture.store.sendMayBeIncomplete)
        XCTAssertTrue(fixture.store.errorMessage?.contains("Send may be incomplete") == true)
        XCTAssertEqual(fixture.store.draft, "Time was not granted")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.inputCount, 0)
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertTrue(fixture.budget.ended.isEmpty, "A refused assertion has no end operation")
    }

    func testForegroundSendFinishesWhenBackgroundTimeIsDenied() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.budget.granted = false
        fixture.store.draft = "Still in front"
        fixture.store.sendDraft()
        try await RelayTests.until("foreground send finished") { !fixture.store.busy }
        XCTAssertTrue(fixture.store.isConnected)
        XCTAssertEqual(fixture.inputCount, 1)
        XCTAssertEqual(fixture.enterCount, 1)
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertFalse(fixture.store.sendMayBeIncomplete)
        XCTAssertTrue(fixture.budget.ended.isEmpty)
    }

    func testForegroundExpirationBeforeBeginReturnsKeepsSendUsable() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.budget.expireDuringBegin = true
        fixture.store.draft = "An early expiration is balanced"
        fixture.store.sendDraft()
        try await RelayTests.until("send after early foreground expiration") { !fixture.store.busy }
        XCTAssertTrue(fixture.store.isConnected)
        XCTAssertEqual(fixture.inputCount, 1)
        XCTAssertEqual(fixture.enterCount, 1)
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertFalse(fixture.store.sendMayBeIncomplete)
        XCTAssertEqual(fixture.budget.ended, [0], "Even expiration before begin returns ends the granted assertion once")
    }

    func testBackgroundExpirationRetainsPhotosAndDraftWithoutReplay() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        let photos = syntheticPhotos()
        fixture.mac.pauseFile = true
        fixture.store.draft = "Inspect the terminal before sending again"
        XCTAssertNil(fixture.store.attach(photos))
        fixture.store.sendDraft()
        try await RelayTests.until("first photo chunk pending") { fixture.mac.requests.contains { $0.action == "file" } }
        fixture.store.enterBackground(finishingSend: true)
        fixture.budget.expire(0)
        XCTAssertEqual(fixture.store.phase, .offline)
        XCTAssertFalse(fixture.store.busy)
        XCTAssertTrue(fixture.store.sendMayBeIncomplete)
        XCTAssertEqual(fixture.store.selectedAttachments, photos)
        XCTAssertEqual(fixture.budget.ended, [0])
        fixture.mac.pauseFile = false
        fixture.store.enterForeground()
        try await RelayTests.until("fresh connection after expired send") { fixture.store.isConnected && fixture.mac.connections == 2 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.mac.requests.filter { $0.action == "file" }.count, 1)
        XCTAssertEqual(fixture.inputCount, 0)
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertEqual(fixture.store.draft, "Inspect the terminal before sending again")
        XCTAssertTrue(fixture.store.errorMessage?.contains("Send may be incomplete") == true)
        try await captureSendScreen(fixture.store, named: "REA-1198 expired send retains draft and photos")
    }

    func testForegroundReturnKeepsTheSendAndRejectsOldExpiration() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseInput = true
        fixture.store.draft = "Return during the send"
        fixture.store.sendDraft()
        try await RelayTests.until("input awaiting foreground return") { fixture.inputCount == 1 }
        fixture.store.enterBackground(finishingSend: true)
        XCTAssertTrue(fixture.store.isConnected)
        fixture.store.enterForeground()
        XCTAssertEqual(fixture.budget.expirations.count, 2)
        XCTAssertEqual(fixture.budget.ended, [0])
        fixture.budget.expire(0)
        XCTAssertTrue(fixture.store.isConnected)
        XCTAssertTrue(fixture.store.busy)
        try await fixture.mac.releaseInput()
        try await RelayTests.until("foreground send completed") { !fixture.store.busy }
        XCTAssertTrue(fixture.store.isConnected, "Old completion cannot run a deferred background stop")
        XCTAssertEqual(fixture.mac.connections, 1)
        XCTAssertEqual(fixture.inputCount, 1)
        XCTAssertEqual(fixture.enterCount, 1)
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertEqual(fixture.budget.ended, [0, 1])
    }

    func testOldExpirationCannotStopNewConnectionSend() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseInput = true
        fixture.store.draft = "Original connection"
        fixture.store.sendDraft()
        try await RelayTests.until("original input pending") { fixture.inputCount == 1 }
        fixture.store.reconnect()
        try await RelayTests.until("replacement connection") { fixture.store.isConnected && fixture.mac.connections == 2 }
        fixture.store.draft = "Replacement connection"
        fixture.store.sendDraft()
        try await RelayTests.until("replacement input pending") { fixture.inputCount == 2 }
        fixture.store.enterBackground(finishingSend: true)
        fixture.budget.expire(0)
        XCTAssertTrue(fixture.store.isConnected)
        XCTAssertTrue(fixture.store.busy)
        XCTAssertEqual(fixture.budget.ended, [0])
        try await fixture.mac.releaseInput()
        try await RelayTests.until("replacement send finished") { !fixture.store.busy }
        XCTAssertEqual(fixture.store.phase, .offline)
        XCTAssertEqual(fixture.enterCount, 1, "The old send never adds Enter on the replacement connection")
        XCTAssertEqual(fixture.mac.requests.filter { $0.action == "input" }.compactMap(\.text),
                       ["Original connection", "Replacement connection"])
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertEqual(fixture.budget.ended, [0, 1])
    }

    func testBackgroundConnectionLossDoesNotReconnect() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseInput = true
        fixture.store.draft = "A lost connection is uncertain"
        fixture.store.sendDraft()
        try await RelayTests.until("input before host loss") { fixture.inputCount == 1 }
        fixture.store.enterBackground(finishingSend: true)
        fixture.mac.stop()
        try await RelayTests.until("background connection stopped") { fixture.store.phase == .offline && !fixture.store.busy }
        try await Task.sleep(for: .seconds(1.1))
        XCTAssertEqual(fixture.store.phase, .offline, "Background socket loss must not start reconnecting")
        XCTAssertEqual(fixture.mac.connections, 1)
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertEqual(fixture.store.draft, "A lost connection is uncertain")
        XCTAssertTrue(fixture.store.sendMayBeIncomplete)
        XCTAssertEqual(fixture.budget.ended, [0])
    }

    func testBackgroundRevocationKeepsSendUncertaintyVisible() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseInput = true
        fixture.store.draft = "Retain this interrupted draft"
        fixture.store.sendDraft()
        try await RelayTests.until("input before revocation") { fixture.inputCount == 1 }
        fixture.store.enterBackground(finishingSend: true)
        fixture.mac.revoke()
        try await RelayTests.until("send pairing revoked") { fixture.store.isRevoked && !fixture.store.busy }
        fixture.store.enterForeground()
        fixture.budget.expire(0)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(fixture.store.isRevoked)
        XCTAssertEqual(fixture.mac.connections, 1)
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertTrue(fixture.store.sendMayBeIncomplete)
        XCTAssertTrue(fixture.store.errorMessage?.contains("Send may be incomplete") == true)
        XCTAssertEqual(fixture.store.draft, "Retain this interrupted draft")
        XCTAssertEqual(fixture.budget.ended, [0])
        try await captureSendScreen(fixture.store, named: "REA-1198 revoked pairing keeps send uncertainty")
    }

    func testBackgroundLostRepliesRetainDraftWithoutReplay() async throws {
        for lost in ["input", "Enter"] {
            let fixture = try await backgroundFixture()
            defer { fixture.stop() }
            fixture.mac.pauseInput = lost == "input"
            fixture.mac.pauseEnter = lost == "Enter"
            let expectedEnter = lost == "Enter" ? 1 : 0
            fixture.store.draft = "An \(lost) acknowledgement can be lost"
            fixture.store.sendDraft()
            try await RelayTests.until("unacknowledged \(lost)") {
                fixture.inputCount == 1 && fixture.enterCount == expectedEnter
            }
            fixture.store.enterBackground(finishingSend: true)
            try await RelayTests.until("normal command deadline settles \(lost)", timeout: 14) {
                !fixture.store.busy && fixture.store.phase == .offline
            }
            XCTAssertTrue(fixture.store.sendMayBeIncomplete)
            XCTAssertEqual(fixture.store.draft, "An \(lost) acknowledgement can be lost")
            fixture.mac.pauseInput = false
            fixture.mac.pauseEnter = false
            fixture.store.enterForeground()
            try await RelayTests.until("reconnected after lost \(lost)") { fixture.store.isConnected && fixture.mac.connections == 2 }
            XCTAssertEqual(fixture.inputCount, 1)
            XCTAssertEqual(fixture.enterCount, expectedEnter, "Reconnect cannot replay either stage")
            XCTAssertTrue(fixture.store.errorMessage?.contains("Send may be incomplete") == true)
            fixture.mac.optionsError = "Options could not be loaded."
            _ = await fixture.store.loadSessionOptions()
            XCTAssertTrue(fixture.store.errorMessage?.contains("Send may be incomplete") == true,
                          "An automatic read error cannot hide the uncertain send")
            XCTAssertTrue(fixture.store.errorMessage?.contains("Options could not be loaded.") == true)
            XCTAssertEqual(fixture.budget.ended, [0])
        }
    }

    func testNewDraftRevisionSurvivesOriginalSend() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        fixture.mac.pauseInput = true
        fixture.store.draft = "Same words"
        fixture.store.sendDraft()
        try await RelayTests.until("original draft dispatched") { fixture.inputCount == 1 }
        fixture.store.draft = "Edited while sending"
        fixture.store.draft = "Same words"
        let later = Attachment(name: "later.txt", data: Data("later attachment".utf8), preview: nil)
        XCTAssertNil(fixture.store.attach([later]))
        try await fixture.mac.releaseInput()
        try await RelayTests.until("original draft acknowledged") { !fixture.store.busy }
        XCTAssertEqual(fixture.store.draft, "Same words", "Editing away and back creates a newer draft")
        XCTAssertEqual(fixture.store.selectedAttachments, [later])
        XCTAssertEqual(fixture.inputCount, 1)
        XCTAssertEqual(fixture.enterCount, 1)
        XCTAssertFalse(fixture.store.sendMayBeIncomplete)
    }

    func testOldSendCompletionCannotReleaseNewBusy() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        let delegate = SwitchingDelegate(store: fixture.store)
        fixture.connection.delegate = delegate
        // Deliver lifecycle callbacks at the acknowledgement boundary while the
        // transport remains valid. This isolates task ownership from wire epochs.
        delegate.afterReply = { [weak delegate] action in
            guard action == "key" else { return }
            delegate?.afterReply = nil
            fixture.store.connection(fixture.connection, didChange: .offline)
            fixture.store.connection(fixture.connection, didChange: .connected)
            fixture.mac.pauseInput = true
            fixture.store.draft = "New busy operation"
            fixture.store.sendDraft()
        }
        fixture.store.draft = "Original operation"
        fixture.store.sendDraft()
        try await RelayTests.until("new operation awaiting reply") { fixture.inputCount == 2 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(fixture.store.busy, "The old continuation cannot release the newer operation")
        XCTAssertEqual(fixture.store.draft, "New busy operation")
        try await fixture.mac.releaseInput()
        try await RelayTests.until("new operation completed") { !fixture.store.busy }
        XCTAssertEqual(fixture.enterCount, 2)
        XCTAssertEqual(fixture.store.draft, "")
        XCTAssertEqual(fixture.budget.ended, [0, 1])
    }

    func testBackgroundExpirationAfterInputDoesNotPressEnter() async throws {
        let fixture = try await backgroundFixture()
        defer { fixture.stop() }
        let delegate = SwitchingDelegate(store: fixture.store)
        fixture.connection.delegate = delegate
        delegate.afterReply = { [weak delegate] action in
            guard action == "input" else { return }
            delegate?.afterReply = nil
            fixture.budget.expire(0)
        }
        fixture.store.draft = "Pasted but not submitted"
        fixture.store.sendDraft()
        fixture.store.enterBackground(finishingSend: true)
        try await RelayTests.until("input boundary expired") { fixture.inputCount == 1 && !fixture.store.busy }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.store.phase, .offline)
        XCTAssertEqual(fixture.enterCount, 0)
        XCTAssertEqual(fixture.store.draft, "Pasted but not submitted")
        XCTAssertTrue(fixture.store.sendMayBeIncomplete)
        XCTAssertEqual(fixture.budget.ended, [0])
    }

    private func syntheticPhotos() -> [Attachment] {
        (1...3).map {
            Attachment(name: "photo-\($0).jpg", data: Data(repeating: UInt8($0), count: RemoteFile.chunkBytes + 7), preview: nil)
        }
    }

    private func backgroundFixture() async throws -> BackgroundSendFixture {
        let port = try relayPort
        let mac = FakeMac(origin: URL(string: "http://localhost:\(port)")!)
        let budget = BackgroundTaskFixture()
        let connection = RemoteConnection()
        let store = RemoteStore(isDemo: false, restoreSavedPairings: false, connection: connection, backgroundTask: budget.task)
        let fixture = BackgroundSendFixture(store: store, mac: mac, budget: budget, connection: connection)
        do {
            let room = try await mac.register()
            XCTAssertNil(store.pair(with: "http://localhost:\(port)/#room=\(room)&key=\(mac.pairingKey)"))
            try await RelayTests.until("background send fixture paired") { store.isConnected && store.selectedTabID == "T1" }
            return fixture
        } catch {
            fixture.stop()
            throw error
        }
    }

    private func captureSendScreen(_ store: RemoteStore, named name: String) async throws {
        let controller = UIHostingController(rootView: SessionScreen().environment(store))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(350))
        controller.view.layoutIfNeeded()
        XCTAssertTrue(store.sendMayBeIncomplete)
        XCTAssertTrue(store.errorMessage?.contains("Send may be incomplete") == true,
                      "The warning remains after the screen's automatic reads finish")
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in window.layer.render(in: context.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
private final class TerminalControlStates {
    var values: [String: Bool] = [:]
}

@MainActor
private final class BackgroundTaskFixture {
    var granted = true
    var expireDuringBegin = false
    private(set) var expirations: [@MainActor @Sendable () -> Void] = []
    private(set) var ended: [Int] = []

    var task: SendBackgroundTask {
        SendBackgroundTask { expiration in
            let index = self.expirations.count
            self.expirations.append(expiration)
            if self.expireDuringBegin { expiration() }
            guard self.granted else { return nil }
            return {
                XCTAssertFalse(self.ended.contains(index), "A background assertion ends once")
                self.ended.append(index)
            }
        }
    }

    func expire(_ index: Int) { expirations[index]() }
}

@MainActor
private struct BackgroundSendFixture {
    let store: RemoteStore
    let mac: FakeMac
    let budget: BackgroundTaskFixture
    let connection: RemoteConnection
    var inputCount: Int { mac.requests.filter { $0.action == "input" }.count }
    var enterCount: Int { mac.requests.filter { $0.action == "key" && $0.text == "enter" }.count }

    func stop() {
        store.enterBackground()
        mac.stop()
        for credential in store.macs { CredentialStore.delete(id: credential.id); ScreenCache.delete(for: credential) }
    }
}

@MainActor
private final class SwitchingDelegate: RemoteConnectionDelegate {
    let store: RemoteStore
    var switchOnKey: String?
    var afterReply: ((String) -> Void)?
    init(store: RemoteStore) { self.store = store }
    func connection(_ connection: RemoteConnection, didChange phase: RemoteConnection.Phase) {
        store.connection(connection, didChange: phase)
    }
    func connection(_ connection: RemoteConnection, didReceive reply: RemoteReply, for action: String, tabID: String?) {
        store.connection(connection, didReceive: reply, for: action, tabID: tabID)
        afterReply?(action)
        if action == "key", let target = switchOnKey {
            switchOnKey = nil
            store.switchTo(macID: target)
        }
    }
    func connection(_ connection: RemoteConnection, didReceiveEvent reply: RemoteReply) { store.connection(connection, didReceiveEvent: reply) }
    func connection(_ connection: RemoteConnection, didSave credential: PairingCredential) { store.connection(connection, didSave: credential) }
    func connection(_ connection: RemoteConnection, didFail message: String) { store.connection(connection, didFail: message) }
}
