import Foundation

/// What a push notification says. The Mac seals it with the device key, so the
/// relay and Apple carry ciphertext; the notification extension opens it here.
struct RemoteAlert: Codable, Equatable {
    enum Kind: Equatable {
        case finished
        case asking
        case ended
        case attention, failed, stopped
        /// A kind this build does not know. Shown with a plain body, never guessed.
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "finished": self = .finished
            case "asking": self = .asking
            case "ended": self = .ended
            case "attention": self = .attention
            case "failed": self = .failed
            case "stopped": self = .stopped
            default: self = .unknown(raw)
            }
        }
    }

    let id: String?
    let issuedAt: Int?
    let kind: Kind
    let tabID: String
    let title: String
    let body: String

    /// The sealing direction, distinct from replies so a reply can never pass as an alert.
    static let direction = "push"

    private enum CodingKeys: String, CodingKey { case id, issuedAt, kind, tabID, title, body }

    init(kind: Kind, tabID: String, title: String, body: String,
         id: String = UUID().uuidString, issuedAt: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id
        self.issuedAt = issuedAt
        self.kind = kind
        self.tabID = tabID
        self.title = title
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        issuedAt = try c.decodeIfPresent(Int.self, forKey: .issuedAt)
        kind = Kind(raw: try c.decode(String.self, forKey: .kind))
        tabID = try c.decode(String.self, forKey: .tabID)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(issuedAt, forKey: .issuedAt)
        let raw: String
        switch kind {
        case .finished: raw = "finished"
        case .asking: raw = "asking"
        case .ended: raw = "ended"
        case .attention: raw = "attention"
        case .failed: raw = "failed"
        case .stopped: raw = "stopped"
        case .unknown(let value): raw = value
        }
        try c.encode(raw, forKey: .kind)
        try c.encode(tabID, forKey: .tabID)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
    }

    /// Opens a sealed alert with any of the given device keys: a phone paired
    /// with several Macs tries each, and AES-GCM rejects every wrong one.
    static func open(_ sealed: String, keys: [String]) -> RemoteAlert? {
        opened(sealed, keys: keys)?.alert
    }

    /// The alert and the index of the key that opened it, which names the Mac.
    static func opened(_ sealed: String, keys: [String]) -> (alert: RemoteAlert, keyIndex: Int)? {
        for (index, key) in keys.enumerated() {
            if let alert: RemoteAlert = try? RemoteCrypto.open(sealed, key: key, direction: direction), alert.isFresh() {
                return (alert, index)
            }
        }
        return nil
    }

    func isFresh(now: Int = Int(Date().timeIntervalSince1970)) -> Bool {
        guard let id, UUID(uuidString: id) != nil, let issuedAt else { return false }
        // Compare without subtracting attacker-controlled integers (overflow).
        return issuedAt >= now - 300 && issuedAt <= now + 30
    }

    /// The notification's own words for a kind, when the Mac's body is empty.
    var shownBody: String {
        if !body.isEmpty { return body }
        switch kind {
        case .finished: return "Finished and waiting for you."
        case .asking: return "Needs your approval."
        case .ended: return "The session ended."
        case .attention: return "Check the terminal."
        case .failed: return "The session failed."
        case .stopped: return "The session stopped."
        case .unknown: return "A session needs you."
        }
    }
}
