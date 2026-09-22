import Foundation
import Testing

@testable import SigilKit

@Suite
@MainActor
struct SessionSearchRankTests {

    @Test func closerTitleBeatsANewerWeakerMatch() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        try harness.write(id: "exact", cwd: "/work/notes", title: "Auth", updated: "2026-01-01T00:00:00Z")
        try harness.write(
            id: "prefix", cwd: "/work/other", title: "Auth notes", updated: "2026-03-01T00:00:00Z")
        try harness.write(
            id: "contains", cwd: "/work/else", title: "See auth later", updated: "2026-04-01T00:00:00Z")
        try harness.write(
            id: "path", cwd: "/work/auth-tools", title: "Weekly", updated: "2026-06-01T00:00:00Z")

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.search("auth").map(\.id) == ["exact", "prefix", "contains", "path"])
    }

    @Test func titleCompareIgnoresCase() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        try harness.write(id: "exact", cwd: "/work/notes", title: "Auth", updated: "2026-01-01T00:00:00Z")
        try harness.write(
            id: "prefix", cwd: "/work/other", title: "AUTHOR guide", updated: "2026-06-01T00:00:00Z")

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.search("AUTH").map(\.id) == ["exact", "prefix"])
    }

    @Test func foldedPrefixBeatsANewerPathMatch() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        try harness.write(
            id: "prefix", cwd: "/work/notes", title: "Café menu", updated: "2026-01-01T00:00:00Z")
        try harness.write(
            id: "path", cwd: "/work/cafe-shop", title: "Hours", updated: "2026-06-01T00:00:00Z")

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.search("cafe").map(\.id) == ["prefix", "path"])
    }

    @Test func sameBandPutsTheNewerTitleFirst() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        try harness.write(
            id: "older", cwd: "/work/notes", title: "Auth one", updated: "2026-02-01T00:00:00Z")
        try harness.write(
            id: "newer", cwd: "/work/other", title: "Auth two", updated: "2026-05-01T00:00:00Z")
        try harness.write(
            id: "path", cwd: "/work/auth-tools", title: "Weekly", updated: "2026-08-01T00:00:00Z")

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.search("auth").map(\.id) == ["newer", "older", "path"])
    }

    @Test func everyTitleWordBeatsANewerFolderMatch() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        try harness.write(
            id: "title",
            cwd: "/work/notes",
            title: "rewrite the auth plan",
            updated: "2026-01-01T00:00:00Z"
        )
        try harness.write(
            id: "folder", cwd: "/work/auth-rewrite", title: "Weekly", updated: "2026-06-01T00:00:00Z")

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.search("auth rewrite").map(\.id) == ["title", "folder"])
    }

    @Test func displayedExactTitleBeatsANewerCliPrefix() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        try harness.write(
            id: "renamed", cwd: "/work/notes", title: "Weekly", updated: "2026-01-01T00:00:00Z")
        try harness.write(
            id: "cli", cwd: "/work/other", title: "Auth notes", updated: "2026-06-01T00:00:00Z")

        await harness.store.scan(ignoringCache: false)

        let ranked = harness.store.search("auth") { session in
            session.id == "renamed" ? "Auth" : session.title
        }
        #expect(ranked.map(\.id) == ["renamed", "cli"])
    }

    @Test func cliTitleExactBeatsANewerPathMatch() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        try harness.write(
            id: "cli", cwd: "/work/notes", title: "Auth", updated: "2026-01-01T00:00:00Z")
        try harness.write(
            id: "path", cwd: "/work/auth-tools", title: "Weekly", updated: "2026-06-01T00:00:00Z")

        await harness.store.scan(ignoringCache: false)

        let ranked = harness.store.search("auth") { _ in "Notes" }
        #expect(ranked.map(\.id) == ["cli", "path"])
    }

    @Test func sidebarSearchDoesNotReadTheTranscript() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        let summary = try harness.write(
            id: "quiet", cwd: "/work/notes", title: "Weekly", updated: "2026-06-01T00:00:00Z")
        let transcript = summary.deletingLastPathComponent().appendingPathComponent("chat_history.jsonl")
        try Data("zephyr-token inside the transcript\n".utf8).write(to: transcript, options: .atomic)

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.search("zephyr-token").isEmpty)
        #expect(harness.store.sessions.map(\.id) == ["quiet"])
    }
}

@MainActor
private struct RankHarness {
    let root: URL
    let store: SessionStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sigil-SearchRank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(root: root)
    }

    func tearDown() {
        store.stop()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(id: String, cwd: String, title: String, updated: String) throws -> URL {
        let directory = root
            .appendingPathComponent(GrokPaths.encode(path: cwd), isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "info": ["id": id, "cwd": cwd],
            "session_summary": title,
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": updated,
            "num_chat_messages": 4,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let url = directory.appendingPathComponent("summary.json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
