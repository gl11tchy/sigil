import Foundation
import Testing

@testable import SigilKit

struct ConversationNotesStoreTests {

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

        for bad in ["../escape", "a/b", "", "a b", "å"] {
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
    func defaultRootLivesUnderApplicationSupport() {
        let root = ConversationNotesStore.defaultRoot
        #expect(root.path.contains("Application Support/Sigil/notes"))
    }
}
