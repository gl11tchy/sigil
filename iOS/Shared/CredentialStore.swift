import Foundation
import Security

/// The pairing lives in the Keychain, this device only, readable after first unlock.
/// It is never in a backup, so a restored phone has to pair again.
enum CredentialStore {
    private static let service = "com.gl11tchy.sigilremote.pairing"
    private static let account = "mac"

    /// Every pairing on this phone. One today; the list is what the notification
    /// extension tries keys from.
    static func loadAll() -> [PairingCredential] {
        load().map { [$0] } ?? []
    }

    static func load() -> PairingCredential? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
            let credential = try? JSONDecoder().decode(PairingCredential.self, from: data), credential.isValid
        else { return nil }
        return credential
    }

    @discardableResult
    static func save(_ credential: PairingCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(base as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
