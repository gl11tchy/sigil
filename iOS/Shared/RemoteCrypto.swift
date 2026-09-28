import CryptoKit
import Foundation

enum RemoteCryptoError: Error, Equatable {
    case invalidKey
    case invalidMessage
    case tooLarge
}

/// The sealed-frame format Sigil and Sidereal share: base64 of nonce, ciphertext
/// and tag, with the direction bound in as associated data so a reply cannot be
/// reflected back as a request. It must match `RemoteCrypto` in SigilKit byte for byte.
enum RemoteCrypto {
    static let plaintextLimit = 65_536
    static let frameLimit = 100_000

    static func randomKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { hex(Data($0)) }
    }

    static func isValidKey(_ value: String) -> Bool {
        value.utf8.count == 64 && isLowerHex(value)
    }

    static func isLowerHex(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func seal<T: Encodable>(_ value: T, key secret: String, direction: String) throws -> String {
        let plaintext = try JSONEncoder().encode(value)
        guard plaintext.count <= plaintextLimit else { throw RemoteCryptoError.tooLarge }
        let box = try AES.GCM.seal(plaintext, using: key(secret), authenticating: aad(direction))
        guard let combined = box.combined else { throw RemoteCryptoError.invalidMessage }
        return combined.base64EncodedString()
    }

    static func open<T: Decodable>(_ frame: String, key secret: String, direction: String) throws -> T {
        guard frame.utf8.count <= frameLimit, let bytes = Data(base64Encoded: frame), bytes.count > 28 else {
            throw RemoteCryptoError.invalidMessage
        }
        let plaintext = try AES.GCM.open(
            AES.GCM.SealedBox(combined: bytes), using: key(secret), authenticating: aad(direction))
        guard plaintext.count <= plaintextLimit else { throw RemoteCryptoError.tooLarge }
        return try JSONDecoder().decode(T.self, from: plaintext)
    }

    private static func aad(_ direction: String) -> Data {
        Data("sigil-remote-v1:\(direction)".utf8)
    }

    private static func key(_ value: String) throws -> SymmetricKey {
        guard isValidKey(value) else { throw RemoteCryptoError.invalidKey }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var iterator = value.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            bytes.append(nibble(high) << 4 | nibble(low))
        }
        return SymmetricKey(data: Data(bytes))
    }

    private static func nibble(_ c: UInt8) -> UInt8 {
        c <= 57 ? c - 48 : c - 87
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
