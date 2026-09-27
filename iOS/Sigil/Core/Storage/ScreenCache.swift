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

    /// Every save, delete and load goes through one writer, off the main actor and in order.
    static let writer = ScreenCacheWriter { directory }

    /// Reads and decodes off the main actor. The cache comes back only if `isCurrent`
    /// still holds once it is read: the screen may have moved on meanwhile.
    @MainActor
    static func restore(for credential: PairingCredential, if isCurrent: () -> Bool) async -> CachedScreen? {
        await writer.restore(for: credential, if: isCurrent)
    }

    /// Returns at once. The writer encodes and writes later, and only the newest snapshot.
    @MainActor
    static func save(_ cached: CachedScreen, for credential: PairingCredential) {
        writer.save(cached, for: credential)
    }

    @MainActor
    static func delete(for credential: PairingCredential) {
        writer.delete(for: credential)
    }

    static func read(_ url: URL) -> CachedScreen? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CachedScreen.self, from: data)
    }

    @discardableResult
    static func write(_ cached: CachedScreen, to url: URL) -> Bool {
        guard let data = try? encoder.encode(cached) else { return false }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return (try? data.write(to: url, options: options)) != nil
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
