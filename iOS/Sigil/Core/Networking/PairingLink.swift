import Foundation

/// A QR code or copied link from Sigil → Settings → Remote.
/// The secrets travel in the fragment, so no server ever logs them.
struct PairingLink: Equatable {
    let origin: URL
    let room: String
    let key: String

    static let defaultOrigin = URL(string: "https://remote.sigilapp.dev")!

    enum Failure: Error, Equatable {
        case notALink
        case insecure
    }

    /// Accepts the full link, or just its `room=…&key=…` fragment for the default address.
    static func parse(_ text: String) -> Result<PairingLink, Failure> {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 4_096 else { return .failure(.notALink) }
        if raw.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil {
            let fragment = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
            guard let secrets = secrets(fragment) else { return .failure(.notALink) }
            return .success(PairingLink(origin: defaultOrigin, room: secrets.room, key: secrets.key))
        }
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty, let fragment = components.fragment,
            let secrets = secrets(fragment)
        else { return .failure(.notALink) }
        guard scheme == "https" || (scheme == "http" && isLoopback(host)) else { return .failure(.insecure) }
        var base = URLComponents()
        base.scheme = scheme
        base.host = host.lowercased()
        base.port = components.port
        guard let origin = base.url else { return .failure(.notALink) }
        return .success(PairingLink(origin: origin, room: secrets.room, key: secrets.key))
    }

    private static func secrets(_ fragment: String) -> (room: String, key: String)? {
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, values[parts[0]] == nil else { continue }
            values[parts[0]] = parts[1]
        }
        guard let room = values["room"], room.utf8.count == 32, RemoteCrypto.isLowerHex(room),
            let key = values["key"], RemoteCrypto.isValidKey(key)
        else { return nil }
        return (room, key)
    }

    /// Plain HTTP only reaches a relay on this device; Sigil's debug builds allow the same.
    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1"].contains(host.lowercased())
    }
}
