import Foundation
import SigilKit
import SwiftTerm
import Testing

@testable import SigilApp

@Suite(.serialized)
@MainActor
struct RemoteStreamOrderingTests {
    @Test func rawMenuKeysAreLiteralBytesEvenWhenBracketedPasteIsEnabled() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("raw-choice")
        let received = fixture.root.appendingPathComponent("received-keys")
        let script = """
            #!/bin/sh
            stty raw -echo
            printf '\\033[?2004hREADY'
            dd bs=1 count=7 of='\(received.path)' 2>/dev/null
            sleep 1
            """
        try Data(script.utf8).write(to: fixture.executable)
        let tab = try #require(fixture.model.newTab(in: folder))
        for _ in 0..<200 {
            if tab.controller.remoteSnapshot().contains("READY") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.controller.remoteSnapshot().contains("READY"))
        for key in ["2", "y", "yes", "no"] {
            #expect(await fixture.command("key", text: key, tabID: tab.id.uuidString).ok)
        }
        #expect(await !fixture.command("key", text: "always", tabID: tab.id.uuidString).ok)
        #expect(await !fixture.command("key", text: "10", tabID: tab.id.uuidString).ok)
        for _ in 0..<200 {
            if (try? Data(contentsOf: received).count) == 7 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: received, encoding: .utf8) == "2yyesno")
    }

    @Test func aLegacyPairingGetsAnUpgradeErrorWithoutConsumingTheQRCode() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let store = InMemoryRemotePairingStore()
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: fixture.model)
        for _ in 0..<200 {
            if remote.pairingURL != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let link = try #require(remote.pairingURL)
        var parts = URLComponents()
        parts.query = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.fragment)
        let room = try #require(parts.queryItems?.first { $0.name == "room" }?.value)
        let bootstrap = try #require(parts.queryItems?.first { $0.name == "key" }?.value)
        let phone = try RelayPhone(relay: relay)
        defer { phone.close() }
        let challenge = try await phone.route(["room": room])
        let legacyDevice = RemoteCrypto.randomKey()
        let upgrade = try await phone.request(
            RemoteRequest(challenge: challenge, sequence: 1, action: "pair", text: legacyDevice, clientNonce: nil),
            key: bootstrap, replyKey: legacyDevice)
        #expect(!upgrade.ok)
        #expect(upgrade.error?.contains("Update") == true)
        #expect(store.load() == nil)
        #expect(!remote.isPaired)
        #expect(remote.pairingURL == link)
        // A newly loaded client can use the same QR and sequence, with its own key.
        let newDevice = RemoteCrypto.randomKey()
        let nonce = RemoteCrypto.randomKey()
        let paired = try await phone.request(
            RemoteRequest(challenge: challenge, sequence: 1, action: "pair", text: newDevice, clientNonce: nonce),
            key: bootstrap, replyKey: newDevice)
        #expect(paired.ok)
        #expect(paired.clientNonce == nonce)
        #expect(store.load()?.deviceKey == newDevice)
        let oversized = try await phone.request(
            RemoteRequest(
                challenge: challenge, sequence: 2, action: "input", text: String(repeating: "x", count: 8_193),
                clientNonce: nonce), key: newDevice)
        #expect(!oversized.ok)
        #expect(oversized.clientNonce == nonce)
        #expect(oversized.error?.contains("Too long") == true)
    }

    @Test func revokingWhilePushRegistrationResumesCannotRestoreOldCredentials() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let store = InMemoryRemotePairingStore()
        let remote = RemoteControl(store: store)
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: fixture.model)
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }
        let pause = PushRegistrationPause()
        defer { pause.resume() }
        remote.afterPushRegistrationSend = { await pause.wait() }
        let token = String(repeating: "ab", count: 32)
        try await paired.phone.send([
            "data": RemoteCrypto.seal(
                RemoteRequest(challenge: paired.challenge, sequence: 2, action: "notify", text: token),
                key: paired.device, direction: "phone")
        ])
        for _ in 0..<200 {
            if pause.entered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pause.entered)
        remote.stop(revoke: true)
        #expect(store.load() == nil)
        pause.resume()
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.load() == nil)
        #expect(!remote.isEnabled)
    }

    @Test func aNewerScreenCannotBeOverwrittenByAnOlderBatchesTail() async throws {
        let relay = try await RelayFixture()
        defer { relay.stop() }
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("ordered-stream")
        let tab = try #require(fixture.model.newTab(in: folder))
        let remote = fixture.model.remoteControl
        defer { remote.stop() }
        remote.start(urlText: relay.origin, model: fixture.model)
        let paired = try await relay.pair(remote)
        defer { paired.phone.close() }
        let watched = try await paired.phone.request(
            RemoteRequest(challenge: paired.challenge, sequence: 2, action: "watch"), key: paired.device)
        #expect(watched.ok)
        let view = try #require(tab.controller.view as? LocalProcessTerminalView)
        // 12 KB of text with per-cell styles becomes several real wire frames.
        let styledLine = (0..<80).map { "\u{1b}[\($0.isMultiple(of: 2) ? 31 : 32)mO" }.joined()
        view.feed(text: (0..<145).map { _ in styledLine + "\r\n" }.joined())
        remote.noteChange()
        let first: RemoteReply = try RemoteCrypto.open(
            try #require(try await paired.phone.receive()["data"]), key: paired.device, direction: "mac")
        #expect(first.event == true)
        let firstRows = try #require(first.state?.screen?.rows)
        #expect(firstRows.count < tab.controller.remoteScreenWindow().rows.count)
        var rows = Dictionary(uniqueKeysWithValues: firstRows.map { ($0.i, $0.t) })
        // This changes a row near the old batch's tail while that batch is in flight.
        view.feed(text: "\u{1b}[H\u{1b}[0mNEW_GENERATION\u{1b}[K")
        remote.noteChange()
        let changed = try #require(tab.controller.remoteScreenWindow().rows.first { $0.t.contains("NEW_GENERATION") })
        try await Task.sleep(for: .milliseconds(650))
        // A solicited reply is a barrier after every scheduled event send.
        try await paired.phone.send([
            "data": RemoteCrypto.seal(
                RemoteRequest(challenge: paired.challenge, sequence: 3, action: "state"),
                key: paired.device, direction: "phone")
        ])
        var sequence = first.eventSequence ?? 0
        var eventCount = 1
        var sawNew = false
        for _ in 0..<40 {
            let frame: RemoteReply = try RemoteCrypto.open(
                try #require(try await paired.phone.receive()["data"]), key: paired.device, direction: "mac")
            if frame.sequence == 3 {
                #expect(frame.state?.terminal.contains("NEW_GENERATION") == true)
                break
            }
            guard frame.event == true else { continue }
            eventCount += 1
            let next = try #require(frame.eventSequence)
            #expect(next > sequence)
            sequence = next
            for row in frame.state?.screen?.rows ?? [] {
                rows[row.i] = row.t
                if row.t.contains("NEW_GENERATION") { sawNew = true }
            }
        }
        #expect(eventCount >= 3)
        #expect(sawNew)
        #expect(rows[changed.i]?.contains("NEW_GENERATION") == true)
    }
}

@MainActor
private final class PushRegistrationPause {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
