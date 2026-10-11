import Darwin
import Foundation

/// Read-only search projection of known conversations, never legacy adoption.
/// Every body read and in-memory projection is capped at 64 KiB of UTF-8.
enum ConversationNotesIndex: Sendable {
    static let byteLimit = 64 * 1024

    struct Key: Hashable, Sendable {
        let provider: CLIProvider
        let sessionID: String
        let cwd: String
    }

    struct Item: Sendable {
        let key: Key
        let file: URL
        var legacy: URL?
    }

    struct Catalog: Sendable {
        var references: [ProviderSessionReference: Key] = [:]
        var items: [Key: Item] = [:]
    }

    static func catalog(
        root: URL, references: Set<ProviderSessionReference>, isCancelled: @Sendable () -> Bool = { false }
    ) -> Catalog {
        var result = Catalog()
        var grokFolders: [String: Set<String>] = [:]
        var canonicalPaths: [String: String] = [:]
        for reference in references {
            guard !isCancelled() else { return result }
            guard reference.cwd.hasPrefix("/") else { continue }
            let id: String
            switch reference.provider {
            case .grokBuild:
                guard validGrokID(reference.sessionID) else { continue }
                id = reference.sessionID
            case .claudeCode, .codex:
                guard let uuid = UUID(uuidString: reference.sessionID) else { continue }
                id = uuid.uuidString.lowercased()
            default: continue
            }
            let cwd = canonicalPaths[reference.cwd] ?? GrokPaths.canonicalPath(reference.cwd)
            canonicalPaths[reference.cwd] = cwd
            let key = Key(provider: reference.provider, sessionID: id, cwd: cwd)
            result.references[reference] = key
            var folder = root
            if reference.provider != .grokBuild { folder.appendPathComponent(reference.provider.rawValue) }
            folder.appendPathComponent(GrokPaths.sessionFolderName(forCanonicalPath: cwd))
            result.items[key] = Item(key: key, file: folder.appendingPathComponent(id + ".md"))
            if reference.provider == .grokBuild { grokFolders[id, default: []].insert(cwd) }
        }
        for (key, var item) in result.items where key.provider == .grokBuild && grokFolders[key.sessionID]?.count == 1 {
            item.legacy = root.appendingPathComponent(key.sessionID + ".md")
            result.items[key] = item
        }
        return result
    }

    private static func validGrokID(_ id: String) -> Bool {
        !id.isEmpty
            && id.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains(
                    $0)
            }
    }

    struct Fingerprint: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    enum Metadata: Equatable, Sendable {
        case missing, unavailable
        case file(Fingerprint)
    }

    struct Reader: Sendable {
        var metadata: @Sendable (URL) -> Metadata
        var read: @Sendable (URL, Fingerprint) -> Data?

        static let disk = Reader(metadata: metadataAt, read: readPrefix)
    }

    struct Cached: Sendable {
        let fingerprint: Fingerprint
        let folded: String?
    }

    struct Snapshot: Sendable {
        let catalog: Catalog
        var cache: [String: Cached]
        var folded: [Key: String]
        var origins: [Key: String]

        func foldedNote(for reference: ProviderSessionReference, overlays: [String: String] = [:]) -> String? {
            guard let key = catalog.references[reference], let item = catalog.items[key] else { return nil }
            if let text = overlays[item.file.path] { return text.isEmpty ? nil : text }
            if let legacy = item.legacy, origins[key] == legacy.path, let text = overlays[legacy.path] {
                return text.isEmpty ? nil : text
            }
            return folded[key]
        }
    }

    /// Only exact paths for captured sessions are inspected. No notes-tree walk,
    /// conflict-copy discovery, or file reads happen in the query path.
    static func scan(
        catalog: Catalog, cache: [String: Cached] = [:], reader: Reader = .disk,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Snapshot? {
        var next: [String: Cached] = [:]
        var folded: [Key: String] = [:]
        var origins: [Key: String] = [:]
        for item in catalog.items.values {
            guard !isCancelled() else { return nil }
            var file = item.file
            var metadata = reader.metadata(file)
            if metadata == .missing, let legacy = item.legacy {
                file = legacy
                metadata = reader.metadata(file)
            }
            guard case .file(let fingerprint) = metadata else { continue }
            let record: Cached
            if let old = cache[file.path], old.fingerprint == fingerprint {
                record = old
            } else {
                let text = reader.read(file, fingerprint).flatMap {
                    prefixText($0, mayBeTruncated: fingerprint.size > Int64(byteLimit))
                }
                record = Cached(fingerprint: fingerprint, folded: text.map(SearchMatchHighlight.fold))
            }
            // A transient read failure must not become a permanent cache hit.
            if record.folded != nil {
                next[file.path] = record
                origins[item.key] = file.path
            }
            if let text = record.folded, !text.isEmpty { folded[item.key] = text }
        }
        guard !isCancelled() else { return nil }
        return Snapshot(catalog: catalog, cache: next, folded: folded, origins: origins)
    }

    static func foldedPrefix(_ text: String) -> String {
        let data = Data(text.utf8.prefix(byteLimit))
        return prefixText(data, mayBeTruncated: true).map(SearchMatchHighlight.fold) ?? ""
    }

    /// Called on the matching queue, never by a sidebar row or search keystroke.
    static func matchingReferences(
        query: String, references: Set<ProviderSessionReference>, snapshot: Snapshot?,
        overlays: [String: String], directPaths: [ProviderSessionReference: String] = [:],
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Set<ProviderSessionReference>? {
        guard let query = SessionScanner.SearchQuery(query) else { return [] }
        var result: Set<ProviderSessionReference> = []
        for reference in references {
            guard !isCancelled() else { return nil }
            let text: String?
            if let snapshot {
                text = snapshot.foldedNote(for: reference, overlays: overlays)
            } else {
                text = directPaths[reference].flatMap { overlays[$0] }
            }
            if let text, query.terms.allSatisfy({ !isCancelled() && text.contains($0) }) { result.insert(reference) }
        }
        return isCancelled() ? nil : result
    }

    private static func prefixText(_ data: Data, mayBeTruncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard mayBeTruncated else { return nil }
        // Trim an incomplete scalar, never arbitrary malformed trailing bytes.
        let tail = Array(data.suffix(4))
        guard let lead = tail.lastIndex(where: { $0 & 0xC0 != 0x80 }) else { return nil }
        let byte = tail[lead]
        let expected: Int
        switch byte {
        case 0xC2...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF4: expected = 4
        default: return nil
        }
        let available = tail.count - lead
        guard available < expected else { return nil }
        if available > 1 {
            let second = tail[lead + 1]
            guard !(byte == 0xE0 && second < 0xA0), !(byte == 0xED && second > 0x9F),
                !(byte == 0xF0 && second < 0x90), !(byte == 0xF4 && second > 0x8F)
            else { return nil }
        }
        return String(data: data.dropLast(available), encoding: .utf8)
    }

    private static func metadataAt(_ url: URL) -> Metadata {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? .missing : .unavailable }
        guard info.st_mode & S_IFMT == S_IFREG else { return .unavailable }
        return .file(Fingerprint(info))
    }

    private static func readPrefix(_ url: URL, expected: Fingerprint) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            Fingerprint(before) == expected
        else { return nil }
        var data = Data()
        do {
            while data.count < byteLimit {
                guard let part = try handle.read(upToCount: byteLimit - data.count), !part.isEmpty else { break }
                data.append(part)
            }
        } catch { return nil }
        var after = stat()
        guard fstat(descriptor, &after) == 0, Fingerprint(after) == expected,
            metadataAt(url) == .file(expected)
        else { return nil }
        return data
    }
}
