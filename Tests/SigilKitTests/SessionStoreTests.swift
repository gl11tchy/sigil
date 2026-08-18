import Foundation
import Testing

@testable import SigilKit

@Suite
@MainActor
struct SessionStoreTests {

    @Test func parsesFullRecord() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.write(
            fixture: "full.json",
            cwd: "/Users/exec/Documents/keyholding-v0-v2",
            id: "019f780a-34d7-7993-aadc-f23a46c40a73"
        )

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.loadError == nil)
        #expect(!harness.store.isLoading)
        let session = try #require(harness.store.sessions.first)
        #expect(session.id == "019f780a-34d7-7993-aadc-f23a46c40a73")
        #expect(session.cwd == "/Users/exec/Documents/keyholding-v0-v2")
        #expect(session.summary == "Assess Overly Prescriptive AI Keyholder System Prompt")
        #expect(session.title == session.summary)
        #expect(session.messageCount == 74)
        #expect(session.modelID == "grok-4.5")
        #expect(session.agentName == "grok-build-plan")
        #expect(session.reasoningEffort == "high")
        #expect(session.createdAt == SessionTimestamp.parse("2026-07-19T01:42:42.653063Z"))
        #expect(session.updatedAt == SessionTimestamp.parse("2026-07-19T01:46:22.537987Z"))
        #expect(session.projectName == "keyholding-v0-v2")
    }

    @Test func parsesMinimalRecord() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )

        await harness.store.scan(ignoringCache: false)

        let session = try #require(harness.store.sessions.first)
        #expect(session.id == "019ffeab-c76b-7fe1-be40-508369febd51")
        #expect(session.cwd == "/Users/exec")
        #expect(session.messageCount == 0)
        #expect(session.modelID == nil)
        #expect(session.agentName == nil)
        #expect(session.reasoningEffort == nil)
        #expect(session.createdAt == SessionTimestamp.parse("2026-08-14T05:08:18.485965Z"))
        #expect(session.updatedAt == SessionTimestamp.parse("2026-08-14T05:08:18.561566Z"))
    }

    @Test func emptySummaryUsesTitleFallback() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.write(
            fixture: "empty-summary.json",
            cwd: "/Users/exec/Documents/diablomaxxing",
            id: "019f8cfd-a25d-7d73-aecb-812cca14bc0e"
        )

        await harness.store.scan(ignoringCache: false)

        let session = try #require(harness.store.sessions.first)
        #expect(session.summary == "")
        #expect(session.title == "Untitled session in diablomaxxing")
        #expect(session.messageCount == 120)
    }

    @Test func missingChatCountFallsBackToNumMessages() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        var object = try FixtureHarness.jsonObject("full.json")
        object.removeValue(forKey: "num_chat_messages")
        try harness.write(
            json: object,
            cwd: "/Users/exec/Documents/keyholding-v0-v2",
            id: "019f780a-34d7-7993-aadc-f23a46c40a73"
        )

        await harness.store.scan(ignoringCache: false)

        let session = try #require(harness.store.sessions.first)
        #expect(session.messageCount == 258)
    }

    @Test func missingTimestampsUseFileModificationDate() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        var object = try FixtureHarness.jsonObject("full.json")
        object.removeValue(forKey: "created_at")
        object["updated_at"] = "not-a-date"
        let url = try harness.write(
            json: object,
            cwd: "/Users/exec/Documents/keyholding-v0-v2",
            id: "019f780a-34d7-7993-aadc-f23a46c40a73"
        )
        let fileDate = try #require(
            url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )

        await harness.store.scan(ignoringCache: false)

        let session = try #require(harness.store.sessions.first)
        #expect(session.createdAt == fileDate)
        #expect(session.updatedAt == fileDate)
    }

    @Test func malformedEntriesAreSkippedWithoutAborting() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }

        try harness.write(
            fixture: "full.json",
            cwd: "/Users/exec/Documents/keyholding-v0-v2",
            id: "019f780a-34d7-7993-aadc-f23a46c40a73"
        )
        try harness.write(
            fixture: "empty-summary.json",
            cwd: "/Users/exec/Documents/diablomaxxing",
            id: "019f8cfd-a25d-7d73-aecb-812cca14bc0e"
        )
        try harness.write(
            data: Data("this is not json {".utf8),
            cwd: "/tmp/bad-json",
            id: "aaaaaaaa-1111-1111-1111-111111111111"
        )
        try harness.write(
            data: Data("[1, 2, 3]".utf8),
            cwd: "/tmp/wrong-shape",
            id: "bbbbbbbb-2222-2222-2222-222222222222"
        )
        var missingCwd = try FixtureHarness.jsonObject("full.json")
        var info = missingCwd["info"] as? [String: Any] ?? [:]
        info.removeValue(forKey: "cwd")
        missingCwd["info"] = info
        try harness.write(
            json: missingCwd,
            cwd: "/tmp/missing-cwd",
            id: "cccccccc-3333-3333-3333-333333333333"
        )
        try harness.writeDirectoryNamedSummary(
            cwd: "/tmp/summary-is-dir",
            id: "dddddddd-4444-4444-4444-444444444444"
        )

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.loadError == nil)
        #expect(!harness.store.isLoading)
        let ids = Set(harness.store.sessions.map(\.id))
        #expect(
            ids == [
                "019f780a-34d7-7993-aadc-f23a46c40a73",
                "019f8cfd-a25d-7d73-aecb-812cca14bc0e",
            ]
        )
    }

    @Test func missingRootSetsLoadErrorAndLeavesSessionsEmpty() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sigil-missing-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(root: missing)
        await store.scan(ignoringCache: false)
        #expect(store.sessions.isEmpty)
        #expect(store.loadError != nil)
        #expect(!store.isLoading)
    }

    @Test func stopIsSafeWhenNeverStarted() {
        let store = SessionStore(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("unused")
        )
        store.stop()
        store.stop()
    }

    @Test func startIsIdempotent() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )
        harness.store.start()
        harness.store.start()
        try await waitUntil { !harness.store.isLoading && !harness.store.sessions.isEmpty }
        #expect(harness.store.sessions.count == 1)
        harness.store.stop()
        harness.store.stop()
    }

    @Test(arguments: SessionQueryCase.all)
    func searchAndGrouping(_ queryCase: SessionQueryCase) async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.installOrderingFixtures()

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.sessions.map(\.id) == ["a1", "b1", "g1", "a2", "b2"])
        #expect(harness.store.search(queryCase.query).map(\.id) == queryCase.expectedIDs)
        let groups = harness.store.groupedByProject(matching: queryCase.query)
        #expect(groups.map(\.cwd) == queryCase.expectedGroupOrder)
        #expect(groups.map { $0.sessions.map(\.id) } == queryCase.expectedGroupedIDs)
    }

    @Test func incrementalRescanReparsesChangedAndDropsDeleted() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        let full = try harness.write(
            fixture: "full.json",
            cwd: "/Users/exec/Documents/keyholding-v0-v2",
            id: "019f780a-34d7-7993-aadc-f23a46c40a73"
        )
        try harness.write(
            fixture: "empty-summary.json",
            cwd: "/Users/exec/Documents/diablomaxxing",
            id: "019f8cfd-a25d-7d73-aecb-812cca14bc0e"
        )
        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )

        await harness.store.scan(ignoringCache: false)
        #expect(harness.store.sessions.count == 3)
        #expect(
            harness.store.sessions.first { $0.id == "019f780a-34d7-7993-aadc-f23a46c40a73" }?.title
                == "Assess Overly Prescriptive AI Keyholder System Prompt"
        )

        var mutated = try FixtureHarness.jsonObject("full.json")
        mutated["session_summary"] = "Updated summary after rescan"
        try JSONSerialization.data(withJSONObject: mutated, options: [.prettyPrinted])
            .write(to: full, options: .atomic)

        try FileManager.default.removeItem(
            at: harness.sessionDirectory(
                cwd: "/Users/exec",
                id: "019ffeab-c76b-7fe1-be40-508369febd51"
            )
        )

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.loadError == nil)
        let ids = Set(harness.store.sessions.map(\.id))
        #expect(
            ids == [
                "019f780a-34d7-7993-aadc-f23a46c40a73",
                "019f8cfd-a25d-7d73-aecb-812cca14bc0e",
            ]
        )
        #expect(
            harness.store.sessions.first { $0.id == "019f780a-34d7-7993-aadc-f23a46c40a73" }?.title
                == "Updated summary after rescan"
        )
        #expect(
            harness.store.sessions.first { $0.id == "019f8cfd-a25d-7d73-aecb-812cca14bc0e" }?.title
                == "Untitled session in diablomaxxing"
        )
    }
}

struct SessionQueryCase: Sendable, CustomTestStringConvertible {
    var query: String
    var expectedIDs: [String]
    var expectedGroupOrder: [String]
    var expectedGroupedIDs: [[String]]

    var testDescription: String {
        query.isEmpty ? "empty" : query
    }

    static let all: [SessionQueryCase] = [
        SessionQueryCase(
            query: "",
            expectedIDs: ["a1", "b1", "g1", "a2", "b2"],
            expectedGroupOrder: ["/proj/Alpha", "/proj/Beta", "/proj/Gamma"],
            expectedGroupedIDs: [["a1", "a2"], ["b1", "b2"], ["g1"]]
        ),
        SessionQueryCase(
            query: "   \t",
            expectedIDs: ["a1", "b1", "g1", "a2", "b2"],
            expectedGroupOrder: ["/proj/Alpha", "/proj/Beta", "/proj/Gamma"],
            expectedGroupedIDs: [["a1", "a2"], ["b1", "b2"], ["g1"]]
        ),
        SessionQueryCase(
            query: "alpha",
            expectedIDs: ["a1", "a2"],
            expectedGroupOrder: ["/proj/Alpha"],
            expectedGroupedIDs: [["a1", "a2"]]
        ),
        SessionQueryCase(
            query: "cafe",
            expectedIDs: ["b1"],
            expectedGroupOrder: ["/proj/Beta"],
            expectedGroupedIDs: [["b1"]]
        ),
        SessionQueryCase(
            query: "BETA",
            expectedIDs: ["b1", "b2"],
            expectedGroupOrder: ["/proj/Beta"],
            expectedGroupedIDs: [["b1", "b2"]]
        ),
        SessionQueryCase(
            query: "Zebra",
            expectedIDs: ["a1"],
            expectedGroupOrder: ["/proj/Alpha"],
            expectedGroupedIDs: [["a1"]]
        ),
        SessionQueryCase(
            query: "zzz",
            expectedIDs: [],
            expectedGroupOrder: [],
            expectedGroupedIDs: []
        ),
    ]
}

@MainActor
private struct FixtureHarness {
    let root: URL
    let store: SessionStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sigil-SessionStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(root: root)
    }

    func tearDown() {
        store.stop()
        try? FileManager.default.removeItem(at: root)
    }

    static func data(_ name: String) throws -> Data {
        switch name {
        case "full.json": return Data(CopiedSummaries.full.utf8)
        case "empty-summary.json": return Data(CopiedSummaries.emptySummary.utf8)
        case "minimal.json": return Data(CopiedSummaries.minimal.utf8)
        default:
            throw CocoaError(.fileNoSuchFile)
        }
    }

    static func jsonObject(_ name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data(name))
        return try #require(object as? [String: Any])
    }

    @discardableResult
    func write(fixture: String, cwd: String, id: String) throws -> URL {
        try write(data: Self.data(fixture), cwd: cwd, id: id)
    }

    @discardableResult
    func write(json: [String: Any], cwd: String, id: String) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        return try write(data: data, cwd: cwd, id: id)
    }

    @discardableResult
    func write(data: Data, cwd: String, id: String) throws -> URL {
        let dir = sessionDirectory(cwd: cwd, id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("summary.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func writeDirectoryNamedSummary(cwd: String, id: String) throws {
        let dir = sessionDirectory(cwd: cwd, id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("summary.json"),
            withIntermediateDirectories: true
        )
    }

    func sessionDirectory(cwd: String, id: String) -> URL {
        root
            .appendingPathComponent(GrokPaths.encode(path: cwd), isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    func installOrderingFixtures() throws {
        try write(
            json: summary(
                id: "a1",
                cwd: "/proj/Alpha",
                text: "Zebra notes",
                created: "2026-08-01T00:00:00Z",
                updated: "2026-08-01T00:00:03Z"
            ),
            cwd: "/proj/Alpha",
            id: "a1"
        )
        try write(
            json: summary(
                id: "a2",
                cwd: "/proj/Alpha",
                text: "Alpha old",
                created: "2026-08-01T00:00:00Z",
                updated: "2026-08-01T00:00:01Z"
            ),
            cwd: "/proj/Alpha",
            id: "a2"
        )
        try write(
            json: summary(
                id: "b1",
                cwd: "/proj/Beta",
                text: "Café work",
                created: "2026-08-01T00:00:00Z",
                updated: "2026-08-01T00:00:02Z"
            ),
            cwd: "/proj/Beta",
            id: "b1"
        )
        try write(
            json: summary(
                id: "b2",
                cwd: "/proj/Beta",
                text: "Beta old",
                created: "2026-08-01T00:00:00Z",
                updated: "2026-08-01T00:00:00Z"
            ),
            cwd: "/proj/Beta",
            id: "b2"
        )
        try write(
            json: summary(
                id: "g1",
                cwd: "/proj/Gamma",
                text: "Gamma",
                created: "2026-08-01T00:00:00Z",
                updated: "2026-08-01T00:00:02Z"
            ),
            cwd: "/proj/Gamma",
            id: "g1"
        )
    }

    private func summary(
        id: String,
        cwd: String,
        text: String,
        created: String,
        updated: String
    ) -> [String: Any] {
        [
            "info": ["id": id, "cwd": cwd],
            "session_summary": text,
            "created_at": created,
            "updated_at": updated,
            "num_messages": 1,
            "num_chat_messages": 2,
        ]
    }
}

/// Real `summary.json` bodies copied from `~/.grok/sessions`.
private enum CopiedSummaries {
    static let full = """
        {
          "info": {
            "id": "019f780a-34d7-7993-aadc-f23a46c40a73",
            "cwd": "/Users/exec/Documents/keyholding-v0-v2"
          },
          "session_summary": "Assess Overly Prescriptive AI Keyholder System Prompt",
          "created_at": "2026-07-19T01:42:42.653063Z",
          "updated_at": "2026-07-19T01:46:22.537987Z",
          "num_messages": 258,
          "num_chat_messages": 74,
          "current_model_id": "grok-4.5",
          "next_trace_turn": 1,
          "chat_format_version": 1,
          "git_root_dir": "/Users/exec/Documents/keyholding-v0-v2/",
          "git_remotes": [
            "https://github.com/gl11tchy/keyholding-v0-v2.git"
          ],
          "head_commit": "bfdb4280ca92429b812a22eaf2d2921821715eea",
          "head_branch": "main",
          "request_id": "811839a1-f7e3-4a38-ab94-748356aff75c",
          "grok_home": "/Users/exec/.grok",
          "last_active_at": "2026-07-19T01:46:22.537987Z",
          "generated_title": "Assess Overly Prescriptive AI Keyholder System Prompt",
          "agent_name": "grok-build-plan",
          "sandbox_profile": "workspace",
          "reasoning_effort": "high"
        }
        """

    static let emptySummary = """
        {
          "info": {
            "id": "019f8cfd-a25d-7d73-aecb-812cca14bc0e",
            "cwd": "/Users/exec/Documents/diablomaxxing"
          },
          "session_summary": "",
          "created_at": "2026-07-23T03:21:00.257785Z",
          "updated_at": "2026-07-23T03:25:24.341667Z",
          "num_messages": 460,
          "num_chat_messages": 120,
          "current_model_id": "grok-4.5",
          "next_trace_turn": 1,
          "chat_format_version": 1,
          "git_root_dir": "/Users/exec/Documents/diablomaxxing/",
          "head_commit": "1220ec94a800d94af0154425326598c5a444e25b",
          "head_branch": "main",
          "request_id": "9c8d8ecf-f758-4070-a9df-43993193f781",
          "grok_home": "/Users/exec/.grok",
          "last_active_at": "2026-07-23T03:25:24.341667Z",
          "agent_name": "grok-build-plan",
          "sandbox_profile": "read-only",
          "reasoning_effort": "high"
        }
        """

    static let minimal = """
        {
          "info": {
            "id": "019ffeab-c76b-7fe1-be40-508369febd51",
            "cwd": "/Users/exec"
          },
          "session_summary": "",
          "created_at": "2026-08-14T05:08:18.485965Z",
          "updated_at": "2026-08-14T05:08:18.561566Z",
          "num_messages": 0,
          "num_chat_messages": 0
        }
        """
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for condition")
}
