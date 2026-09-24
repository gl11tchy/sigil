import Foundation

enum ProtocolTests {
    static let key = String(repeating: "ab", count: 32)
    static let other = String(repeating: "cd", count: 32)

    struct Sample: Codable, Equatable {
        let action: String
        let sequence: Int
    }

    static func cryptoRoundTrip() throws {
        let sealed = try RemoteCrypto.seal(Sample(action: "state", sequence: 1), key: key, direction: "phone")
        let opened: Sample = try RemoteCrypto.open(sealed, key: key, direction: "phone")
        try Expect.equal(opened, Sample(action: "state", sequence: 1), "round trip")
    }

    /// Direction is authenticated: a phone frame reflected back as a Mac frame must not open.
    static func cryptoRejectsWrongDirectionKeyAndTampering() throws {
        let sealed = try RemoteCrypto.seal(Sample(action: "state", sequence: 1), key: key, direction: "phone")
        try Expect.true((try? RemoteCrypto.open(sealed, key: key, direction: "mac") as Sample) == nil, "direction")
        try Expect.true((try? RemoteCrypto.open(sealed, key: other, direction: "phone") as Sample) == nil, "key")
        var bytes = Data(base64Encoded: sealed)!
        bytes[bytes.count - 1] ^= 1
        let tampered = bytes.base64EncodedString()
        try Expect.true((try? RemoteCrypto.open(tampered, key: key, direction: "phone") as Sample) == nil, "tamper")
        try Expect.true((try? RemoteCrypto.open("not base64", key: key, direction: "phone") as Sample) == nil, "junk")
    }

    static func cryptoRejectsBadKeys() throws {
        for bad in ["", String(repeating: "AB", count: 32), String(repeating: "a", count: 63), String(repeating: "g", count: 64)] {
            try Expect.true(!RemoteCrypto.isValidKey(bad), "invalid key accepted: \(bad)")
            try Expect.true((try? RemoteCrypto.seal(Sample(action: "x", sequence: 1), key: bad, direction: "phone")) == nil, "sealed with \(bad)")
        }
        let fresh = RemoteCrypto.randomKey()
        try Expect.true(RemoteCrypto.isValidKey(fresh), "random key shape")
        try Expect.true(fresh != RemoteCrypto.randomKey(), "random keys differ")
    }

    /// The same sealed format as SigilKit: nonce 12 + ciphertext + tag 16, base64.
    static func cryptoFrameLayout() throws {
        let sealed = try RemoteCrypto.seal(Sample(action: "state", sequence: 1), key: key, direction: "phone")
        let plain = try JSONEncoder().encode(Sample(action: "state", sequence: 1))
        try Expect.equal(Data(base64Encoded: sealed)!.count, 12 + plain.count + 16, "frame layout")
    }

    static func pairingLinkTable() throws {
        let room = String(repeating: "0123456789abcdef", count: 2)
        let cases: [(String, Result<PairingLink, PairingLink.Failure>)] = [
            ("https://remote.sigilapp.dev/#room=\(room)&key=\(key)",
             .success(PairingLink(origin: URL(string: "https://remote.sigilapp.dev")!, room: room, key: key))),
            ("  https://Relay.Example.com:8443/#key=\(key)&room=\(room)\n",
             .success(PairingLink(origin: URL(string: "https://relay.example.com:8443")!, room: room, key: key))),
            ("#room=\(room)&key=\(key)",
             .success(PairingLink(origin: PairingLink.defaultOrigin, room: room, key: key))),
            ("room=\(room)&key=\(key)",
             .success(PairingLink(origin: PairingLink.defaultOrigin, room: room, key: key))),
            ("http://localhost:3099/#room=\(room)&key=\(key)",
             .success(PairingLink(origin: URL(string: "http://localhost:3099")!, room: room, key: key))),
            ("http://relay.example.com/#room=\(room)&key=\(key)", .failure(.insecure)),
            ("ftp://relay.example.com/#room=\(room)&key=\(key)", .failure(.insecure)),
            ("https://remote.sigilapp.dev/?room=\(room)&key=\(key)", .failure(.notALink)),
            ("https://remote.sigilapp.dev/#room=\(room.uppercased())&key=\(key)", .failure(.notALink)),
            ("https://remote.sigilapp.dev/#room=\(room)&key=\(key.dropLast())", .failure(.notALink)),
            ("https://remote.sigilapp.dev/", .failure(.notALink)),
            ("", .failure(.notALink)),
            ("hello", .failure(.notALink)),
        ]
        for (input, expected) in cases {
            try Expect.equal(PairingLink.parse(input), expected, "parse \(input)")
        }
    }

    static func credentialAddresses() throws {
        let credential = PairingCredential(
            origin: URL(string: "https://remote.sigilapp.dev")!, room: String(repeating: "a", count: 32),
            deviceKey: key, ticket: nil)
        try Expect.equal(credential.originString, "https://remote.sigilapp.dev", "origin header has no slash")
        try Expect.equal(credential.connectURL?.absoluteString, "wss://remote.sigilapp.dev/connect?role=phone", "wss url")
        try Expect.true(credential.isValid, "valid credential")
        let local = PairingCredential(
            origin: URL(string: "http://localhost:3099")!, room: credential.room, deviceKey: key, ticket: "bad")
        try Expect.equal(local.connectURL?.absoluteString, "ws://localhost:3099/connect?role=phone", "ws url")
        try Expect.true(!local.isValid, "bad ticket rejected")
    }

    /// No ticket before the first pairing: the relay rejects a ticket that is present but malformed.
    static func routeOmitsMissingTicket() throws {
        let json = String(decoding: try JSONEncoder().encode(RouteEnvelope(room: "r", ticket: nil)), as: UTF8.self)
        try Expect.equal(json, #"{"room":"r"}"#, "ticket omitted")
    }

    static func requestOmitsMissingFields() throws {
        let request = RemoteRequest(challenge: "c", sequence: 2, action: "state")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        try Expect.equal(Set(object?.keys.map { $0 } ?? []), ["challenge", "sequence", "action"], "only set fields")
    }

    /// A reply exactly as the Mac's `RemoteReply` encodes it.
    static func decodesMacReply() throws {
        let json = #"""
        {"challenge":"c","sequence":3,"ok":true,"chatsTruncated":false,"projectsTruncated":false,
         "ticket":"t","state":{"tabs":[{"id":"A","title":"one","status":"working"},{"id":"B","title":"two","status":"paused"}],
         "selectedTabID":"A","terminal":"hi","capabilities":["restart"],"tabsTruncated":false}}
        """#
        let reply = try JSONDecoder().decode(RemoteReply.self, from: Data(json.utf8))
        let state = try Expect.notNil(reply.state, "state")
        try state.validate()
        try Expect.equal(state.tabs[0].status, .working, "known status")
        try Expect.equal(state.tabs[1].status, .unknown("paused"), "unknown status is kept, not guessed")
        try Expect.true(state.canRestart, "restart capability")
        try Expect.true(state.tabListIsComplete, "complete list")
    }

    static func stateValidation() throws {
        func state(_ ids: [String], selected: String?, truncated: Bool? = nil) -> RemoteState {
            RemoteState(
                tabs: ids.map { RemoteTab(id: $0, title: $0, status: .idle) }, selectedTabID: selected,
                terminal: "", capabilities: nil, tabsTruncated: truncated)
        }
        try state(["a", "b"], selected: "a").validate()
        try state([], selected: nil).validate()
        try Expect.true((try? state(["a", "a"], selected: "a").validate()) == nil, "duplicate ids")
        try Expect.true((try? state(["a"], selected: "z").validate()) == nil, "selected must exist")
        try Expect.true((try? state([""], selected: nil).validate()) == nil, "empty id")
        try Expect.true(!state((0..<100).map(String.init), selected: nil).tabListIsComplete, "old Mac, 100 rows")
        try Expect.true(state((0..<100).map(String.init), selected: nil, truncated: false).tabListIsComplete, "flag wins")
    }
}

extension PairingLink.Failure: CustomStringConvertible {
    public var description: String { self == .insecure ? "insecure" : "notALink" }
}
