import Foundation
import Testing

@testable import SigilKit

struct TaskLedgerTests {
    @Test
    func taskIdentitySurvivesSerializationBeforeNativeIdentityExists() throws {
        let taskID = UUID().uuidString.lowercased()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = TaskLedger()
        let entry = try ledger.start(
            .init(
                taskID: taskID, provider: .codex, projectPath: "/generated/project",
                workspacePath: "/generated/project", branch: nil, conversation: nil, createdAt: started))
        #expect(entry.taskID == taskID)
        #expect(entry.conversationID == nil)
        var restored = try JSONDecoder().decode(TaskLedger.self, from: JSONEncoder().encode(ledger))
        let replacement = try restored.start(
            .init(
                taskID: taskID, provider: .codex, projectPath: "/generated/project",
                workspacePath: "/generated/project", branch: nil, conversation: nil,
                createdAt: started.addingTimeInterval(60)))
        #expect(replacement == entry)
        #expect(restored.entries == [entry])
    }

    @Test
    func qualifiedConversationIdentitySharesATaskWithoutCrossingProvidersOrWorkspaces() throws {
        var ledger = TaskLedger()
        let original = try ledger.start(registration(conversation: reference()))
        let secondProcess = try ledger.start(registration(conversation: reference()))
        #expect(secondProcess.taskID == original.taskID)
        let claude = try ledger.start(registration(provider: .claudeCode, conversation: reference(.claudeCode)))
        let elsewhere = try ledger.start(
            registration(workspace: "/generated/elsewhere", conversation: reference(cwd: "/generated/elsewhere")))
        #expect(Set([original.taskID, claude.taskID, elsewhere.taskID]).count == 3)
        #expect(ledger.entries.count == 3)
    }

    @Test
    func aNativeBindingCannotRetargetAnExistingTask() throws {
        var ledger = TaskLedger()
        let task = try ledger.start(registration())
        try ledger.bind(taskID: task.taskID, conversation: reference())
        #expect(ledger.entries.first?.taskID == task.taskID)
        #expect(ledger.entries.first?.conversationID == "generated-session")
        #expect(throws: (any Error).self) {
            try ledger.bind(taskID: task.taskID, conversation: reference(.claudeCode))
        }
        #expect(throws: (any Error).self) {
            try ledger.bind(taskID: task.taskID, conversation: reference(cwd: "/generated/other"))
        }
        #expect(throws: (any Error).self) {
            try ledger.bind(
                taskID: task.taskID,
                conversation: .init(provider: .codex, sessionID: "another", cwd: "/generated/project"))
        }
        #expect(ledger.entries.first?.conversationID == "generated-session")
    }

    @Test
    func reopeningAQualifiedTaskRefreshesItsObservedBranchWithoutANewIdentity() throws {
        var ledger = TaskLedger()
        var original = registration(conversation: reference())
        original.branch = "sigil/first"
        let entry = try ledger.start(original)
        var reopened = registration(conversation: reference())
        reopened.branch = "sigil/renamed"
        let result = try ledger.start(reopened)
        #expect(result.taskID == entry.taskID && result.createdAt == entry.createdAt)
        #expect(result.branch == "sigil/renamed")
        #expect(ledger.entries.count == 1)
    }

    @Test
    func duplicateLateBindingsRequireAnExplicitTaskInsteadOfGuessing() throws {
        var ledger = TaskLedger()
        let a = try ledger.start(registration())
        let b = try ledger.start(registration())
        try ledger.bind(taskID: a.taskID, conversation: reference())
        try ledger.bind(taskID: b.taskID, conversation: reference())
        #expect(throws: (any Error).self) { try ledger.start(registration(conversation: reference())) }
        var explicit = registration(conversation: reference())
        explicit.taskID = a.taskID
        #expect(try ledger.start(explicit).taskID == a.taskID)
    }

    @Test
    func repeatedMigrationRetainsUnknownIDsAndPostMigrationTasksAndMetadata() throws {
        var ledger = TaskLedger()
        let known = TaskLedger.LegacyConversation(
            conversation: reference(), projectPath: "/generated/project", title: "Saved name",
            archivedAt: Date(timeIntervalSince1970: 100))
        let firstDate = Date(timeIntervalSince1970: 200)
        try ledger.migrate(
            legacyIDs: ["codex:generated-session", "unknown:retained"], resolved: [known], now: firstDate)
        let migrated = try #require(ledger.entries.first)
        #expect(migrated.title == "Saved name" && migrated.archivedAt != nil)
        #expect(migrated.createdAt == firstDate)
        let startedLater = try ledger.start(registration())
        try ledger.setMetadata(taskID: migrated.taskID, title: "New name", archivedAt: nil)
        try ledger.migrate(
            legacyIDs: ["codex:generated-session"], resolved: [known], now: firstDate.addingTimeInterval(900))
        #expect(ledger.entries.map(\.taskID) == [migrated.taskID, startedLater.taskID])
        #expect(ledger.entries.first?.title == "New name" && ledger.entries.first?.archivedAt == nil)
        #expect(ledger.entries.first?.createdAt == firstDate)
        #expect(ledger.unresolvedLegacyIDs == ["unknown:retained"])
        let roundTrip = try JSONDecoder().decode(TaskLedger.self, from: JSONEncoder().encode(ledger))
        #expect(roundTrip == ledger)
    }

    @Test
    func missingWorktreeAndCanonicalAliasesDoNotEraseOrDuplicateTasks() throws {
        var ledger = TaskLedger()
        let workspace = "/generated/deleted-worktree"
        var request = registration(workspace: workspace)
        request.branch = "sigil/generated"
        let entry = try ledger.start(request)
        #expect(entry.workspacePath == workspace && entry.branch == "sigil/generated")
        request.workspacePath = "/generated/./deleted-worktree"
        #expect(try ledger.start(request) == entry)
        #expect(ledger.entries.count == 1)
    }

    @Test
    func malformedTaskAndPathInputsAreRejectedWithoutMutation() throws {
        var ledger = TaskLedger()
        var input = registration()
        input.taskID = "not-a-uuid"
        #expect(throws: (any Error).self) { try ledger.start(input) }
        input = registration()
        input.workspacePath = "relative"
        #expect(throws: (any Error).self) { try ledger.start(input) }
        #expect(ledger.entries.isEmpty)
    }

    @Test
    func aMissingWorkspaceKeepsTheSameSystemAliasIdentity() throws {
        let missing = "/tmp/ledger-missing-\(UUID().uuidString)"
        var ledger = TaskLedger()
        let first = try ledger.start(registration(workspace: missing, conversation: reference(cwd: missing)))
        let physical = "/private" + missing
        let second = try ledger.start(registration(workspace: physical, conversation: reference(cwd: physical)))
        #expect(first.taskID == second.taskID)
        #expect(first.workspacePath == physical)
        #expect(ledger.entries.count == 1)
    }

    private func reference(_ provider: CLIProvider = .codex, cwd: String = "/generated/project")
        -> ProviderSessionReference
    {
        .init(provider: provider, sessionID: "generated-session", cwd: cwd)
    }

    private func registration(
        provider: CLIProvider = .codex, workspace: String = "/generated/project",
        conversation: ProviderSessionReference? = nil
    ) -> TaskLedger.Registration {
        .init(
            taskID: UUID().uuidString.lowercased(), provider: provider,
            projectPath: "/generated/project", workspacePath: workspace, branch: nil,
            conversation: conversation, createdAt: Date(timeIntervalSince1970: 200))
    }
}
