import Foundation
import Security
import SigilKit

struct RemotePairing: Codable, Equatable, Sendable {
    var origin: String
    var deviceKey: String
    var ticket: String
}

protocol RemotePairingStore: AnyObject {
    /// Returns nil only when no pairing is stored. Throws when a stored
    /// pairing exists but cannot be read.
    func load() throws -> RemotePairing?
    /// Returns false when the pairing was not stored.
    func save(_ pairing: RemotePairing) -> Bool
    func clear() -> Bool
    /// True while a Disconnect could not delete the stored pairing. That
    /// pairing must not be used again, in this run or after a relaunch.
    var revokeFailed: Bool { get set }
}

final class InMemoryRemotePairingStore: RemotePairingStore {
    private var pairing: RemotePairing?
    var revokeFailed = false

    func load() -> RemotePairing? { pairing }
    @discardableResult func save(_ pairing: RemotePairing) -> Bool {
        self.pairing = pairing
        return true
    }
    @discardableResult func clear() -> Bool {
        pairing = nil
        return true
    }
}

final class KeychainRemotePairingStore: RemotePairingStore {
    private let service: String
    private let account = "pairing"
    private let defaults: UserDefaults

    init(service: String = "app.sigil.remote", defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    var revokeFailed: Bool {
        get { defaults.bool(forKey: "remoteRevokeFailed") }
        set { defaults.set(newValue, forKey: "remoteRevokeFailed") }
    }

    struct ReadError: Error, Equatable {
        let status: OSStatus
    }

    func load() throws -> RemotePairing? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return try Self.pairing(status: status, item: item)
    }

    /// Only a missing item means "not paired". A denied Keychain prompt, for
    /// example after an update with a new signature, must not look like one.
    static func pairing(status: OSStatus, item: CFTypeRef?) throws -> RemotePairing? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ReadError(status: status) }
        guard let data = item as? Data,
            let pairing = try? JSONDecoder().decode(RemotePairing.self, from: data),
            RemoteCrypto.isValidKey(pairing.deviceKey), RemoteCrypto.isValidKey(pairing.ticket)
        else { return nil }
        return pairing
    }

    /// Delete and add, so the new item's access list trusts this build.
    @discardableResult func save(_ pairing: RemotePairing) -> Bool {
        guard clear(), let data = try? JSONEncoder().encode(pairing) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum RemoteReconnectPolicy {
    static func retrySeconds(failures: Int) -> Int {
        min(1 << min(max(failures - 1, 0), 5), 30)
    }

    static func shouldReallocate(failures: Int) -> Bool {
        failures > 0 && failures % 3 == 0
    }

    static func shouldGiveUp(failures _: Int) -> Bool {
        false
    }
}
