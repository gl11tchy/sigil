import Foundation

/// What the phone keeps after the Mac accepts it. The device key never leaves
/// this phone except inside the one encrypted pairing request.
struct PairingCredential: Codable, Equatable {
    let origin: URL
    let room: String
    let deviceKey: String
    var ticket: String?

    /// `scheme://host[:port]` exactly, because the relay compares the Origin header as a string.
    var originString: String {
        var parts = URLComponents()
        parts.scheme = origin.scheme
        parts.host = origin.host
        parts.port = origin.port
        return parts.string ?? origin.absoluteString
    }

    var connectURL: URL? {
        var parts = URLComponents()
        parts.scheme = origin.scheme == "https" ? "wss" : "ws"
        parts.host = origin.host
        parts.port = origin.port
        parts.path = "/connect"
        parts.queryItems = [URLQueryItem(name: "role", value: "phone")]
        return parts.url
    }

    var isValid: Bool {
        room.utf8.count == 32 && RemoteCrypto.isLowerHex(room) && RemoteCrypto.isValidKey(deviceKey)
            && (ticket.map(RemoteCrypto.isValidKey) ?? true)
    }
}
