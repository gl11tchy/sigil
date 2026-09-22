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
    func defaultRootLivesUnderApplicationSupport() {
        let root = ConversationNotesStore.defaultRoot
        #expect(root.path.contains("Application Support/Sigil/notes"))
    }
}
