import CryptoKit
import Foundation

public enum RemoteError: Error {
    case invalidMessage
    case pairingExpired
}

public struct RemoteRequest: Codable, Sendable {
    public let challenge: String
    public let sequence: Int
    public let action: String
    public var tabID: String?
    public var text: String?

    public init(challenge: String, sequence: Int, action: String, tabID: String? = nil, text: String? = nil) {
        self.challenge = challenge
        self.sequence = sequence
        self.action = action
        self.tabID = tabID
        self.text = text
    }
}

/// One phone authorization. Credentials deliberately do not survive a Mac app restart.
public struct RemoteSession: Sendable {
    public let pairingKey: String
    public let expiresAt: Date
    public private(set) var challenge = RemoteCrypto.randomKey()
    public private(set) var deviceKey: String?
    private var lastSequence = 0
    public var isPaired: Bool { deviceKey != nil }

    public init(now: Date = Date()) {
        pairingKey = RemoteCrypto.randomKey()
        expiresAt = now.addingTimeInterval(300)
    }

    public mutating func resetConnection() {
        challenge = RemoteCrypto.randomKey()
        lastSequence = 0
    }

    public mutating func accept(_ frame: String, now: Date = Date()) throws -> RemoteRequest {
        let request: RemoteRequest = try RemoteCrypto.open(frame, key: deviceKey ?? pairingKey, direction: "phone")
        guard request.challenge == challenge, request.sequence > lastSequence,
            request.sequence <= 9_007_199_254_740_991,
            request.action.utf8.count <= 32, (request.text?.utf8.count ?? 0) <= 8_192,
            (request.tabID?.utf8.count ?? 0) <= 64
        else { throw RemoteError.invalidMessage }
        if deviceKey == nil {
            guard now < expiresAt else { throw RemoteError.pairingExpired }
            guard request.action == "pair", let key = request.text, key != pairingKey,
                RemoteCrypto.isValidKey(key)
            else { throw RemoteError.invalidMessage }
            deviceKey = key
        } else if request.action == "pair" {
            throw RemoteError.invalidMessage
        }
        lastSequence = request.sequence
        return request
    }
}

public enum RemoteCrypto {
    public static func randomKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    public static func isValidKey(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func key(_ value: String) throws -> SymmetricKey {
        guard isValidKey(value) else { throw RemoteError.invalidMessage }
        let chars = Array(value)
        let bytes = stride(from: 0, to: chars.count, by: 2).compactMap {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)
        }
        return SymmetricKey(data: Data(bytes))
    }

    public static func seal<T: Encodable>(_ value: T, key secret: String, direction: String) throws -> String {
        let plaintext = try JSONEncoder().encode(value)
        guard plaintext.count <= 65_536 else { throw RemoteError.invalidMessage }
        let box = try AES.GCM.seal(
            plaintext, using: key(secret), authenticating: Data("sigil-remote-v1:\(direction)".utf8))
        guard let combined = box.combined else { throw RemoteError.invalidMessage }
        return combined.base64EncodedString()
    }

    public static func open<T: Decodable>(_ frame: String, key secret: String, direction: String) throws -> T {
        guard frame.utf8.count <= 100_000, let bytes = Data(base64Encoded: frame) else {
            throw RemoteError.invalidMessage
        }
        let plaintext = try AES.GCM.open(
            AES.GCM.SealedBox(combined: bytes), using: key(secret),
            authenticating: Data("sigil-remote-v1:\(direction)".utf8))
        guard plaintext.count <= 65_536 else { throw RemoteError.invalidMessage }
        return try JSONDecoder().decode(T.self, from: plaintext)
    }
}
