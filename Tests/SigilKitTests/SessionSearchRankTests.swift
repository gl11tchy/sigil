import Foundation
import Testing

@testable import SigilKit

@Suite
@MainActor
struct SessionSearchRankTests {

    @Test(arguments: [
        ("Rate limiter", "lim", SessionScanner.SearchRank.titleWordStart),
        ("Climbing", "lim", .titleContains),
        ("Climbing / limiter", "lim", .titleWordStart),
        ("Try—CAFÉ menu", "cafe", .titleWordStart),
        ("Rate_limiter", "lim", .titleWordStart),
        ("Rate v2limiter", "lim", .titleContains),
        ("Правка—лимитер", "лим", .titleWordStart),
        ("更新—登录流程", "登录", .titleWordStart),
        ("更新登录流程", "登录", .titleContains),
        ("Climbing 🛠limiter", "lim", .titleWordStart),
        ("Rate-limiter", "lim rate", .titleWordStart),
        ("Rate climbing", "rate lim", .titleContains),
        ("Rate limiter", "rate lim", .titlePrefix),
    ])
    func foldedWordStarts(_ title: String, _ query: String, _ expected: SessionScanner.SearchRank) throws {
        let parsed = try #require(SessionScanner.SearchQuery(query))
        #expect(SessionScanner.searchRank(.init(rankedSession("row", title)), query: parsed) == expected)
    }

    @Test func rankThenBoostThenRecency() {
        let rows = [
            rankedSession("path", "Weekly", updated: 100, cwd: "/generated/lim", provider: .codex),
            rankedSession("middle", "Climbing", updated: 90),
            rankedSession("word", "Rate limiter", updated: 80),
            rankedSession("prefix", "Limiter notes", updated: 70),
            rankedSession("exact", "Lim", updated: 1),
            rankedSession("open", "Rate limiter", updated: 2),
            rankedSession("pin", "Rate limiter", updated: 3),
            rankedSession("project", "Rate limiter", updated: 4),
            rankedSession("newer-open", "Rate limiter", updated: 5),
        ]
        let boosts = ["open": 3, "newer-open": 3, "pin": 2, "project": 1, "middle": 3, "codex:path": 3]
        var calls: [String: Int] = [:]
        let found = SessionScanner.search(
            "lim", sessions: rows, keys: SessionScanner.searchKeys(for: rows),
            boost: {
                calls[$0.id, default: 0] += 1
                return boosts[$0.id] ?? 0
            })
        #expect(
            found.map(\.id) == [
                "exact", "prefix", "newer-open", "open", "pin", "project", "word", "middle", "codex:path",
            ])
        #expect(calls.count == rows.count)
        #expect(calls.values.allSatisfy { $0 == 1 })
    }

    @Test func providerQualifiedTiesAreIndependentOfInputOrder() {
        let rows = [
            rankedSession("same", "Lim", cwd: "/generated/b", provider: .codex),
            rankedSession("same", "Lim", cwd: "/generated/a", provider: .codex),
            rankedSession("same", "Lim", provider: .claudeCode),
            rankedSession("codex:same", "Lim"),
        ]
        let expected = [rows[2].reference, rows[1].reference, rows[0].reference, rows[3].reference]
        for input in [rows, Array(rows.reversed()), [rows[1], rows[3], rows[2], rows[0]]] {
            let found = SessionScanner.search("lim", sessions: input, keys: SessionScanner.searchKeys(for: input))
            #expect(found.map(\.reference) == expected)
        }
    }

    @Test(arguments: ["", " \n\t "])
    func emptyQuerySkipsTitlesAndBoosts(_ query: String) {
        let rows = [rankedSession("new", "Weekly", updated: 2), rankedSession("old", "Lim", updated: 1)]
        let found = SessionScanner.search(
            query, sessions: rows, keys: [],
            boost: { _ in
                Issue.record("Empty query evaluated boost")
                return 99
            },
            displayedTitle: { _ in
                Issue.record("Empty query evaluated title")
                return "Lim"
            },
            foldedNotes: { _ in
                Issue.record("Empty query evaluated note")
                return "lim"
            })
        #expect(found == rows)
    }

    @Test func everyTitleAndPathRankBeatsBoostedNotesAndNoteTiesKeepTheSharedOrder() {
        let rows = [
            rankedSession("note", "Weekly", updated: 100),
            rankedSession("pin", "Weekly", updated: 90),
            rankedSession("open", "Weekly", updated: 1),
            rankedSession("path", "Weekly", updated: 2, cwd: "/generated/lim"),
            rankedSession("middle", "Climbing", updated: 3),
            rankedSession("word", "Rate limiter", updated: 4),
            rankedSession("prefix", "Limiter", updated: 5),
            rankedSession("exact", "Lim", updated: 6),
        ]
        let boosts = ["open": 3, "pin": 2]
        let found = SessionScanner.search(
            "lim", sessions: rows, keys: SessionScanner.searchKeys(for: rows),
            boost: { boosts[$0.id] ?? 0 }, foldedNotes: { _ in "lim" })
        #expect(found.map(\.id) == ["exact", "prefix", "word", "middle", "path", "open", "pin", "note"])
        let withoutNotes = SessionScanner.search("lim", sessions: rows, keys: SessionScanner.searchKeys(for: rows))
        #expect(withoutNotes == Array(found.prefix(5)))
        let partial = SessionScanner.search(
            "lim zirconia", sessions: rows, keys: SessionScanner.searchKeys(for: rows),
            foldedNotes: { _ in "lim" })
        #expect(partial.isEmpty)
    }

    @Test func storeNotesOverloadPreservesTrailingTitleAndPhoneTitlePathOnlySearch() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        try harness.write(id: "note", cwd: "/work/project", title: "Weekly", updated: "2026-01-01T00:00:00Z")
        await harness.store.scan(ignoringCache: false)
        #expect(harness.store.search("zirconia").isEmpty)
        let noteText: (GrokSession) -> String? = { _ in "zirconia" }
        let found = harness.store.search("zirconia", boost: nil, foldedNotes: noteText) { $0.summary }
        #expect(found.count == 1)
        #expect(harness.store.search("weekly") { $0.summary }.count == 1)
    }

    @Test func wordStartBeatsANewerMiddleHitThroughTheStore() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        try harness.write(id: "word", cwd: "/work/notes", title: "Rate limiter", updated: "2026-01-01T00:00:00Z")
        try harness.write(id: "middle", cwd: "/work/notes", title: "Climbing", updated: "2026-06-01T00:00:00Z")
        await harness.store.scan(ignoringCache: false)
        #expect(harness.store.search("lim").map(\.id) == ["word", "middle"])
    }

    @Test func storeBoostOutranksRecencyOnlyWithinAMatchRank() async throws {
        let harness = try RankHarness()
        defer { harness.tearDown() }
        for (id, title, month) in [
            ("exact", "Lim", "01"), ("closed", "Rate limiter", "06"), ("open", "Rate limiter", "02"),
        ] {
            try harness.write(id: id, cwd: "/work/notes", title: title, updated: "2026-\(month)-01T00:00:00Z")
        }
        await harness.store.scan(ignoringCache: false)
        #expect(
            harness.store.search("lim", boost: { $0.id == "open" ? 3 : 0 }).map(\.id) == ["exact", "open", "closed"])
    }

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

private func rankedSession(
    _ id: String, _ title: String, updated: TimeInterval = 1,
    cwd: String = "/generated/search", provider: CLIProvider = .grokBuild
) -> GrokSession {
    GrokSession(
        id: id, cwd: cwd, summary: title, createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: updated), messageCount: 4, modelID: nil,
        agentName: nil, reasoningEffort: nil, directory: URL(fileURLWithPath: cwd), provider: provider)
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
        let directory =
            root
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
