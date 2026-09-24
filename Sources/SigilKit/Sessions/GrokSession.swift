import Foundation

/// One Grok Build conversation, as recorded in `<session-dir>/summary.json`.
public struct GrokSession: Identifiable, Hashable, Sendable {
    public let id: String
    /// Absolute working directory the session was started in.
    public let cwd: String
    /// The CLI's own summary line; empty for sessions that never got one.
    public let summary: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int
    public let modelID: String?
    public let agentName: String?
    public let reasoningEffort: String?
    /// CLI `session_kind`. `"subagent"` is a child of another conversation.
    public let kind: String?
    /// On-disk location, used to watch the session and to export its transcript.
    public let directory: URL

    public init(
        id: String,
        cwd: String,
        summary: String,
        createdAt: Date,
        updatedAt: Date,
        messageCount: Int,
        modelID: String?,
        agentName: String?,
        reasoningEffort: String?,
        kind: String? = nil,
        directory: URL
    ) {
        self.id = id
        self.cwd = cwd
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.modelID = modelID
        self.agentName = agentName
        self.reasoningEffort = reasoningEffort
        self.kind = kind
        self.directory = directory
    }

    /// Child of a parent chat: workflow / spawn_subagent. Hidden from the sidebar by default.
    public var isSubagent: Bool {
        kind == "subagent"
    }

    /// The CLI summary, or a folder fallback when the CLI wrote none.
    /// The sidebar may show a user-chosen name instead; see `ConversationNaming`.
    public var title: String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Untitled session in \(projectName)"
    }

    /// The folder the sidebar groups this session under: the project a Sigil
    /// worktree was made from, else `cwd`.
    public var projectPath: String { SigilWorktree.projectPath(of: cwd) ?? cwd }

    /// Last path component of `projectPath`, used to group the sidebar by project.
    public var projectName: String {
        let path = projectPath
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// `cwd` with the user's home replaced by `~`.
    public var displayPath: String { Self.abbreviated(cwd) }

    /// `projectPath` with the user's home replaced by `~`.
    public var projectDisplayPath: String { Self.abbreviated(projectPath) }

    private static func abbreviated(_ path: String) -> String {
        let home = homePath
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
}
