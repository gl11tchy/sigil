import Darwin
import Foundation
import os

struct SessionCacheEntry: Sendable, Equatable, Codable {
    var modificationDate: Date
    var size: Int
    /// POSIX inode of the source file. With `device`, an atomic replace cannot reuse this entry.
    var inode: UInt64? = nil
    var device: UInt64? = nil
    /// Attribute-change time (`ctime`). Catches in-place rewrites that restore mtime.
    var changeDate: Date? = nil
    /// Bytes used to build `session`. A metadata miss can skip JSON decoding when the body matches.
    var contents = Data()
    var session: GrokSession
    /// Claude JSONL progress only; Grok summaries and Codex samples keep their existing paths.
    var claudeScan: NativeSessionScanner.ClaudeScanState? = nil
    /// Transcript title before a Codex index override, so eviction/removal can restore it.
    var nativeSummary: String? = nil

    // Transcript bytes and incremental parser state never enter the display index.
    private enum CodingKeys: String, CodingKey {
        case modificationDate, size, inode, device, changeDate, session, nativeSummary
    }
}

enum SessionTimestamp {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = try? Date(raw, strategy: .iso8601) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }
}

enum SessionScanner: Sendable {
    /// Physical scan coverage is separate from whether a file has a supported format.
    struct Coverage: Sendable {
        var observedRoots: Set<String> = []
        var uncertainRoots: Set<String> = []
        var notices: [String: String] = [:]
        var unrecognizedGrokDirectories: Set<String> = []

        mutating func merge(_ other: Coverage) {
            observedRoots.formUnion(other.observedRoots)
            uncertainRoots.formUnion(other.uncertainRoots)
            notices.merge(other.notices) { _, new in new }
            unrecognizedGrokDirectories.formUnion(other.unrecognizedGrokDirectories)
        }
    }

    struct Result: Sendable {
        var sessions: [GrokSession]
        var cache: [String: SessionCacheEntry]
        var loadError: String?
        var coverage = Coverage()

        var notice: String? {
            coverage.notices.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n").nilIfBlank
        }
    }

    enum RootStatus: Sendable {
        case available, missing, unreadable, notDirectory
    }

    /// Inspection and recording share a lock so overlapping scans cannot miss an earlier observation.
    final class RootAvailability: Sendable {
        private let roots = OSAllocatedUnfairLock(initialState: Set<String>())

        func inspect(_ root: URL) -> (status: RootStatus, wasAvailable: Bool) {
            roots.withLock { observed in
                let path = root.standardizedFileURL.path
                let status = SessionScanner.rootStatus(root)
                let wasAvailable = observed.contains(path)
                if case .available = status { observed.insert(path) }
                return (status, wasAvailable)
            }
        }
    }

    /// `fileExists` also returns false on permission failures. Only ENOENT proves absence.
    static func rootStatus(_ root: URL) -> RootStatus {
        var info = stat()
        guard stat(root.path, &info) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        return info.st_mode & S_IFMT == S_IFDIR ? .available : .notDirectory
    }

    /// Reads `summary.json` bodies. Production uses disk; tests inject a counter.
    struct ContentReader: Sendable {
        var read: @Sendable (URL) throws -> Data

        static let disk = ContentReader { url in
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
                throw CocoaError(.fileReadUnknown)
            }
            let data = try handle.readToEnd() ?? Data()
            var after = stat()
            guard lstat(url.path, &after) == 0, after.st_mode & S_IFMT == S_IFREG,
                NativeSessionScanner.FileSnapshot(before) == NativeSessionScanner.FileSnapshot(after)
            else { throw CocoaError(.fileReadUnknown) }
            return data
        }
    }

    static func scan(
        root: URL,
        cache: [String: SessionCacheEntry],
        ignoringCache: Bool = false,
        contentReader: ContentReader = .disk,
        wasAvailable: Bool = false,
        rootAvailability: RootAvailability? = nil
    ) -> Result {
        let fm = FileManager()
        let rootPath = root.standardizedFileURL.path
        var coverage = Coverage()
        let inspection = rootAvailability?.inspect(root) ?? (rootStatus(root), false)
        switch inspection.0 {
        case .missing:
            let uncertain = wasAvailable || inspection.1 || !cache.isEmpty
            if uncertain { coverage.uncertainRoots.insert(rootPath) }
            return Result(
                sessions: cachedSessions(cache),
                cache: cache,
                loadError: uncertain ? "Sessions directory does not exist: \(root.path)" : nil,
                coverage: coverage
            )
        case .unreadable, .notDirectory:
            coverage.uncertainRoots.insert(rootPath)
            return Result(
                sessions: cachedSessions(cache),
                cache: cache,
                loadError: "Sessions directory is unavailable: \(root.path)", coverage: coverage
            )
        case .available:
            coverage.observedRoots.insert(rootPath)
        }

        let projectDirs: [URL]
        do {
            projectDirs = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            coverage.uncertainRoots.insert(rootPath)
            return Result(
                sessions: cachedSessions(cache),
                cache: cache,
                loadError: "Could not read sessions directory: \(error.localizedDescription)", coverage: coverage
            )
        }

        var nextCache: [String: SessionCacheEntry] = [:]
        var sessions: [GrokSession] = []
        var issues: [String] = []
        var incompleteCount = 0
        sessions.reserveCapacity(cache.count)

        for projectDir in projectDirs {
            do {
                guard try isDir(projectDir) else { continue }
            } catch {
                issues.append("\(projectDir.lastPathComponent): directory could not be inspected")
                preserveCachedSessions(under: projectDir, from: cache, into: &nextCache, sessions: &sessions)
                continue
            }
            let sessionDirs: [URL]
            do {
                sessionDirs = try fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                issues.append(
                    "\(projectDir.lastPathComponent): \(error.localizedDescription)"
                )
                preserveCachedSessions(
                    under: projectDir,
                    from: cache,
                    into: &nextCache,
                    sessions: &sessions
                )
                continue
            }

            for sessionDir in sessionDirs {
                do {
                    guard try isDir(sessionDir) else { continue }
                } catch {
                    issues.append("\(sessionDir.lastPathComponent): directory could not be inspected")
                    preserveCachedSessions(under: sessionDir, from: cache, into: &nextCache, sessions: &sessions)
                    let path = sessionDir.standardizedFileURL.path
                    if nextCache[path] == nil, let entry = cache[path] {
                        nextCache[path] = entry
                        sessions.append(entry.session)
                    }
                    continue
                }
                switch loadSession(
                    at: sessionDir,
                    cache: cache,
                    ignoringCache: ignoringCache,
                    contentReader: contentReader
                ) {
                case .loaded(let path, let entry):
                    nextCache[path] = entry
                    sessions.append(entry.session)
                case .failed(let path, let reason):
                    issues.append("\(sessionDir.lastPathComponent): \(reason)")
                    if let cached = cache[path] {
                        nextCache[path] = cached
                        sessions.append(cached.session)
                    }
                case .unrecognized(let path):
                    incompleteCount += 1
                    coverage.unrecognizedGrokDirectories.insert(path)
                    if let cached = cache[path] {
                        nextCache[path] = cached
                        sessions.append(cached.session)
                    }
                }
            }
        }

        sessions.sort(by: Self.isNewer)
        if !issues.isEmpty { coverage.uncertainRoots.insert(rootPath) }
        if incompleteCount > 0 {
            coverage.notices[rootPath] =
                "Grok history: \(incompleteCount) session summary file(s) are missing, incomplete or unsupported. Saved conversations are kept."
        }
        return Result(
            sessions: sessions,
            cache: nextCache,
            loadError: issueMessage(issues), coverage: coverage
        )
    }

    static func parse(
        data: Data,
        directory: URL,
        fileModificationDate: Date
    ) -> GrokSession? {
        let dto: SummaryDTO
        do {
            dto = try JSONDecoder().decode(SummaryDTO.self, from: data)
        } catch {
            return nil
        }
        guard let id = dto.info?.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
        else {
            return nil
        }
        guard let cwd = dto.info?.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty
        else {
            return nil
        }

        let messageCount = dto.numChatMessages ?? dto.numMessages ?? 0
        return GrokSession(
            id: id,
            cwd: cwd,
            summary: dto.sessionSummary ?? "",
            createdAt: SessionTimestamp.parse(dto.createdAt) ?? fileModificationDate,
            updatedAt: SessionTimestamp.parse(dto.updatedAt) ?? fileModificationDate,
            messageCount: messageCount,
            modelID: dto.currentModelId,
            agentName: dto.agentName,
            reasoningEffort: dto.reasoningEffort,
            kind: dto.sessionKind,
            directory: directory
        )
    }

    static func isNewer(_ lhs: GrokSession, _ rhs: GrokSession) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id < rhs.id
    }

    static func matches(
        _ session: GrokSession,
        query: String,
        displayedTitle: String? = nil
    ) -> Bool {
        guard let query = SearchQuery(query) else { return true }
        return matches(
            SearchKey(session), query: query, foldedDisplayedTitle: displayedTitle.map(foldedTitle))
    }

    /// A session's search fields, folded once when the session list changes.
    struct SearchKey: Sendable {
        /// `session.title` as it is, to spot a displayed title that is not a rename.
        let title: String
        let foldedTitle: String
        /// Folded project name, `~` path, and cwd.
        let foldedPaths: [String]

        init(_ session: GrokSession, projectName: String? = nil) {
            let name = projectName ?? session.projectName
            let summary = session.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            title = summary.isEmpty ? "Untitled session in \(name)" : summary
            foldedTitle = SessionScanner.foldedTitle(title)
            foldedPaths = [name, session.displayPath, session.cwd]
                .map(SearchMatchHighlight.fold)
        }
    }

    /// Resolve shared project display paths once while publishing a list.
    static func searchKeys(for sessions: [GrokSession]) -> [SearchKey] {
        var names: [String: String] = [:]
        return sessions.map { session in
            let name = names[session.cwd] ?? session.projectName
            names[session.cwd] = name
            return SearchKey(session, projectName: name)
        }
    }

    /// A non-empty query, folded once per search.
    struct SearchQuery: Sendable {
        let folded: String
        /// Folded words; each must occur in some field.
        let terms: [String]

        init?(_ query: String) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            folded = SearchMatchHighlight.fold(trimmed)
            terms = trimmed.split(whereSeparator: \.isWhitespace).map {
                SearchMatchHighlight.fold(String($0))
            }
        }
    }

    /// Closest title first: exact, prefix, every term at a word start, contains,
    /// then folder or path. Category boosts only break ties within a rank.
    /// Titles compare without case. Transcript text is not a field.
    enum SearchRank: Int, Sendable {
        case exactTitle = 0
        case titlePrefix = 1
        case titleWordStart = 2
        case titleContains = 3
        case folderOrPath = 4
    }

    /// Shared search ordering for conversation lists. An empty query keeps the
    /// published newest-first list without evaluating either caller closure.
    static func search(
        _ query: String,
        sessions: [GrokSession],
        keys: [SearchKey],
        boost: ((GrokSession) -> Int)? = nil,
        displayedTitle: ((GrokSession) -> String)? = nil
    ) -> [GrokSession] {
        guard let query = SearchQuery(query) else { return sessions }
        return zip(sessions, keys)
            .compactMap { session, key -> (session: GrokSession, rank: SearchRank, boost: Int)? in
                guard let rank = searchRank(key, query: query, displayedTitle: displayedTitle?(session)) else {
                    return nil
                }
                return (session, rank, boost?(session) ?? 0)
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank.rawValue < rhs.rank.rawValue }
                if lhs.boost != rhs.boost { return lhs.boost > rhs.boost }
                if lhs.session.updatedAt != rhs.session.updatedAt {
                    return lhs.session.updatedAt > rhs.session.updatedAt
                }
                // Sidebar IDs preserve legacy Grok preferences, so compare the
                // explicit provider too. Folder breaks duplicate native-ID ties.
                let left = lhs.session.reference
                let right = rhs.session.reference
                if left.provider != right.provider { return left.provider.rawValue < right.provider.rawValue }
                if left.sessionID != right.sessionID { return left.sessionID < right.sessionID }
                return left.cwd < right.cwd
            }
            .map(\.session)
    }

    static func searchRank(
        _ key: SearchKey,
        query: SearchQuery,
        displayedTitle: String? = nil
    ) -> SearchRank? {
        let displayed = displayedTitle.map { $0 == key.title ? key.foldedTitle : foldedTitle($0) }
        var best: SearchRank?
        for candidate in [displayed, key.foldedTitle] {
            guard let candidate, let rank = titleRank(candidate, query: query) else { continue }
            if let current = best, rank.rawValue >= current.rawValue { continue }
            best = rank
        }
        if let best { return best }
        return matches(key, query: query, foldedDisplayedTitle: displayed) ? .folderOrPath : nil
    }

    private static func matches(
        _ key: SearchKey,
        query: SearchQuery,
        foldedDisplayedTitle: String?
    ) -> Bool {
        query.terms.allSatisfy { term in
            foldedDisplayedTitle.map { holds($0, term) } == true || holds(key.foldedTitle, term)
                || key.foldedPaths.contains { holds($0, term) }
        }
    }

    private static func titleRank(_ title: String, query: SearchQuery) -> SearchRank? {
        if title.isEmpty || query.folded.isEmpty { return nil }
        if title == query.folded { return .exactTitle }
        if title.hasPrefix(query.folded) { return .titlePrefix }
        if query.terms.allSatisfy({ startsWord(in: title, term: $0) }) { return .titleWordStart }
        if title.contains(query.folded) { return .titleContains }
        if query.terms.allSatisfy({ holds(title, $0) }) { return .titleContains }
        return nil
    }

    /// A folded term starts a word at index zero or after a character that is
    /// neither a Unicode letter nor a number. Check later occurrences too.
    private static func startsWord(in title: String, term: String) -> Bool {
        guard !term.isEmpty else { return false }
        var start = title.startIndex
        while let hit = title.range(of: term, range: start..<title.endIndex) {
            if hit.lowerBound == title.startIndex { return true }
            let previous = title[title.index(before: hit.lowerBound)]
            if !previous.isLetter && !previous.isNumber { return true }
            start = title.index(after: hit.lowerBound)
        }
        return false
    }

    private static func foldedTitle(_ title: String) -> String {
        SearchMatchHighlight.fold(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Both sides already folded. An empty term is no hit, as in `SearchMatchHighlight.contains`.
    private static func holds(_ folded: String, _ term: String) -> Bool {
        !term.isEmpty && folded.contains(term)
    }

    private static func isDir(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard let value = values.isDirectory, let symbolic = values.isSymbolicLink else {
            throw CocoaError(.fileReadUnknown)
        }
        if symbolic { throw CocoaError(.fileReadNoPermission) }
        return value
    }

    private static func cachedSessions(_ cache: [String: SessionCacheEntry]) -> [GrokSession] {
        cache.values.map(\.session).sorted(by: isNewer)
    }

    private static func preserveCachedSessions(
        under directory: URL,
        from cache: [String: SessionCacheEntry],
        into nextCache: inout [String: SessionCacheEntry],
        sessions: inout [GrokSession]
    ) {
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        for (path, entry) in cache where path.hasPrefix(prefix) && nextCache[path] == nil {
            nextCache[path] = entry
            sessions.append(entry.session)
        }
    }

    private static func issueMessage(_ issues: [String]) -> String? {
        guard !issues.isEmpty else { return nil }
        let shown = issues.prefix(3).joined(separator: "; ")
        let remainder = issues.count - min(issues.count, 3)
        if remainder == 0 {
            return "Could not load \(issues.count) session item(s): \(shown)"
        }
        return "Could not load \(issues.count) session item(s): \(shown); and \(remainder) more"
    }

    private enum LoadResult {
        case loaded(path: String, entry: SessionCacheEntry)
        case failed(path: String, reason: String)
        case unrecognized(path: String)
    }

    private static func loadSession(
        at sessionDir: URL,
        cache: [String: SessionCacheEntry],
        ignoringCache: Bool,
        contentReader: ContentReader
    ) -> LoadResult {
        let path = sessionDir.standardizedFileURL.path
        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        let identity: SummaryIdentity
        switch inspectSummary(summaryURL) {
        case .unrecognized:
            return .unrecognized(path: path)
        case .failed(let reason):
            return .failed(path: path, reason: reason)
        case .ok(let value):
            identity = value
        }

        if !ignoringCache, let cached = cache[path], matches(cached, identity) {
            return .loaded(path: path, entry: cached)
        }

        let data: Data
        do {
            data = try contentReader.read(summaryURL)
        } catch {
            return .failed(path: path, reason: "summary.json could not be read")
        }
        if !ignoringCache, let cached = cache[path], cached.contents == data {
            return .loaded(path: path, entry: updatingIdentity(cached, identity))
        }
        guard
            let session = parse(
                data: data, directory: sessionDir, fileModificationDate: identity.modificationDate)
        else {
            return .unrecognized(path: path)
        }
        return .loaded(
            path: path,
            entry: SessionCacheEntry(
                modificationDate: identity.modificationDate,
                size: identity.size,
                inode: identity.inode,
                device: identity.device,
                changeDate: identity.changeDate,
                contents: data,
                session: session
            )
        )
    }

    private struct SummaryIdentity: Equatable {
        var modificationDate: Date
        var size: Int
        var inode: UInt64?
        var device: UInt64?
        var changeDate: Date?
    }

    private enum InspectResult {
        case ok(SummaryIdentity)
        case failed(String)
        case unrecognized
    }

    /// Metadata only: `getattrlist` plus `stat`. Never reads file contents.
    private static func inspectSummary(_ url: URL) -> InspectResult {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
            .attributeModificationDateKey,
        ]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
                [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code)
            {
                return .unrecognized
            }
            return .failed("summary.json could not be inspected")
        }
        if values.isDirectory == true || values.isRegularFile == false || values.isSymbolicLink == true {
            return .unrecognized
        }
        guard values.isRegularFile == true else {
            return .failed("summary.json file type is unavailable")
        }
        guard let modificationDate = values.contentModificationDate, let size = values.fileSize
        else {
            return .failed("summary.json metadata is unavailable")
        }

        var inode: UInt64?
        var device: UInt64?
        var st = stat()
        if stat(url.path, &st) == 0 {
            inode = st.st_ino
            device = UInt64(bitPattern: Int64(st.st_dev))
        }

        return .ok(
            SummaryIdentity(
                modificationDate: modificationDate,
                size: size,
                inode: inode,
                device: device,
                changeDate: values.attributeModificationDate
            )
        )
    }

    /// True when mtime, size, and every available extra identity field match.
    /// Inode and/or ctime are required so an atomic replace that restores mtime+size still misses.
    private static func matches(_ cached: SessionCacheEntry, _ identity: SummaryIdentity) -> Bool {
        guard cached.modificationDate == identity.modificationDate,
            cached.size == identity.size
        else {
            return false
        }

        var extra = false
        switch (cached.inode, cached.device, identity.inode, identity.device) {
        case (let cachedInode?, let cachedDevice?, let newInode?, let newDevice?):
            guard cachedInode == newInode, cachedDevice == newDevice else { return false }
            extra = true
        case (nil, nil, nil, nil):
            break
        default:
            return false
        }

        switch (cached.changeDate, identity.changeDate) {
        case (let cachedChange?, let newChange?):
            guard cachedChange == newChange else { return false }
            extra = true
        case (nil, nil):
            break
        default:
            return false
        }

        return extra
    }

    private static func updatingIdentity(
        _ cached: SessionCacheEntry,
        _ identity: SummaryIdentity
    ) -> SessionCacheEntry {
        var next = cached
        next.modificationDate = identity.modificationDate
        next.size = identity.size
        next.inode = identity.inode
        next.device = identity.device
        next.changeDate = identity.changeDate
        return next
    }
}

private struct SummaryDTO: Decodable, Sendable {
    struct Info: Decodable, Sendable {
        var id: String?
        var cwd: String?
    }

    var info: Info?
    var sessionSummary: String?
    var createdAt: String?
    var updatedAt: String?
    var numMessages: Int?
    var numChatMessages: Int?
    var currentModelId: String?
    var agentName: String?
    var reasoningEffort: String?
    var sessionKind: String?

    enum CodingKeys: String, CodingKey {
        case info
        case sessionSummary = "session_summary"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case numMessages = "num_messages"
        case numChatMessages = "num_chat_messages"
        case currentModelId = "current_model_id"
        case agentName = "agent_name"
        case reasoningEffort = "reasoning_effort"
        case sessionKind = "session_kind"
    }
}
