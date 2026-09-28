import Foundation
import Security

/// The pairings live in the Keychain, this device only, readable after first
/// unlock. They are never in a backup, so a restored phone has to pair again.
/// One item holds the whole list; a single pairing saved by an earlier build is
/// folded into it on first load.
enum CredentialStore {
    private static let service = "com.gl11tchy.sigilremote.pairing"
    private static let legacyAccount = "mac"
    private static let listAccount = "macs"

    /// The whole list, migrating a pre-list pairing if one is still there.
    static func loadList() -> PairingList {
        if let data = read(account: listAccount), let list = try? JSONDecoder().decode(PairingList.self, from: data) {
            return PairingList(macs: list.macs.filter(\.isValid), selectedID: list.selectedID)
        }
        guard let data = read(account: legacyAccount),
            let old = try? JSONDecoder().decode(PairingCredential.self, from: data), old.isValid
        else { return PairingList() }
        var list = PairingList()
        list.upsert(old)
        if save(list) { delete(account: legacyAccount) }
        return list
    }

    /// Every pairing on this phone, for the notification extension to try keys from.
    static func loadAll() -> [PairingCredential] {
        loadList().macs
    }

    /// The selected pairing, or nil when the phone has none.
    static func load() -> PairingCredential? {
        loadList().selected
    }

    /// Adds or replaces one pairing and selects it.
    @discardableResult
    static func save(_ credential: PairingCredential, select: Bool = true) -> Bool {
        var list = loadList()
        list.upsert(credential, select: select)
        return save(list)
    }

    @discardableResult
    static func save(_ list: PairingList) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return write(data, account: listAccount)
    }

    @discardableResult
    static func select(id: String) -> Bool {
        var list = loadList()
        guard list.macs.contains(where: { $0.id == id }) else { return false }
        list.selectedID = id
        return save(list)
    }

    /// Removes one pairing. With none left the list item goes too.
    @discardableResult
    static func delete(id: String) -> Bool {
        var list = loadList()
        list.remove(id: id)
        if list.macs.isEmpty { return delete(account: listAccount) }
        return save(list)
    }

    /// Removes every pairing.
    @discardableResult
    static func delete() -> Bool {
        delete(account: legacyAccount) && delete(account: listAccount)
    }

    private static func read(account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data, account: String) -> Bool {
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let result = SecItemUpdate(base(account) as CFDictionary, values as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        var item = base(account)
        values.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func delete(account: String) -> Bool {
        let status = SecItemDelete(base(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
