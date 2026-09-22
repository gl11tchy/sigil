import Foundation
import Testing

@testable import SigilKit

struct ConversationNotesStoreTests {

    private func makeStore() throws -> (ConversationNotesStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationNotesStoreTests-\(UUID().uuidString)")
        return (ConversationNotesStore(root: root), root)
    }

    @Test func notesRoundTripThroughAFilePerConversation() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.note(for: "a-1") == "")
        store.setNote("ports: 3000\nowner: web team", for: "a-1")
        #expect(store.note(for: "a-1") == "ports: 3000\nowner: web team")
        #expect(store.note(for: "b-2") == "")

        let file = root.appendingPathComponent("a-1.md")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == "ports: 3000\nowner: web team")

        // A second store over the same root reads what the first one wrote.
        let reread = ConversationNotesStore(root: root)
        #expect(reread.note(for: "a-1") == "ports: 3000\nowner: web team")
    }

    @Test func emptyTextDeletesTheFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        store.setNote("scratch", for: "a-1")
        let file = root.appendingPathComponent("a-1.md")
        #expect(FileManager.default.fileExists(atPath: file.path))
        store.setNote("", for: "a-1")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.note(for: "a-1") == "")
    }

    @Test func deleteNoteDropsTheFileAndTheCache() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        store.setNote("scratch", for: "a-1")
        store.deleteNote(for: "a-1")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a-1.md").path))
        #expect(store.note(for: "a-1") == "")
    }

    @Test func idsThatCouldEscapeTheFolderAreRefused() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        for bad in ["../escape", "a/b", "", "a b", "å"] {
            store.setNote("nope", for: bad)
            #expect(store.note(for: bad) == "")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func defaultRootLivesUnderApplicationSupport() {
        let root = ConversationNotesStore.defaultRoot
        #expect(root.path.contains("Application Support/Sigil/notes"))
    }
}
