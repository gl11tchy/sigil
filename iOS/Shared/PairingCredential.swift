import Foundation

/// What the phone keeps after the Mac accepts it. The device key never leaves
/// this phone except inside the one encrypted pairing request. A phone can hold
/// one of these per Mac.
struct PairingCredential: Codable, Equatable, Identifiable {
    /// This phone's own id for the pairing; a pairing saved before ids gets one on load.
    let id: String
    let origin: URL
    let room: String
    let deviceKey: String
    var ticket: String?
    /// The Mac's name, learned from its replies.
    var name: String?

    private enum CodingKeys: String, CodingKey { case id, origin, room, deviceKey, ticket, name }

    init(id: String = UUID().uuidString, origin: URL, room: String, deviceKey: String, ticket: String?, name: String? = nil) {
        self.id = id
        self.origin = origin
        self.room = room
        self.deviceKey = deviceKey
        self.ticket = ticket
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        origin = try c.decode(URL.self, forKey: .origin)
        room = try c.decode(String.self, forKey: .room)
        deviceKey = try c.decode(String.self, forKey: .deviceKey)
        ticket = try c.decodeIfPresent(String.self, forKey: .ticket)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

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
            && (ticket.map(RemoteCrypto.isValidKey) ?? true) && !id.isEmpty && id.utf8.count <= 64
    }

    /// What the picker shows: the Mac's name, else the relay host.
    var label: String {
        if let name, !name.isEmpty { return name }
        return origin.host ?? "Mac"
    }
}

/// The list the phone keeps, and the pure rules for changing it.
struct PairingList: Codable, Equatable {
    var macs: [PairingCredential] = []
    var selectedID: String?

    var selected: PairingCredential? {
        macs.first { $0.id == selectedID } ?? macs.first
    }

    /// Adds or replaces by id; a new Mac becomes the selected one.
    mutating func upsert(_ credential: PairingCredential, select: Bool = true) {
        if let index = macs.firstIndex(where: { $0.id == credential.id }) {
            macs[index] = credential
        } else {
            macs.append(credential)
        }
        if select || selectedID == nil { selectedID = credential.id }
    }

    /// Removes one Mac; the selection moves to the first that is left.
    mutating func remove(id: String) {
        macs.removeAll { $0.id == id }
        if selectedID == id { selectedID = macs.first?.id }
    }
}
