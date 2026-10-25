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
}
