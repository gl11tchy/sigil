import Foundation
import Testing

@testable import SigilKit

struct TaskLedgerStoreTests {
    @Test
    func independentStoreInstancesRereadBeforeEveryMutation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let a = TaskLedgerStore(url: fixture.url)
        let b = TaskLedgerStore(url: fixture.url)
        #expect(a.read().ledger.entries.isEmpty && b.read().ledger.entries.isEmpty)
        let first = try a.transaction { try $0.start(registration()) }
        let second = try b.transaction { try $0.start(registration()) }
        try a.transaction { try $0.setMetadata(taskID: first.taskID, title: "Changed", archivedAt: nil) }
        let readback = TaskLedgerStore(url: fixture.url).read()
        #expect(readback.problem == nil)
        #expect(readback.ledger.entries.map(\.taskID) == [first.taskID, second.taskID])
        #expect(readback.ledger.entries.first?.title == "Changed")
    }

    @Test
    func simultaneousIndependentInstancesKeepEveryTask() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for round in 0..<8 {
            let url = fixture.root.appendingPathComponent("round-\(round).json")
            let start = ConcurrentStart()
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        await start.waitForBoth()
                        return try TaskLedgerStore(url: url).transaction { try $0.start(registration()) }.taskID
                    }
                }
                var ids = Set<String>()
                for try await id in group { ids.insert(id) }
                #expect(ids.count == 2)
                let status = TaskLedgerStore(url: url).read()
                #expect(status.problem == nil)
                #expect(Set(status.ledger.entries.map(\.taskID)) == ids)
            }
        }
    }

    @Test(arguments: TaskLedgerStore.CommitPhase.allCases)
    func interruptedCommitCannotRebuildOnlyFromLegacy(phase: TaskLedgerStore.CommitPhase) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let initial = TaskLedgerStore(url: fixture.url)
        let old = try initial.transaction { try $0.start(registration()) }
        let pending = registration()
        let failing = TaskLedgerStore(
            url: fixture.url,
            beforeCommit: { observed in
                if observed == phase { throw InjectedFailure() }
            })
        #expect(throws: (any Error).self) { try failing.transaction { try $0.start(pending) } }
        let restarted = TaskLedgerStore(url: fixture.url)
        let status = restarted.read()
        #expect(status.ledger.entries.contains(where: { $0.taskID == old.taskID }))
        if phase == .prepared {
            #expect(status.problem == nil)
            #expect(status.ledger.entries.count == 1)
        } else if phase == .backupReplaced {
            #expect(status.problem == nil)
            #expect(status.ledger.entries.contains(where: { $0.taskID == pending.taskID }))
        } else {
            #expect(status.problem != nil && status.canRecover)
            let primary = try Data(contentsOf: fixture.url)
            #expect(throws: (any Error).self) {
                try restarted.transaction { try $0.migrate(legacyIDs: ["legacy-only"], resolved: []) }
            }
            #expect(try Data(contentsOf: fixture.url) == primary)
            try restarted.recover()
            let recovered = restarted.read()
            #expect(recovered.problem == nil)
            #expect(Set(recovered.ledger.entries.map(\.taskID)) == [old.taskID, pending.taskID])
        }
    }

    @Test
    func migrationRetriesAfterARejectedWriteWithoutRegeneratingAnExistingTask() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TaskLedgerStore(url: fixture.url)
        let known = TaskLedger.LegacyConversation(
            conversation: .init(provider: .codex, sessionID: "known", cwd: "/generated/project"),
            projectPath: "/generated/project")
        let failing = TaskLedgerStore(url: fixture.url, beforeCommit: { _ in throw InjectedFailure() })
        #expect(throws: (any Error).self) {
            try failing.transaction { try $0.migrate(legacyIDs: ["codex:known", "unknown"], resolved: [known]) }
        }
        #expect(store.read().ledger.entries.isEmpty)
        try store.transaction { try $0.migrate(legacyIDs: ["codex:known", "unknown"], resolved: [known]) }
        let original = store.read().ledger
        try TaskLedgerStore(url: fixture.url).transaction {
            try $0.migrate(legacyIDs: ["codex:known", "unknown"], resolved: [known])
        }
        #expect(store.read().ledger == original)
        #expect(original.unresolvedLegacyIDs == ["unknown"])
    }

    @Test
    func corruptPrimaryRetainsLatestBackupAndOffersExplicitRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TaskLedgerStore(url: fixture.url)
        try store.transaction { try $0.migrate(legacyIDs: ["old-unknown"], resolved: []) }
        let later = try store.transaction { try $0.start(registration()) }
        let backupURL = fixture.url.appendingPathExtension("backup")
        let backup = try Data(contentsOf: backupURL)
        let corrupt = Data("{ interrupted corrupt bytes".utf8)
        try corrupt.write(to: fixture.url)
        let read = store.read()
        #expect(read.problem != nil && read.canRecover)
        #expect(read.ledger.entries.map(\.taskID) == [later.taskID])
        #expect(throws: (any Error).self) {
            try store.transaction { try $0.migrate(legacyIDs: ["old-unknown"], resolved: []) }
        }
        #expect(try Data(contentsOf: fixture.url) == corrupt)
        #expect(try Data(contentsOf: backupURL) == backup)
        try store.recover()
        #expect(store.read().problem == nil)
        #expect(store.read().ledger.entries.map(\.taskID) == [later.taskID])
        let preserved = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("recovery-") }
        #expect(try preserved.contains(where: { try Data(contentsOf: $0) == corrupt }))
    }

    @Test
    func staleBackupWithoutMatchingReceiptCannotOverwriteUnknownPostMigrationTasks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TaskLedgerStore(url: fixture.url)
        try store.transaction { try $0.start(registration()) }
        let stale = try Data(contentsOf: fixture.url.appendingPathExtension("backup"))
        try store.transaction { try $0.start(registration()) }
        try stale.write(to: fixture.url.appendingPathExtension("backup"))
        try Data("corrupt newest primary".utf8).write(to: fixture.url)
        let status = store.read()
        #expect(status.problem != nil && !status.canRecover)
        #expect(throws: (any Error).self) { try store.recover() }
        #expect(try Data(contentsOf: fixture.url.appendingPathExtension("backup")) == stale)
    }

    @Test
    func futureVersionPreservesFilesAndDisablesDowngradeRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TaskLedgerStore(url: fixture.url)
        try store.transaction { try $0.start(registration()) }
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any])
        envelope["version"] = 999
        let future = try JSONSerialization.data(withJSONObject: envelope)
        try future.write(to: fixture.url)
        let status = store.read()
        #expect(status.problem != nil && !status.canRecover)
        #expect(throws: (any Error).self) { try store.transaction { try $0.start(registration()) } }
        #expect(throws: (any Error).self) { try store.recover() }
        #expect(try Data(contentsOf: fixture.url) == future)
    }

    @Test
    func aSymlinkDestinationCannotChangeAnotherFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("unrelated.json")
        let original = Data("keep these bytes".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)
        let store = TaskLedgerStore(url: fixture.url)
        #expect(store.read().problem != nil)
        #expect(throws: (any Error).self) { try store.transaction { try $0.start(registration()) } }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test
    func transactionCannotRemovePreviouslySavedTasksOrLegacyReferences() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TaskLedgerStore(url: fixture.url)
        try store.transaction {
            _ = try $0.start(registration())
            try $0.migrate(legacyIDs: ["unknown-reference"], resolved: [])
        }
        let original = store.read().ledger
        #expect(throws: (any Error).self) { try store.transaction { $0 = TaskLedger() } }
        #expect(store.read().ledger == original)
    }

    private actor ConcurrentStart {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func waitForBoth() async {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                if waiting.count == 2 {
                    let ready = waiting
                    waiting.removeAll()
                    for continuation in ready { continuation.resume() }
                }
            }
        }
    }
    private struct InjectedFailure: Error {}
    private struct Fixture {
        let root: URL
        var url: URL { root.appendingPathComponent("tasks.json") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

private func registration() -> TaskLedger.Registration {
    .init(
        taskID: UUID().uuidString.lowercased(), provider: .codex, projectPath: "/generated/project",
        workspacePath: "/generated/project", branch: nil, conversation: nil, createdAt: Date())
}
