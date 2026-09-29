import Foundation

// The workbench's five concepts, kept apart as docs/ux/EXPERIENCE.md defines
// them. Only projects and tasks are navigation; a task's workspace, live
// process and verified conversation are facts about it.

/// A repository or folder the user works in.
public struct WorkbenchProject: Identifiable, Hashable, Sendable {
    /// The folder's canonical path. A Sigil worktree resolves to its project.
    public let id: String
    public var name: String

    public init(path: String, name: String? = nil) {
        id = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    }

    public var path: String { id }
}

/// The checkout where a task's files change.
public struct WorkbenchWorkspace: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The project folder itself.
        case projectFolder
        /// A Sigil worktree on its own branch.
        case worktree(branch: String)
    }

    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }

    /// What the context header shows after the project name.
    public var label: String {
        switch kind {
        case .projectFolder: "project folder"
        case .worktree(let branch): branch
        }
    }
}

/// Whether the provider's own conversation is known to belong to the task.
public enum ConversationEvidence: Hashable, Sendable {
    /// The history adapter matched this native session ID to the task.
    case verified(sessionID: String)
    /// The provider picks its ID itself and it has not been matched yet.
    case pending
    /// The provider keeps no history Sigil can read.
    case none
}

/// What runs for the task now. A tab ID is not a conversation ID, and a live
/// process does not prove a finished turn.
public enum TaskProcess: Equatable, Sendable {
    case live(SessionLifecycleState)
    /// Nothing runs; the task is known from history only.
    case notRunning
    /// The provider CLI cannot start. The saved reference stays.
    case providerUnavailable(problem: String)
    /// The workspace folder no longer exists.
    case workspaceMissing
}

/// What, if anything, a task asks of the user. Only evidence sets it.
public enum TaskAttention: Hashable, Sendable {
    case none
    /// A provider-confirmed turn finished and the user has not looked yet.
    case finished
    case needsInput
    case stopped
    case failed
    /// It cannot run: the provider is missing or the workspace is gone.
    case blocked

    public var needsUser: Bool { self != .none }

    public var label: String {
        switch self {
        case .none: "No action needed"
        case .finished: "Finished"
        case .needsInput: "Needs input"
        case .stopped: "Stopped"
        case .failed: "Failed"
        case .blocked: "Blocked"
        }
    }
}

/// One piece of work: one workspace, one provider, one conversation lineage.
public struct WorkbenchTask: Identifiable, Equatable, Sendable {
    /// Sigil's own identity for the task, stable before the provider has one.
    public let id: String
    public let projectID: String
    public var title: String
    public let provider: CLIProvider
    public var workspace: WorkbenchWorkspace
    public var process: TaskProcess
    public var conversation: ConversationEvidence
    public let createdAt: Date
    public var hasUnseenFinish: Bool
    public var workingSince: Date?

    public init(
        id: String, projectID: String, title: String, provider: CLIProvider,
        workspace: WorkbenchWorkspace, process: TaskProcess, conversation: ConversationEvidence,
        createdAt: Date, hasUnseenFinish: Bool = false, workingSince: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.provider = provider
        self.workspace = workspace
        self.process = process
        self.conversation = conversation
        self.createdAt = createdAt
        self.hasUnseenFinish = hasUnseenFinish
        self.workingSince = workingSince
    }

    public var attention: TaskAttention {
        switch process {
        case .providerUnavailable, .workspaceMissing:
            return .blocked
        case .notRunning:
            return .none
        case .live(let state):
            switch state {
            case .idle: return hasUnseenFinish ? .finished : .none
            case .waitingForApproval: return .needsInput
            case .interrupted: return .stopped
            case .failed: return .failed
            case .exited: return state.endedInFailure ? .failed : .none
            case .starting, .working, .unknown, .disconnected: return .none
            }
        }
    }

    /// The lifecycle state when a process runs or has run in this window.
    public var lifecycle: SessionLifecycleState? {
        if case .live(let state) = process { return state }
        return nil
    }
}
