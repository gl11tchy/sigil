import Foundation
import Observation
import Testing
import os

@testable import SigilKit

struct ConversationNotesStoreTests {

    @Test @MainActor
    func outsideEditWhileTypingIsPreservedBeforeLocalTextReplacesIt() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")

        store.setNote("local draft", for: "a-1", cwd: "/tmp/one")
        try Data("outside edit".utf8).write(to: file, options: .atomic)
        store.flushNow()

        let siblings = try FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let conflicts = siblings.filter { $0.lastPathComponent.hasPrefix("a-1.conflict-") }
        #expect(conflicts.count == 1)
        if let conflict = conflicts.first {
            #expect(try String(contentsOf: conflict, encoding: .utf8) == "outside edit")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "local draft")
    }

    @Test @MainActor
    func idleNotesFollowOutsideAtomicReplacement() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        try Data("outside edit".utf8).write(
            to: noteFile(root, "a-1", "/tmp/one"), options: .atomic)
        try await Task.sleep(for: .seconds(1))
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "outside edit")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    private func conflictFiles(beside file: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(file.deletingPathExtension().lastPathComponent + ".conflict-") }
    }

    @Test @MainActor
    func equalTimestampAndSizeOutsideEditWinsWhenIdle() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("first", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        let date = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try Data("other".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        try await waitUntil { store.note(for: "a-1", cwd: "/tmp/one") == "other" }
        #expect(store.isSaved(for: "a-1", cwd: "/tmp/one"))
    }

    @Test @MainActor
    func equalTimestampAndSizeOutsideEditIsPreservedWhileDirty() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("first", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        let date = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        store.setNote("local", for: "a-1", cwd: "/tmp/one")
        try Data("other".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        store.flushNow()
        let conflict = try #require(try conflictFiles(beside: file).first)
        #expect(try String(contentsOf: conflict, encoding: .utf8) == "other")
        guard case .conflictPreserved(let reported) = store.notice(for: "a-1", cwd: "/tmp/one") else {
            Issue.record("Missing conflict notice")
            return
        }
        #expect(reported.resolvingSymlinksInPath() == conflict.resolvingSymlinksInPath())
    }

    @Test @MainActor
    func savePreservesTheLatestDiskRevisionRatherThanAnOlderRead() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        store.setNote("local draft", for: "a-1", cwd: "/tmp/one")
        try Data("outside one".utf8).write(to: file, options: .atomic)
        try Data("outside two".utf8).write(to: file, options: .atomic)
        store.flushNow()
        let conflict = try #require(try conflictFiles(beside: file).first)
        #expect(try String(contentsOf: conflict, encoding: .utf8) == "outside two")
        #expect(try String(contentsOf: file, encoding: .utf8) == "local draft")
        let relaunched = ConversationNotesStore(root: root)
        #expect(relaunched.note(for: "a-1", cwd: "/tmp/one") == "local draft")
        #expect(try String(contentsOf: conflict, encoding: .utf8) == "outside two")
    }

    @Test @MainActor
    func idleDeletionAndRecreationArePickedUp() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        try FileManager.default.removeItem(at: file)
        try await waitUntil { store.note(for: "a-1", cwd: "/tmp/one").isEmpty }
        try Data("recreated".utf8).write(to: file, options: .atomic)
        try await waitUntil { store.note(for: "a-1", cwd: "/tmp/one") == "recreated" }
    }

    @Test @MainActor
    func dirtyLocalTextSurvivesOutsideDeletion() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        store.setNote("local draft", for: "a-1", cwd: "/tmp/one")
        try FileManager.default.removeItem(at: file)
        store.flushNow()
        #expect(try String(contentsOf: file, encoding: .utf8) == "local draft")
        #expect(store.notice(for: "a-1", cwd: "/tmp/one") == .outsideDeletion)
        #expect(store.isSaved(for: "a-1", cwd: "/tmp/one"))
    }

    @Test @MainActor
    func localDeletionPreservesOutsideEdits() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        store.deleteNote(for: "a-1", cwd: "/tmp/one")
        try Data("outside".utf8).write(to: file, options: .atomic)
        store.flushNow()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let conflict = try #require(try conflictFiles(beside: file).first)
        #expect(try String(contentsOf: conflict, encoding: .utf8) == "outside")
    }

    @Test @MainActor
    func twoInstancesPreserveEachOthersQueuedEdits() async throws {
        let (first, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        first.setNote("original", for: "a-1", cwd: "/tmp/one")
        first.flushNow()
        let second = ConversationNotesStore(root: root)
        #expect(second.note(for: "a-1", cwd: "/tmp/one") == "original")
        first.setNote("first draft", for: "a-1", cwd: "/tmp/one")
        second.setNote("second draft", for: "a-1", cwd: "/tmp/one")
        try await waitUntil {
            first.isSaved(for: "a-1", cwd: "/tmp/one") && second.isSaved(for: "a-1", cwd: "/tmp/one")
        }
        let file = noteFile(root, "a-1", "/tmp/one")
        let versions =
            try conflictFiles(beside: file).map { try String(contentsOf: $0, encoding: .utf8) }
            + [String(contentsOf: file, encoding: .utf8)]
        #expect(versions.contains("first draft"))
        #expect(versions.contains("second draft"))
        let final = try String(contentsOf: file, encoding: .utf8)
        try await waitUntil {
            first.note(for: "a-1", cwd: "/tmp/one") == final && second.note(for: "a-1", cwd: "/tmp/one") == final
        }
    }

    @Test @MainActor
    func editsDuringAnInFlightSaveKeepTheNewestLocalAndOutsideText() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        let ready = OSAllocatedUnfairLock(initialState: false)
        let outsideSaved = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        // A real coordinated editor holds the file while Sigil queues its save.
        DispatchQueue.global(qos: .utility).async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &error) { url in
                ready.withLock { $0 = true }
                guard release.wait(timeout: .now() + 3) == .success else { return }
                do {
                    try Data("outside while queued".utf8).write(to: url, options: .atomic)
                    outsideSaved.withLock { $0 = true }
                } catch {}
            }
        }
        try await waitUntil { ready.withLock { $0 } }
        store.setNote("first local", for: "a-1", cwd: "/tmp/one")
        try await Task.sleep(for: ConversationNotesStore.flushDelay + .milliseconds(100))
        #expect(!store.isSaved(for: "a-1", cwd: "/tmp/one"))
        store.setNote("newest local", for: "a-1", cwd: "/tmp/one")
        release.signal()
        try await waitUntil { store.isSaved(for: "a-1", cwd: "/tmp/one") }
        #expect(outsideSaved.withLock { $0 })
        #expect(try String(contentsOf: file, encoding: .utf8) == "newest local")
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "newest local")
        let conflicts = try conflictFiles(beside: file)
        #expect(conflicts.count == 1)
        #expect(try String(contentsOf: #require(conflicts.first), encoding: .utf8) == "outside while queued")
    }

    @Test @MainActor
    func unreadableOutsideFileBlocksReplacementUntilRetry() throws {
        let (store, root) = try makeStore()
        let fm = FileManager.default
        let file = noteFile(root, "a-1", "/tmp/one")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? fm.removeItem(at: root)
        }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        store.setNote("local", for: "a-1", cwd: "/tmp/one")
        try Data("outside".utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        store.flushNow()
        #expect(!store.isSaved(for: "a-1", cwd: "/tmp/one"))
        #expect(store.notice(for: "a-1", cwd: "/tmp/one") == .saveFailed)
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "local")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "outside")
        store.retrySaves()
        #expect(try String(contentsOf: file, encoding: .utf8) == "local")
        let conflict = try #require(try conflictFiles(beside: file).first)
        #expect(try String(contentsOf: conflict, encoding: .utf8) == "outside")
    }

    @Test @MainActor
    func conflictFilenameCollisionsNeverReplaceExistingCopies() throws {
        let (_, root) = try makeStore()
        let store = ConversationNotesStore(root: root, conflictTimestamp: { 1234 })
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        let collision = file.deletingLastPathComponent().appendingPathComponent("a-1.conflict-1234-0.md")
        try Data("existing backup".utf8).write(to: collision)
        store.setNote("local", for: "a-1", cwd: "/tmp/one")
        try Data("outside".utf8).write(to: file, options: .atomic)
        store.flushNow()
        #expect(try String(contentsOf: collision, encoding: .utf8) == "existing backup")
        let backup = file.deletingLastPathComponent().appendingPathComponent("a-1.conflict-1234-1.md")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "outside")
        #expect(store.notice(for: "a-1", cwd: "/tmp/one") == .conflictPreserved(backup))
    }

    @Test @MainActor
    func failedPreservationKeepsDiskAndBothDraftsSafeAcrossRetry() throws {
        let (store, root) = try makeStore()
        let fm = FileManager.default
        let file = noteFile(root, "a-1", "/tmp/one")
        let folder = file.deletingLastPathComponent()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? fm.removeItem(at: root)
        }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        store.setNote("local draft", for: "a-1", cwd: "/tmp/one")
        try Data("outside one".utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        store.flushNow()
        #expect(try String(contentsOf: file, encoding: .utf8) == "outside one")
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "local draft")
        #expect(!store.isSaved(for: "a-1", cwd: "/tmp/one"))
        #expect(store.notice(for: "a-1", cwd: "/tmp/one") == .conflictUnsaved)

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try Data("outside two".utf8).write(to: file, options: .atomic)
        store.flushNow()
        #expect(try String(contentsOf: file, encoding: .utf8) == "local draft")
        let preserved = try conflictFiles(beside: file).map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(preserved.contains("outside one"))
        #expect(preserved.contains("outside two"))
        #expect(store.isSaved(for: "a-1", cwd: "/tmp/one"))
    }

    @Test @MainActor
    func invalidUTF8OutsideRevisionIsPreservedAsBytes() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        let outside = Data([0xff, 0xfe, 0x00])
        store.setNote("local draft", for: "a-1", cwd: "/tmp/one")
        try outside.write(to: file, options: .atomic)
        store.flushNow()
        let conflict = try #require(try conflictFiles(beside: file).first)
        #expect(try Data(contentsOf: conflict) == outside)
        #expect(try String(contentsOf: file, encoding: .utf8) == "local draft")
    }

    @Test @MainActor
    func cachedReadsAndKeystrokesDoNotReadDiskAgain() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        // Synchronous edits happen before any filesystem-event refresh can run.
        try Data("outside".utf8).write(to: file, options: .atomic)
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "original")
        for index in 0..<100 { store.setNote("draft \(index)", for: "a-1", cwd: "/tmp/one") }
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "draft 99")
        #expect(try String(contentsOf: file, encoding: .utf8) == "outside")
        store.flushNow()
        #expect(try String(contentsOf: file, encoding: .utf8) == "draft 99")
        #expect(try conflictFiles(beside: file).count == 1)
    }

    @Test @MainActor
    func idleExternalRefreshInvalidatesObservation() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.setNote("original", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.note(for: "a-1", cwd: "/tmp/one")
        } onChange: {
            changed.withLock { $0 = true }
        }
        try Data("outside".utf8).write(to: noteFile(root, "a-1", "/tmp/one"), options: .atomic)
        try await waitUntil { changed.withLock { $0 } }
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "outside")
    }

    @MainActor
    private func makeStore() throws -> (ConversationNotesStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationNotesStoreTests-\(UUID().uuidString)")
        return (ConversationNotesStore(root: root), root)
    }

    @MainActor
    private func noteFile(_ root: URL, _ sessionID: String, _ cwd: String) -> URL {
        root
            .appendingPathComponent(GrokPaths.encode(path: GrokPaths.canonicalPath(cwd)))
            .appendingPathComponent("\(sessionID).md")
    }

    @Test @MainActor
    func notesRoundTripThroughAFilePerConversation() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "")
        store.setNote("ports: 3000\nowner: web team", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "ports: 3000\nowner: web team")
        #expect(store.note(for: "b-2", cwd: "/tmp/one") == "")

        let file = noteFile(root, "a-1", "/tmp/one")
        #expect(try String(contentsOf: file, encoding: .utf8) == "ports: 3000\nowner: web team")

        // A second store over the same root reads what the first one wrote.
        let reread = ConversationNotesStore(root: root)
        #expect(reread.note(for: "a-1", cwd: "/tmp/one") == "ports: 3000\nowner: web team")
    }

    @Test @MainActor
    func theSameSessionIDInTwoFoldersKeepsTwoNotes() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        store.setNote("first folder", for: "a-1", cwd: "/tmp/one")
        store.setNote("second folder", for: "a-1", cwd: "/tmp/two")
        store.flushNow()
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "first folder")
        #expect(store.note(for: "a-1", cwd: "/tmp/two") == "second folder")
        #expect(FileManager.default.fileExists(atPath: noteFile(root, "a-1", "/tmp/one").path))
        #expect(FileManager.default.fileExists(atPath: noteFile(root, "a-1", "/tmp/two").path))
    }

    @Test @MainActor
    func providerNotesUseSeparateNamespacesAndPreserveTheGrokLayout() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = "11111111-1111-4111-8111-111111111111"
        let cwd = "/tmp/one"
        for id in [uuid, "claudeCode:" + uuid, "codex:" + uuid] {
            store.setNote("Note for " + id, for: id, cwd: cwd)
        }
        store.flushNow()
        let reread = ConversationNotesStore(root: root)
        for id in [uuid, "claudeCode:" + uuid, "codex:" + uuid] {
            #expect(reread.note(for: id, cwd: cwd) == "Note for " + id)
            #expect(store.isSaved(for: id, cwd: cwd))
        }
        #expect(FileManager.default.fileExists(atPath: noteFile(root, uuid, cwd).path))
        #expect(
            FileManager.default.fileExists(atPath: noteFile(root.appendingPathComponent("claudeCode"), uuid, cwd).path))
        #expect(FileManager.default.fileExists(atPath: noteFile(root.appendingPathComponent("codex"), uuid, cwd).path))
        reread.deleteNote(for: "claudeCode:" + uuid, cwd: cwd)
        reread.flushNow()
        let afterDelete = ConversationNotesStore(root: root)
        #expect(afterDelete.note(for: "claudeCode:" + uuid, cwd: cwd).isEmpty)
        #expect(afterDelete.note(for: uuid, cwd: cwd) == "Note for " + uuid)
        #expect(afterDelete.note(for: "codex:" + uuid, cwd: cwd) == "Note for codex:" + uuid)
    }

    @Test @MainActor
    func writesAreCoalescedAndFlushOnDemand() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        store.setNote("draft one", for: "a-1", cwd: "/tmp/one")
        store.setNote("draft two", for: "a-1", cwd: "/tmp/one")
        let file = noteFile(root, "a-1", "/tmp/one")
        // Inside the debounce window the cache serves the text before the disk does.
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "draft two")
        store.flushNow()
        #expect(try String(contentsOf: file, encoding: .utf8) == "draft two")
    }

    @Test @MainActor
    func emptyTextDeletesTheFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        store.setNote("scratch", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        let file = noteFile(root, "a-1", "/tmp/one")
        #expect(FileManager.default.fileExists(atPath: file.path))
        store.setNote("", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "")
    }

    @Test @MainActor
    func aPendingWriteDoesNotResurrectADeletedNote() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        store.setNote("scratch", for: "a-1", cwd: "/tmp/one")
        store.deleteNote(for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        #expect(!FileManager.default.fileExists(atPath: noteFile(root, "a-1", "/tmp/one").path))
    }

    @Test @MainActor
    func aDeletedNoteStaysGoneBeforeTheFlushLands() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        store.setNote("scratch", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        store.deleteNote(for: "a-1", cwd: "/tmp/one")
        // Still inside the debounce window: the file exists on disk, but the
        // tombstone must answer the read instead of resurrecting it.
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "")
        store.flushNow()
        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "")
    }

    @Test @MainActor
    func aFlatNoteFromTheFirstBuildIsAdoptedOnFirstRead() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // The first notes-as-files build wrote root/<id>.md with no folder.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("a-1.md")
        try Data("old layout".utf8).write(to: legacy)

        #expect(store.note(for: "a-1", cwd: "/tmp/one") == "old layout")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: noteFile(root, "a-1", "/tmp/one").path))
    }

    @Test @MainActor
    func deleteFlatNoteRemovesTheFirstBuildsLayout() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("a-1.md")
        try Data("old layout".utf8).write(to: legacy)

        store.deleteFlatNote(forSessionID: "a-1")
        store.flushNow()
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test @MainActor
    func idsThatCouldEscapeTheFolderAreRefused() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        for bad in [
            "../escape", "a/b", "", "a b", "å", "codex:../escape", "claudeCode:not-a-uuid",
            "../codex:11111111-1111-4111-8111-111111111111", "codex:11111111-1111-4111-8111-111111111111:extra",
        ] {
            store.setNote("nope", for: bad, cwd: "/tmp/one")
            #expect(store.note(for: bad, cwd: "/tmp/one") == "")
        }
        store.flushNow()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test @MainActor
    func aFailedWriteIsRetriedByTheNextFlush() throws {
        let (store, root) = try makeStore()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        // A read-only notes folder makes the write fail.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        store.setNote("first", for: "a-1", cwd: "/tmp/one")
        store.setNote("kept", for: "b-2", cwd: "/tmp/one")
        store.flushNow()
        #expect(!fm.fileExists(atPath: noteFile(root, "a-1", "/tmp/one").path))

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        store.setNote("newer", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        #expect(try String(contentsOf: noteFile(root, "a-1", "/tmp/one"), encoding: .utf8) == "newer")
        #expect(try String(contentsOf: noteFile(root, "b-2", "/tmp/one"), encoding: .utf8) == "kept")
    }

    @Test @MainActor
    func aFailedDebouncedWriteIsRetriedAtQuit() async throws {
        let (store, root) = try makeStore()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        store.setNote("typed", for: "a-1", cwd: "/tmp/one")
        try await Task.sleep(for: ConversationNotesStore.flushDelay * 3)

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        store.flushNow()
        #expect(try String(contentsOf: noteFile(root, "a-1", "/tmp/one"), encoding: .utf8) == "typed")
    }

    @Test @MainActor
    func aFailedDeleteIsRetriedByTheNextFlush() throws {
        let (store, root) = try makeStore()
        let fm = FileManager.default
        let file = noteFile(root, "a-1", "/tmp/one")
        let folder = file.deletingLastPathComponent()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? fm.removeItem(at: root)
        }
        store.setNote("scratch", for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        store.deleteNote(for: "a-1", cwd: "/tmp/one")
        store.flushNow()
        #expect(fm.fileExists(atPath: file.path))

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        store.flushNow()
        #expect(!fm.fileExists(atPath: file.path))
    }

    @Test @MainActor
    func aNoteForALongNonASCIIFolderIsSavedAndReadBack() throws {
        let (store, root) = try makeStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-cwd-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: base)
        }
        // Percent-encoded, this path is far over the 255-byte file name limit.
        let cwd = base.appendingPathComponent("太郎/ドキュメント/開発プロジェクト/顧客向け在庫管理システム")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        store.setNote("deploy on friday", for: "a-1", cwd: cwd.path)
        store.flushNow()

        let reread = ConversationNotesStore(root: root)
        #expect(reread.note(for: "a-1", cwd: cwd.path) == "deploy on friday")
        let folder = GrokPaths.sessionFolderName(forCanonicalPath: GrokPaths.canonicalPath(cwd.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path))
    }

    @Test @MainActor
    func defaultRootLivesUnderApplicationSupport() {
        let root = ConversationNotesStore.defaultRoot
        #expect(root.path.contains("Application Support/Sigil/notes"))
    }
}
