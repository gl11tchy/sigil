import Darwin
import Foundation

/// A disposable, private display cache. It never writes provider-owned history.
struct SessionIndexFile: Sendable {
    static let version = 1
    static let byteLimit = 8 * 1024 * 1024
    static let entryLimit = 10_000
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sigil/history-index.json")
    }

    struct Root: Codable, Equatable, Sendable {
        var provider: CLIProvider
        var path: String
    }

    struct Snapshot: Codable, Sendable {
        var version = SessionIndexFile.version
        var roots: [Root]
        var entries: [String: SessionCacheEntry]
        var titleIndexes: [String: CodexTitleIndexCache.DisplaySnapshot] = [:]
    }

    let url: URL
    // Deterministic race/failure injection, after preparing our own temporary file.
    var beforeCommit: @Sendable () throws -> Void = {}

    static func roots(grok: URL, native: [(CLIProvider, URL)]) -> [Root] {
        ([Root(provider: .grokBuild, path: grok.standardizedFileURL.path)]
            + native.map { Root(provider: $0.0, path: $0.1.standardizedFileURL.path) })
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    func load(roots: [Root]) -> Snapshot? {
        do {
            let parent = try openParent(create: false)
            defer { close(parent) }
            let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            let before = try privateFile(fd)
            guard before.st_size >= 0, before.st_size <= Self.byteLimit else { return nil }
            var data = Data()
            while data.count < Int(before.st_size) {
                try Task.checkCancellation()
                let requested = min(64 * 1024, Int(before.st_size) - data.count)
                let chunk = try handle.read(upToCount: requested) ?? Data()
                guard !chunk.isEmpty else { return nil }
                data.append(chunk)
            }
            let after = try privateFile(fd)
            guard sameFile(before, after), try boundToPath(parent: parent, info: after) else { return nil }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard valid(snapshot, roots: roots) else { return nil }
            return snapshot
        } catch { return nil }
    }

    /// Atomic replacement retains the last valid index on any preparation failure.
    @discardableResult
    func save(_ snapshot: Snapshot) -> Bool {
        do {
            try Task.checkCancellation()
            guard valid(snapshot, roots: snapshot.roots) else { return false }
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= Self.byteLimit else { return false }
            let parent = try openParent(create: true)
            defer { close(parent) }
            guard safeDestination(parent) else { return false }
            let temporary = ".history-index-\(UUID().uuidString).tmp"
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return false }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer {
                try? handle.close()
                unlinkat(parent, temporary, 0)
            }
            // Creation is private even under a permissive umask. Verify before writing titles.
            _ = try privateFile(fd)
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0 else { return false }
            let written = try privateFile(fd)
            guard written.st_size == data.count else { return false }
            try beforeCommit()
            try Task.checkCancellation()
            let prepared = try privateFile(fd)
            var temporaryInfo = stat()
            guard fstatat(parent, temporary, &temporaryInfo, AT_SYMLINK_NOFOLLOW) == 0,
                temporaryInfo.st_mode & S_IFMT == S_IFREG, sameFile(prepared, temporaryInfo)
            else { return false }
            let currentParent = try openParent(create: false)
            defer { close(currentParent) }
            var original = stat()
            var current = stat()
            guard fstat(parent, &original) == 0, fstat(currentParent, &current) == 0,
                original.st_dev == current.st_dev, original.st_ino == current.st_ino,
                safeDestination(parent),
                renameat(parent, temporary, parent, url.lastPathComponent) == 0
            else { return false }
            let committed = try privateFile(fd)
            return try boundToPath(parent: parent, info: committed)
        } catch { return false }
    }

    private func valid(_ snapshot: Snapshot, roots: [Root]) -> Bool {
        guard snapshot.version == Self.version, snapshot.roots == roots,
            roots.count <= 3, Set(roots.map(\.provider)).count == roots.count,
            roots.allSatisfy({ supported($0.provider) && absolutePath($0.path) }),
            snapshot.entries.count <= Self.entryLimit, snapshot.titleIndexes.count <= 1
        else { return false }
        var inspected: [String: Bool] = [:]
        var grokFolders: [String: String] = [:]
        for (key, entry) in snapshot.entries {
            let session = entry.session
            guard let root = roots.first(where: { $0.provider == session.provider }),
                safeSource(key, under: root.path, inspected: &inspected), session.directory.isFileURL,
                session.directory.host?.isEmpty != false,
                session.directory.query == nil, session.directory.fragment == nil,
                absolutePath(session.directory.path),
                physicalSystemPath(session.directory.path) == physicalSystemPath(key),
                validIdentifier(session.nativeSessionID, provider: session.provider),
                absolutePath(session.cwd), session.summary.utf8.count <= 4096,
                [session.modelID, session.agentName, session.reasoningEffort, session.kind, entry.nativeSummary]
                    .allSatisfy({ ($0?.utf8.count ?? 0) <= 4096 }),
                session.messageCount >= 0, entry.size >= 0, entry.inode != nil, entry.device != nil,
                entry.changeDate != nil,
                [session.createdAt, session.updatedAt, entry.modificationDate, entry.changeDate!]
                    .allSatisfy({
                        $0.timeIntervalSince1970.isFinite
                            && (-62_135_596_800.0...253_402_300_799.0).contains($0.timeIntervalSince1970)
                    })
            else { return false }
            let relative = String(key.dropFirst(root.path.count + 1)).split(separator: "/")
            if session.provider == .grokBuild {
                let folder =
                    grokFolders[session.cwd]
                    ?? GrokPaths.sessionFolderName(forCanonicalPath: GrokPaths.canonicalPath(session.cwd))
                grokFolders[session.cwd] = folder
                guard relative.count == 2, relative.last?.lowercased() == session.nativeSessionID.lowercased(),
                    relative.first.map(String.init) == folder,
                    safeSource(key + "/summary.json", under: root.path, inspected: &inspected)
                else { return false }
            } else {
                guard session.directory.pathExtension == "jsonl",
                    !relative.contains(where: { $0 == "subagents" || $0 == "tool-results" || $0.hasPrefix(".") })
                else { return false }
            }
        }
        for (path, title) in snapshot.titleIndexes {
            guard let codex = roots.first(where: { $0.provider == .codex }),
                path
                    == URL(fileURLWithPath: codex.path).deletingLastPathComponent()
                    .appendingPathComponent("session_index.jsonl").path,
                safeSource(
                    path, under: URL(fileURLWithPath: codex.path).deletingLastPathComponent().path,
                    inspected: &inspected),
                title.identity.size >= 0, title.names.count <= Self.entryLimit,
                title.names.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.utf8.count <= 4096 })
            else { return false }
        }
        return true
    }

    private func supported(_ provider: CLIProvider) -> Bool {
        provider == .grokBuild || provider == .claudeCode || provider == .codex
    }

    private func validIdentifier(_ id: String, provider: CLIProvider) -> Bool {
        if provider != .grokBuild { return UUID(uuidString: id) != nil }
        // Grok summaries support non-UUID identifiers. They still identify exactly one safe folder component.
        return !id.isEmpty && id.utf8.count <= 4096 && id != "." && id != ".."
            && !id.contains("/") && !id.contains("\0")
    }

    /// Foundation standardizes the macOS system aliases back to /var and /tmp.
    /// Expand only those OS aliases; arbitrary source/parent symlinks must still fail the no-follow checks.
    private func physicalSystemPath(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            let physical = GrokPaths.canonicalPath(alias)
            return physical + path.dropFirst(alias.count)
        }
        return path
    }

    private func absolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096,
            !path.contains("//"), path == "/" || !path.hasSuffix("/")
        else { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    func permitsSource(_ path: String, roots: [Root], provider: CLIProvider) -> Bool {
        guard let root = roots.first(where: { $0.provider == provider }) else { return false }
        var inspected: [String: Bool] = [:]
        return safeSource(path, under: root.path, inspected: &inspected)
            && (provider != .grokBuild || safeSource(path + "/summary.json", under: root.path, inspected: &inspected))
    }

    /// Inspect shared ancestors once per load, without following source symlinks.
    /// A deleted source can still be displayed until scanning proves its absence.
    private func safeSource(_ path: String, under root: String, inspected: inout [String: Bool]) -> Bool {
        guard absolutePath(path), path.hasPrefix(root + "/") else { return false }
        let canonicalKey = "\0" + root
        if inspected[canonicalKey] == nil {
            inspected[canonicalKey] = GrokPaths.canonicalPath(root) == physicalSystemPath(root)
        }
        guard inspected[canonicalKey] == true else { return false }
        var component = root
        for part in [""] + path.dropFirst(root.count + 1).split(separator: "/").map(String.init) {
            if !part.isEmpty { component += "/" + part }
            if let safe = inspected[component] {
                if !safe { return false }
                continue
            }
            var info = stat()
            if lstat(physicalSystemPath(component), &info) == 0 {
                let safe = info.st_mode & S_IFMT != S_IFLNK
                inspected[component] = safe
                if !safe { return false }
            } else if errno == ENOENT {
                return true
            } else {
                return false
            }
        }
        return true
    }

    private func openParent(create: Bool) throws -> Int32 {
        guard url.isFileURL, absolutePath(url.path), url.lastPathComponent == "history-index.json" else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        do {
            for component in physicalSystemPath(url.deletingLastPathComponent().path).split(separator: "/").map(
                String.init)
            {
                if create, mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST {
                    throw CocoaError(.fileWriteUnknown)
                }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw CocoaError(.fileReadUnknown) }
                close(descriptor)
                descriptor = next
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
                throw CocoaError(.fileReadNoPermission)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func safeDestination(_ parent: Int32) -> Bool {
        var info = stat()
        if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT }
        return info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
    }

    private func privateFile(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600
        else { throw CocoaError(.fileReadNoPermission) }
        return info
    }

    private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func boundToPath(parent: Int32, info: stat) throws -> Bool {
        var pathInfo = stat()
        return fstatat(parent, url.lastPathComponent, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0
            && pathInfo.st_mode & S_IFMT == S_IFREG && sameFile(info, pathInfo)
    }
}

/// Serial off-main writes discard older queued snapshots from the same store.
actor SessionIndexWriter {
    private var latestSequence = 0

    func save(
        _ snapshot: SessionIndexFile.Snapshot, to file: SessionIndexFile, sequence: Int,
        titleIndexCache: CodexTitleIndexCache? = nil
    ) {
        guard !Task.isCancelled, sequence >= latestSequence else { return }
        latestSequence = sequence
        var snapshot = snapshot
        if let titleIndexCache { snapshot.titleIndexes = titleIndexCache.displaySnapshots() }
        file.save(snapshot)
    }
}
