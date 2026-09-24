import Foundation

/// What a push notification says. The Mac seals it with the device key, so the
/// relay and Apple carry ciphertext; the notification extension opens it here.
struct RemoteAlert: Codable, Equatable {
    enum Kind: Equatable {
        case finished
        case asking
        case ended
        /// A kind this build does not know. Shown with a plain body, never guessed.
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "finished": self = .finished
            case "asking": self = .asking
            case "ended": self = .ended
            default: self = .unknown(raw)
            }
        }
    }

    let kind: Kind
    let tabID: String
    let title: String
    let body: String

    /// The sealing direction, distinct from replies so a reply can never pass as an alert.
    static let direction = "push"

    private enum CodingKeys: String, CodingKey { case kind, tabID, title, body }

    init(kind: Kind, tabID: String, title: String, body: String) {
        self.kind = kind
        self.tabID = tabID
        self.title = title
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(raw: try c.decode(String.self, forKey: .kind))
        tabID = try c.decode(String.self, forKey: .tabID)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let raw: String
        switch kind {
        case .finished: raw = "finished"
        case .asking: raw = "asking"
        case .ended: raw = "ended"
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
        for key in keys {
            if let alert: RemoteAlert = try? RemoteCrypto.open(sealed, key: key, direction: direction) {
                return alert
            }
        }
        return nil
    }

    /// The notification's own words for a kind, when the Mac's body is empty.
    var shownBody: String {
        if !body.isEmpty { return body }
        switch kind {
        case .finished: return "Finished and waiting for you."
        case .asking: return "Needs your approval."
        case .ended: return "The session ended."
        case .unknown: return "A session needs you."
        }
    }
}
