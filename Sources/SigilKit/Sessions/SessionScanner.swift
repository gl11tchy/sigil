import Foundation

struct SessionCacheEntry: Sendable, Equatable {
    var modificationDate: Date
    var size: Int
    /// The exact bytes used to build `session`.
    ///
    /// File size and modification time are not reliable cache identities: writers can preserve
    /// both while replacing a summary. Keeping the small summary body lets us compare it exactly
    /// and skip decoding without ever returning stale content.
    var contents: Data
    var session: GrokSession
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
    struct Result: Sendable {
        var sessions: [GrokSession]
        var cache: [String: SessionCacheEntry]
        var loadError: String?
    }

    static func scan(
        root: URL,
        cache: [String: SessionCacheEntry],
        ignoringCache: Bool = false
    ) -> Result {
        let fm = FileManager()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return Result(
                sessions: cachedSessions(cache),
                cache: cache,
                loadError: "Sessions directory does not exist: \(root.path)"
            )
        }
        guard isDirectory.boolValue else {
            return Result(
                sessions: cachedSessions(cache),
                cache: cache,
                loadError: "Sessions path is not a directory: \(root.path)"
            )
        }

        let projectDirs: [URL]
        do {
            projectDirs = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return Result(
                sessions: cachedSessions(cache),
                cache: cache,
                loadError: "Could not read sessions directory: \(error.localizedDescription)"
            )
        }

        var nextCache: [String: SessionCacheEntry] = [:]
        var sessions: [GrokSession] = []
        var issues: [String] = []
        sessions.reserveCapacity(cache.count)

        for projectDir in projectDirs {
            guard isDir(projectDir) else { continue }
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
                guard isDir(sessionDir) else { continue }
                switch loadSession(
                    at: sessionDir,
                    cache: cache,
                    ignoringCache: ignoringCache
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
                }
            }
        }

        sessions.sort(by: Self.isNewer)
        return Result(
            sessions: sessions,
            cache: nextCache,
            loadError: issueMessage(issues)
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
            directory: directory
        )
    }

    static func isNewer(_ lhs: GrokSession, _ rhs: GrokSession) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id < rhs.id
    }

    static func matches(_ session: GrokSession, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let needle = fold(trimmed)
        return fold(session.title).contains(needle)
            || fold(session.projectName).contains(needle)
            || fold(session.cwd).contains(needle)
    }

    static func grouped(_ sessions: [GrokSession]) -> [(cwd: String, sessions: [GrokSession])] {
        var groups: [String: [GrokSession]] = [:]
        var order: [String] = []
        for session in sessions {
            if groups[session.cwd] == nil {
                order.append(session.cwd)
                groups[session.cwd] = [session]
            } else {
                groups[session.cwd]?.append(session)
            }
        }
        return order.map { (cwd: $0, sessions: groups[$0] ?? []) }
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isDir(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
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
    }

    private static func loadSession(
        at sessionDir: URL,
        cache: [String: SessionCacheEntry],
        ignoringCache: Bool
    ) -> LoadResult {
        let path = sessionDir.standardizedFileURL.path
        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
        ]
        let values: URLResourceValues
        do {
            values = try summaryURL.resourceValues(forKeys: keys)
        } catch {
            return .failed(path: path, reason: "summary.json could not be inspected")
        }
        if values.isDirectory == true {
            return .failed(path: path, reason: "summary.json is a directory")
        }
        guard values.isRegularFile == true else {
            return .failed(path: path, reason: "summary.json is not a regular file")
        }
        guard let modificationDate = values.contentModificationDate, let size = values.fileSize
        else {
            return .failed(path: path, reason: "summary.json metadata is unavailable")
        }

        let data: Data
        do {
            data = try Data(contentsOf: summaryURL)
        } catch {
            return .failed(path: path, reason: "summary.json could not be read")
        }
        if !ignoringCache,
            let cached = cache[path],
            cached.modificationDate == modificationDate,
            cached.size == size,
            cached.contents == data
        {
            return .loaded(path: path, entry: cached)
        }
        guard
            let session = parse(
                data: data, directory: sessionDir, fileModificationDate: modificationDate)
        else {
            return .failed(path: path, reason: "summary.json is invalid")
        }
        return .loaded(
            path: path,
            entry: SessionCacheEntry(
                modificationDate: modificationDate,
                size: size,
                contents: data,
                session: session
            )
        )
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
    }
}
