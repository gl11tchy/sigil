import CryptoKit
import Foundation

/// What the app shows before the socket comes up: the tabs and the selected
/// session's rows as they were last seen from one Mac.
struct CachedScreen: Codable, Equatable {
    var tabs: [RemoteTab]
    var selectedTabID: String?
    var mac: String?
    var screens: [String: ScreenModel]
    var savedAt: Date
}

/// One JSON file per Mac under Application Support, named by a digest of the
/// pairing so the file name never carries a key.
enum ScreenCache {
    static func fileName(for credential: PairingCredential) -> String {
        let digest = SHA256.hash(data: Data(credential.deviceKey.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    static var directory: URL? {
        guard
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = base.appendingPathComponent("Screens", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func load(for credential: PairingCredential) -> CachedScreen? {
        guard let url = directory?.appendingPathComponent(fileName(for: credential)),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? decoder.decode(CachedScreen.self, from: data)
    }

    @discardableResult
    static func save(_ cached: CachedScreen, for credential: PairingCredential) -> Bool {
        guard let url = directory?.appendingPathComponent(fileName(for: credential)),
            let data = try? encoder.encode(cached)
        else { return false }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return (try? data.write(to: url, options: options)) != nil
    }

    static func delete(for credential: PairingCredential) {
        guard let url = directory?.appendingPathComponent(fileName(for: credential)) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
