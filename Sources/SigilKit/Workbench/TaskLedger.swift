import Foundation

/// Sigil's durable task identity, independent of a terminal or provider process.
/// Native references passed here must already have the adapter's identity proof;
/// deserializing an old reference never authorizes a live process binding.
public struct TaskLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let taskID: String
        public let provider: CLIProvider
        public let projectPath: String
        public let workspacePath: String
        public internal(set) var branch: String?
        public internal(set) var conversationID: String?
        public let createdAt: Date
        public internal(set) var archivedAt: Date?
        public internal(set) var title: String?
        public var id: String { taskID }
        public var conversation: ProviderSessionReference? {
            conversationID.map { .init(provider: provider, sessionID: $0, cwd: workspacePath) }
        }
    }

    public struct Registration: Sendable {
        public var taskID: String
        public var provider: CLIProvider
        public var projectPath: String
        public var workspacePath: String
        public var branch: String?
        public var conversation: ProviderSessionReference?
        public var createdAt: Date

        public init(
            taskID: String, provider: CLIProvider, projectPath: String, workspacePath: String,
            branch: String?, conversation: ProviderSessionReference?, createdAt: Date
        ) {
            self.taskID = taskID
            self.provider = provider
            self.projectPath = projectPath
            self.workspacePath = workspacePath
            self.branch = branch
            self.conversation = conversation
            self.createdAt = createdAt
        }
    }

    public struct LegacyConversation: Sendable {
        public let conversation: ProviderSessionReference
        public let projectPath: String
        public let branch: String?
        public let title: String?
        public let archivedAt: Date?
        public init(
            conversation: ProviderSessionReference, projectPath: String, branch: String? = nil,
            title: String? = nil, archivedAt: Date? = nil
        ) {
            self.conversation = conversation
            self.projectPath = projectPath
            self.branch = branch
            self.title = title
            self.archivedAt = archivedAt
        }
    }

    public struct Failure: Error, LocalizedError, Equatable, Sendable {
        public let message: String
        public var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    public private(set) var entries: [Entry] = []
    /// Retain unknown IDs and the original ownership source throughout migration.
    public private(set) var legacyIDs: [String] = []
    public var unresolvedLegacyIDs: [String] {
        let known = Set(entries.compactMap { $0.conversation?.sidebarID })
        return legacyIDs.filter { !known.contains($0) }
    }

    public init() {}

    /// Keep system aliases stable even while a workspace folder is missing.
    public static func canonicalWorkspacePath(_ path: String) -> String {
        physicalSystemPath(GrokPaths.canonicalPath(path))
    }

    /// Re-registering a process does not create another task. A qualified native
    /// reference may reuse one unambiguous task; an explicit UUID resolves duplicates.
    @discardableResult
    public mutating func start(_ registration: Registration) throws -> Entry {
        let request = try normalized(registration)
        if let index = entries.firstIndex(where: { $0.taskID == request.taskID }) {
            let previous = entries[index]
            guard previous.provider == request.provider, previous.projectPath == request.projectPath,
                previous.workspacePath == request.workspacePath
            else {
                throw Failure("The saved task belongs to a different provider or workspace.")
            }
            if let conversation = request.conversation { try bind(taskID: previous.taskID, conversation: conversation) }
            if let branch = request.branch { entries[index].branch = branch }
            return entries[index]
        }
        if let reference = request.conversation {
            let matches = entries.filter { self.matches($0, reference) }
            guard matches.count <= 1 else {
                throw Failure("Several tasks reference this conversation. An explicit saved task ID is required.")
            }
            if let match = matches.first {
                guard match.projectPath == request.projectPath else {
                    throw Failure("The saved task belongs to a different project.")
                }
                return match
            }
        }
        let entry = Entry(
            taskID: request.taskID, provider: request.provider,
            projectPath: request.projectPath, workspacePath: request.workspacePath,
            branch: request.branch, conversationID: request.conversation?.sessionID,
            createdAt: request.createdAt, archivedAt: nil, title: nil)
        entries.append(entry)
        return entry
    }

    public mutating func bind(taskID: String, conversation: ProviderSessionReference) throws {
        guard let index = entries.firstIndex(where: { $0.taskID == taskID }) else {
            throw Failure("The task is missing.")
        }
        let entry = entries[index]
        guard entry.provider == conversation.provider,
            entry.workspacePath == (try Self.path(conversation.cwd)), Self.text(conversation.sessionID),
            entry.conversationID == nil || entry.conversationID == conversation.sessionID
        else {
            throw Failure("The verified conversation does not match the saved task's identity.")
        }
        entries[index].conversationID = conversation.sessionID
    }

    public mutating func setMetadata(taskID: String, title: String?, archivedAt: Date?) throws {
        guard let index = entries.firstIndex(where: { $0.taskID == taskID }) else {
            throw Failure("The task is missing.")
        }
        guard title.map(Self.text) ?? true, archivedAt.map(Self.date) ?? true else {
            throw Failure("Invalid task metadata.")
        }
        entries[index].title = title
        entries[index].archivedAt = archivedAt
    }

    /// The source IDs and their resolved entries commit together. A repeated scan
    /// can resolve unknown IDs without replacing task identity or newer metadata.
    public mutating func migrate(legacyIDs source: [String], resolved: [LegacyConversation], now: Date = Date()) throws
    {
        guard source.allSatisfy(Self.text), Self.date(now) else { throw Failure("Invalid legacy ownership source.") }
        var next = self
        var seen = Set(next.legacyIDs)
        for id in source where seen.insert(id).inserted { next.legacyIDs.append(id) }
        for item in resolved where seen.contains(item.conversation.sidebarID) {
            let reference = ProviderSessionReference(
                provider: item.conversation.provider,
                sessionID: item.conversation.sessionID,
                cwd: try Self.path(item.conversation.cwd))
            guard !next.entries.contains(where: { next.matches($0, reference) }) else { continue }
            let entry = try next.start(
                .init(
                    taskID: UUID().uuidString.lowercased(), provider: item.conversation.provider,
                    projectPath: item.projectPath, workspacePath: reference.cwd,
                    branch: item.branch, conversation: reference, createdAt: now))
            try next.setMetadata(taskID: entry.taskID, title: item.title, archivedAt: item.archivedAt)
        }
        try next.validate()
        self = next
    }

    func validate() throws {
        guard entries.count <= 100_000, legacyIDs.count <= 100_000,
            Set(entries.map(\.taskID)).count == entries.count,
            Set(legacyIDs).count == legacyIDs.count, legacyIDs.allSatisfy(Self.text)
        else {
            throw Failure("Invalid or duplicated task ledger records.")
        }
        for entry in entries {
            guard UUID(uuidString: entry.taskID)?.uuidString.lowercased() == entry.taskID,
                Self.storedPath(entry.projectPath), Self.storedPath(entry.workspacePath),
                entry.branch.map(Self.text) ?? true, entry.conversationID.map(Self.text) ?? true,
                entry.title.map(Self.text) ?? true, Self.date(entry.createdAt), entry.archivedAt.map(Self.date) ?? true
            else {
                throw Failure("Invalid task ledger entry.")
            }
        }
    }

    /// A store transaction/recovery may add identities and change metadata, but
    /// cannot discard a previously durable task, native binding or unknown ID.
    func preserves(_ previous: TaskLedger) -> Bool {
        guard Set(previous.legacyIDs).isSubset(of: Set(legacyIDs)) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.taskID, $0) })
        return previous.entries.allSatisfy { old in
            guard let new = byID[old.taskID] else { return false }
            return new.provider == old.provider && new.projectPath == old.projectPath
                && new.workspacePath == old.workspacePath && new.createdAt == old.createdAt
                && (old.conversationID == nil || old.conversationID == new.conversationID)
        }
    }

    /// Display-only union when protocol files disagree. Conflicting records stay
    /// read-only; this union is never selected as a recovery/write candidate.
    func retainingKnownRecords(from other: TaskLedger) -> TaskLedger {
        var result = self
        var tasks = Set(entries.map(\.taskID))
        for entry in other.entries where tasks.insert(entry.taskID).inserted { result.entries.append(entry) }
        var ids = Set(legacyIDs)
        for id in other.legacyIDs where ids.insert(id).inserted { result.legacyIDs.append(id) }
        return result
    }

    private func normalized(_ input: Registration) throws -> Registration {
        guard let uuid = UUID(uuidString: input.taskID), Self.date(input.createdAt), input.branch.map(Self.text) ?? true
        else {
            throw Failure("Invalid task registration.")
        }
        var result = input
        result.taskID = uuid.uuidString.lowercased()
        result.projectPath = try Self.path(input.projectPath)
        result.workspacePath = try Self.path(input.workspacePath)
        if let reference = input.conversation {
            guard reference.provider == input.provider, Self.text(reference.sessionID),
                try Self.path(reference.cwd) == result.workspacePath
            else {
                throw Failure("The verified conversation belongs to a different provider or workspace.")
            }
            result.conversation = .init(
                provider: reference.provider, sessionID: reference.sessionID, cwd: result.workspacePath)
        }
        return result
    }

    private func matches(_ entry: Entry, _ reference: ProviderSessionReference) -> Bool {
        entry.provider == reference.provider && entry.conversationID == reference.sessionID
            && entry.workspacePath == reference.cwd
    }
    private static func path(_ path: String) throws -> String {
        guard absolute(path) else { throw Failure("A task requires an absolute workspace and project path.") }
        return canonicalWorkspacePath(path)
    }
    private static func physicalSystemPath(_ path: String) -> String {
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }
    private static func storedPath(_ path: String) -> Bool {
        absolute(path) && URL(fileURLWithPath: path).standardizedFileURL.path == path
            && physicalSystemPath(path) == path
    }
    private static func absolute(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= 16_384
    }
    private static func text(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && !value.utf8.contains(0)
    }
    private static func date(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite
            && (-62_135_596_800.0...253_402_300_799.0).contains(date.timeIntervalSince1970)
    }
}
