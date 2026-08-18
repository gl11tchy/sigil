import Foundation

struct SessionCacheEntry: Sendable, Equatable {
    var modificationDate: Date
    var size: Int
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

    static func scan(root: URL, cache: [String: SessionCacheEntry]) -> Result {
        let fm = FileManager()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return Result(
                sessions: [],
                cache: [:],
                loadError: "Sessions directory does not exist: \(root.path)"
            )
        }
        guard isDirectory.boolValue else {
            return Result(
                sessions: [],
                cache: [:],
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
            return Result(sessions: [], cache: [:], loadError: error.localizedDescription)
        }

        var nextCache: [String: SessionCacheEntry] = [:]
        var sessions: [GrokSession] = []
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
                continue
            }

            for sessionDir in sessionDirs {
                guard isDir(sessionDir) else { continue }
                guard let parsed = loadSession(at: sessionDir, cache: cache) else { continue }
                nextCache[parsed.path] = parsed.entry
                sessions.append(parsed.entry.session)
            }
        }

        sessions.sort(by: Self.isNewer)
        return Result(sessions: sessions, cache: nextCache, loadError: nil)
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

    private static func loadSession(
        at sessionDir: URL,
        cache: [String: SessionCacheEntry]
    ) -> (path: String, entry: SessionCacheEntry)? {
        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
        ]
        let values: URLResourceValues
        do {
            values = try summaryURL.resourceValues(forKeys: keys)
        } catch {
            return nil
        }
        if values.isDirectory == true { return nil }
        guard values.isRegularFile == true else { return nil }
        guard let modificationDate = values.contentModificationDate, let size = values.fileSize
        else {
            return nil
        }

        let path = sessionDir.standardizedFileURL.path
        if let cached = cache[path],
            cached.modificationDate == modificationDate,
            cached.size == size
        {
            return (path, cached)
        }

        let data: Data
        do {
            data = try Data(contentsOf: summaryURL)
        } catch {
            return nil
        }
        guard let session = parse(data: data, directory: sessionDir, fileModificationDate: modificationDate)
        else {
            return nil
        }
        return (
            path,
            SessionCacheEntry(modificationDate: modificationDate, size: size, session: session)
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
