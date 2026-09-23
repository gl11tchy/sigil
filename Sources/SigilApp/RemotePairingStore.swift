import Foundation
import Security
import SigilKit

struct RemotePairing: Codable, Equatable, Sendable {
    var origin: String
    var deviceKey: String
    var ticket: String
}

protocol RemotePairingStore: AnyObject {
    func load() -> RemotePairing?
    func save(_ pairing: RemotePairing)
    func clear() -> Bool
    /// True while a Disconnect could not delete the stored pairing. That
    /// pairing must not be used again, in this run or after a relaunch.
    var revokeFailed: Bool { get set }
}

final class InMemoryRemotePairingStore: RemotePairingStore {
    private var pairing: RemotePairing?
    var revokeFailed = false

    func load() -> RemotePairing? { pairing }
    func save(_ pairing: RemotePairing) { self.pairing = pairing }
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

    func load() -> RemotePairing? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let pairing = try? JSONDecoder().decode(RemotePairing.self, from: data),
            RemoteCrypto.isValidKey(pairing.deviceKey), RemoteCrypto.isValidKey(pairing.ticket)
        else { return nil }
        return pairing
    }

    func save(_ pairing: RemotePairing) {
        clear()
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
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
