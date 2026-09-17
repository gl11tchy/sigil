import CryptoKit
import Foundation
import Testing

@testable import SigilKit

struct RemoteSessionTests {
    @Test func decryptsBrowserWebCryptoFixture() throws {
        // Produced by Sidereal/public/crypto.mjs with an ephemeral random nonce.
        let frame =
            "xoagH8t3KffYZZjoYboq4JhUak/zXXv9RMdUYYXU9y8b52o/hjv73EpPNjmhf3mlyjFBRkX+KNZHyryXSDWQPY+0e3b1IUWKugWsRh+nhqeRzRg0Wv2xY20="
        let value: RemoteRequest = try RemoteCrypto.open(
            frame, key: String(repeating: "b", count: 64), direction: "phone")
        #expect(value.challenge == "browser-interop")
        #expect(value.sequence == 1)
        #expect(value.action == "state")
    }

    @Test func pairingExpiresAndIsSingleUse() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var session = RemoteSession(now: start)
        let pairing = session.pairingKey
        let device = RemoteCrypto.randomKey()
        let challenge = session.challenge
        let request = RemoteRequest(challenge: challenge, sequence: 1, action: "pair", text: device)
        let frame = try RemoteCrypto.seal(request, key: pairing, direction: "phone")
        #expect(throws: (any Error).self) {
            _ = try session.accept(frame, now: start.addingTimeInterval(301))
        }
        let accepted = try session.accept(frame, now: start)
        #expect(accepted.action == "pair")
        #expect(session.isPaired)
        #expect(throws: (any Error).self) {
            _ = try session.accept(frame, now: start)
        }
        let state = RemoteRequest(challenge: challenge, sequence: 2, action: "state")
        let encrypted = try RemoteCrypto.seal(state, key: device, direction: "phone")
        #expect(try session.accept(encrypted, now: start).action == "state")
        #expect(throws: (any Error).self) {
            _ = try session.accept(encrypted, now: start)
        }
    }

    @Test func rejectsWrongKeyDirectionChallengeAndOversizedFrames() throws {
        var session = RemoteSession()
        let key = session.pairingKey
        let request = RemoteRequest(
            challenge: session.challenge, sequence: 1, action: "pair", text: RemoteCrypto.randomKey())
        for (encryptionKey, direction) in [(RemoteCrypto.randomKey(), "phone"), (key, "mac")] {
            let frame = try RemoteCrypto.seal(request, key: encryptionKey, direction: direction)
            #expect(throws: (any Error).self) {
                _ = try session.accept(frame)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try session.accept(String(repeating: "a", count: 100_001))
        }
        #expect(!session.isPaired)
    }

    @Test func newConnectionResetsSequenceButRejectsOldChallenge() throws {
        var session = RemoteSession()
        let device = RemoteCrypto.randomKey()
        let pair = RemoteRequest(challenge: session.challenge, sequence: 1, action: "pair", text: device)
        _ = try session.accept(RemoteCrypto.seal(pair, key: session.pairingKey, direction: "phone"))
        let oldChallenge = session.challenge
        session.resetConnection()
        #expect(session.challenge != oldChallenge)
        let stale = RemoteRequest(challenge: oldChallenge, sequence: 2, action: "input", text: "do not send")
        #expect(throws: (any Error).self) {
            _ = try session.accept(RemoteCrypto.seal(stale, key: device, direction: "phone"))
        }
        let fresh = RemoteRequest(challenge: session.challenge, sequence: 1, action: "state")
        #expect(try session.accept(RemoteCrypto.seal(fresh, key: device, direction: "phone")).action == "state")
    }

    @Test func restoredPairingAcceptsCommandsWithoutAQR() throws {
        let device = RemoteCrypto.randomKey()
        let ticket = RemoteCrypto.randomKey()
        let start = Date(timeIntervalSince1970: 1_000)
        var session = RemoteSession(deviceKey: device, ticket: ticket, now: start)
        #expect(session.isPaired)
        #expect(session.ticket == ticket)
        #expect(RemoteCrypto.isValidKey(RemoteSession().ticket))
        let state = RemoteRequest(challenge: session.challenge, sequence: 1, action: "state")
        #expect(
            try session.accept(
                RemoteCrypto.seal(state, key: device, direction: "phone"), now: start.addingTimeInterval(301)
            ).action == "state")
        let pair = RemoteRequest(
            challenge: session.challenge, sequence: 2, action: "pair", text: RemoteCrypto.randomKey())
        #expect(throws: (any Error).self) {
            _ = try session.accept(RemoteCrypto.seal(pair, key: device, direction: "phone"), now: start)
        }
    }

    @Test func fileChunksMayBeLargerThanPromptText() throws {
        var session = RemoteSession()
        let device = RemoteCrypto.randomKey()
        let pair = RemoteRequest(challenge: session.challenge, sequence: 1, action: "pair", text: device)
        _ = try session.accept(RemoteCrypto.seal(pair, key: session.pairingKey, direction: "phone"))
        let chunk = RemoteRequest(
            challenge: session.challenge, sequence: 2, action: "file",
            text: String(repeating: "a", count: 20_000), name: "shot.jpg", index: 0, count: 1,
            transfer: String(repeating: "ab", count: 16))
        #expect(try session.accept(RemoteCrypto.seal(chunk, key: device, direction: "phone")).action == "file")
        let named = RemoteRequest(
            challenge: session.challenge, sequence: 3, action: "file", text: "YQ==",
            name: String(repeating: "n", count: 80), index: 0, count: 1,
            transfer: String(repeating: "ab", count: 16))
        #expect(try session.accept(RemoteCrypto.seal(named, key: device, direction: "phone")).action == "file")
        let oversizedInput = RemoteRequest(
            challenge: session.challenge, sequence: 4, action: "input",
            text: String(repeating: "b", count: 8_193))
        #expect(throws: (any Error).self) {
            _ = try session.accept(RemoteCrypto.seal(oversizedInput, key: device, direction: "phone"))
        }
    }
}
