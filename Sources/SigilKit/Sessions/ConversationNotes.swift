import Foundation

/// One Markdown scratch pad per conversation, stored as `<session-id>.md`
/// under `~/Library/Application Support/Sigil/notes/`.
///
/// Files keep the notes readable outside the app and unbounded by what a
/// plist value can hold. Writes are atomic and happen on every keystroke;
/// an in-memory cache keeps re-reads off the disk.
public final class ConversationNotesStore {
    public let root: URL
    private var cache: [String: String] = [:]

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
    }

    public static var defaultRoot: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Sigil/notes", isDirectory: true)
    }

    public func note(for sessionID: String) -> String {
        guard let fileName = Self.fileName(for: sessionID) else { return "" }
        if let cached = cache[fileName] { return cached }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        cache[fileName] = text
        return text
    }

    public func setNote(_ text: String, for sessionID: String) {
        guard let fileName = Self.fileName(for: sessionID) else { return }
        if text.isEmpty {
            deleteNote(for: sessionID)
            return
        }
        cache[fileName] = text
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: root.appendingPathComponent(fileName), options: .atomic)
    }

    public func deleteNote(for sessionID: String) {
        guard let fileName = Self.fileName(for: sessionID) else { return }
        cache.removeValue(forKey: fileName)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(fileName))
    }

    /// Session IDs are UUIDs; refuse anything that could escape the folder or
    /// trip Unicode filename normalization.
    static func fileName(for sessionID: String) -> String? {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !sessionID.isEmpty,
            sessionID.rangeOfCharacter(from: allowed.inverted) == nil
        else { return nil }
        return sessionID + ".md"
    }
}
