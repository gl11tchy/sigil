import Foundation
import Testing

@testable import SigilKit

struct NativeSessionScannerTests {
    let id = "11111111-1111-4111-8111-111111111111"
    let file = URL(fileURLWithPath: "/tmp/fixture.jsonl")

    @Test func readsVersionedNativeIdentitiesAndTitles() {
        let claude = Data(
            """
            {"type":"user","sessionId":"\(id)","cwd":"/tmp/worktree","version":"2.1.283","timestamp":"2026-09-27T10:00:00Z","message":{"content":"Fix the parser"}}
            {"type":"custom-title","customTitle":"Parser work"}
            """.utf8)
        let session = NativeSessionScanner.parse(provider: .claudeCode, data: claude, file: file, modified: Date())
        #expect(session?.nativeSessionID == id)
        #expect(session?.id == "claudeCode:\(id)")
        #expect(session?.cwd == "/tmp/worktree")
        #expect(session?.title == "Parser work")
        #expect(session?.directory == file)
        let codex = NativeSessionScanner.parse(provider: .codex, data: codexFixture(), file: file, modified: Date())
        #expect(codex?.nativeSessionID == id)
        #expect(codex?.title == "Check the API")
        #expect(codex?.provider == .codex)
    }

    @Test(arguments: ["0.158.0", "0.158.0-alpha.2", "0.160.0"])
    func newerCodexWithSupportedMetadataEntersHistory(version: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("rollout.jsonl")
        let data = codexFixture(version: version)
        try data.write(to: rollout)
        let result = NativeSessionScanner.scan(provider: .codex, root: root, cache: [:], ignoringCache: false)
        #expect(result.sessions.first?.nativeSessionID == id)
        #expect(result.sessions.first?.title == "Check the API")
        #expect(result.loadError == nil)
        #expect(try Data(contentsOf: rollout) == data)
    }

    @Test(arguments: ["0.158.0", "0.158.0-alpha.2", "0.160.0"])
    func aNewerResumeHeaderKeepsTheExistingCodexConversation(version: String) throws {
        let original = "2026-09-27T10:00:00Z"
        let resumed = "2026-10-09T08:00:00Z"
        let modified = try #require(SessionTimestamp.parse(resumed))
        let data =
            codexFixture(timestamp: original) + Data([0x0A])
            + codexFixture(version: version, timestamp: resumed)
        let session = NativeSessionScanner.parse(provider: .codex, data: data, file: file, modified: modified)
        #expect(session?.nativeSessionID == id)
        #expect(session?.cwd == "/tmp/project")
        #expect(session?.createdAt == SessionTimestamp.parse(original))
        #expect(session?.updatedAt == modified)
    }

    @Test(arguments: ["0.1", "0.157.1", "0.158", "0.158.0+build.3"])
    func compatibleLegacyAndNewCodexVersionsKeepTheirIdentity(version: String) {
        #expect(
            NativeSessionScanner.parse(
                provider: .codex, data: codexFixture(version: version), file: file, modified: Date())?.nativeSessionID
                == id)
    }

    @Test(arguments: [
        "0.0", "0.0.0", "0.0.99", "1.0.0", "9.0", "", "0.bad", "0.-1.0", "0.158.0.1", "0.158.0-", "0.158.0+",
    ])
    func unsupportedAndMalformedVersionsStayRejected(version: String) {
        #expect(
            NativeSessionScanner.parse(
                provider: .codex, data: codexFixture(version: version), file: file, modified: Date()) == nil)
    }

    @Test(arguments: [
        #"null"#,
        #"[]"#,
        #"{"id":"made-up","cwd":"/tmp","cli_version":"0.158.0"}"#,
        #"{"id":"11111111-1111-4111-8111-111111111111","cli_version":"0.158.0"}"#,
        #"{"id":"11111111-1111-4111-8111-111111111111","cwd":"relative","cli_version":"0.158.0"}"#,
        #"{"id":"11111111-1111-4111-8111-111111111111","cwd":"/tmp\u0000","cli_version":"0.158.0"}"#,
        #"{"id":"11111111-1111-4111-8111-111111111111","cwd":"/tmp","cli_version":158}"#,
    ])
    func malformedMetadataCannotSupplyOrReplaceACodexIdentity(payload: String) {
        let broken = Data("{\"type\":\"session_meta\",\"payload\":\(payload)}".utf8)
        #expect(NativeSessionScanner.parse(provider: .codex, data: broken, file: file, modified: Date()) == nil)
        let appended = codexFixture() + Data([0x0A]) + broken
        #expect(NativeSessionScanner.parse(provider: .codex, data: appended, file: file, modified: Date()) == nil)
    }

    @Test func brokenNewVersionMetadataStillReportsAReadProblem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try codexFixture(version: "0.158.0", nativeID: "broken").write(to: root.appendingPathComponent("rollout.jsonl"))
        let result = NativeSessionScanner.scan(provider: .codex, root: root, cache: [:], ignoringCache: false)
        #expect(result.sessions.isEmpty)
        #expect(result.loadError == "Some Codex history could not be read. Saved sessions are kept.")
    }

    @Test func modernCodexUserItemsAndNativeRenamesAreSearchable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(
            """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/tmp","cli_version":"0.157.1"}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md rules"},{"type":"input_text","text":"<environment_context>"}]}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Repair the login flow"}]}}
            """.utf8)
        try data.write(to: sessions.appendingPathComponent("rollout.jsonl"))
        let first = NativeSessionScanner.scan(provider: .codex, root: sessions, cache: [:], ignoringCache: false)
        #expect(first.sessions.first?.title == "Repair the login flow")
        let names = Data(
            "{\"id\":\"\(id)\",\"thread_name\":\"Login repair\",\"updated_at\":\"2026-09-27T10:00:00Z\"}\n".utf8)
        try names.write(to: root.appendingPathComponent("session_index.jsonl"))
        let renamed = NativeSessionScanner.scan(
            provider: .codex, root: sessions, cache: first.cache, ignoringCache: false)
        #expect(renamed.sessions.first?.title == "Login repair")
        #expect(renamed.sessions.first.map { SessionScanner.matches($0, query: "Login repair") } == true)
    }

    @Test func rejectsUnknownVersionsMissingIdentityAndMixedSessions() {
        #expect(
            NativeSessionScanner.parse(
                provider: .codex, data: codexFixture(version: "9.0"), file: file, modified: Date()) == nil)
        #expect(
            NativeSessionScanner.parse(
                provider: .codex, data: Data(#"{"type":"session_meta","payload":{"id":"made-up","cwd":"/tmp"}}"#.utf8),
                file: file, modified: Date()) == nil)
        let mixed = """
            {"type":"user","sessionId":"\(id)","cwd":"/tmp","version":"2.1.283"}
            {"type":"user","sessionId":"22222222-2222-4222-8222-222222222222","cwd":"/tmp","version":"2.1.283"}
            """
        #expect(
            NativeSessionScanner.parse(provider: .claudeCode, data: Data(mixed.utf8), file: file, modified: Date())
                == nil)
    }

    @Test func claudeBlockContentSuppliesTitleAndMeaningfulHistory() throws {
        let data = Data(
            """
            {"type":"user","sessionId":"\(id)","cwd":"/tmp","version":"2.1.283","message":{"content":[{"type":"image"},{"type":"text","text":"Fix the image layout"}]}}
            """.utf8)
        let parsed = try #require(
            NativeSessionScanner.parse(provider: .claudeCode, data: data, file: file, modified: Date()))
        #expect(parsed.summary == "Fix the image layout")
        #expect(parsed.hasObservedMessages)
        #expect(parsed.messageCount == 0)
    }

    @Test(arguments: ["0.157.1", "0.158.0"])
    func mixedCodexMetadataCannotRenameOrRetargetAnotherConversation(version: String) {
        let other = "22222222-2222-4222-8222-222222222222"
        let first = codexFixture(version: version)
        let mixedID = first + Data([0x0A]) + codexFixture(version: version, nativeID: other)
        #expect(NativeSessionScanner.parse(provider: .codex, data: mixedID, file: file, modified: Date()) == nil)
        let changedFolder = String(decoding: first, as: UTF8.self).replacingOccurrences(
            of: "/tmp/project", with: "/tmp/other")
        let mixedFolder = first + Data([0x0A]) + Data(changedFolder.utf8)
        #expect(NativeSessionScanner.parse(provider: .codex, data: mixedFolder, file: file, modified: Date()) == nil)
        let duplicate = first + Data([0x0A]) + first
        #expect(
            NativeSessionScanner.parse(provider: .codex, data: duplicate, file: file, modified: Date())?.nativeSessionID
                == id)
        let claude = """
            {"type":"user","sessionId":"\(id)","cwd":"/tmp/first","version":"2.1.283"}
            {"type":"user","sessionId":"\(id)","cwd":"/tmp/second","version":"2.1.283"}
            """
        #expect(
            NativeSessionScanner.parse(provider: .claudeCode, data: Data(claude.utf8), file: file, modified: Date())
                == nil)
    }

    @Test func unreadableOrFutureHistoryKeepsCachedConversationsWithoutWritingCLIData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        try codexFixture().write(to: file)
        let initial = NativeSessionScanner.scan(provider: .codex, root: root, cache: [:], ignoringCache: false)
        #expect(initial.sessions.count == 1)
        let unsupported = codexFixture(version: "9.0")
        try unsupported.write(to: file)
        let next = NativeSessionScanner.scan(provider: .codex, root: root, cache: initial.cache, ignoringCache: false)
        #expect(next.sessions == initial.sessions)
        #expect(next.loadError != nil)
        #expect(try Data(contentsOf: file) == unsupported)
        let missing = NativeSessionScanner.scan(
            provider: .codex, root: root.appendingPathComponent("missing"), cache: initial.cache, ignoringCache: false)
        #expect(missing.sessions == initial.sessions)
    }

    @Test func indexesNineHundredSessionsWithBoundedCacheAndSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<900 {
            var data = codexFixture(nativeID: String(format: "11111111-1111-4111-8111-%012d", index))
            data.append(0x0A)
            // Twenty realistic response records per conversation, not empty metadata files.
            for turn in 0..<20 {
                let record: [String: Any] = [
                    "type": "response_item",
                    "payload": [
                        "type": "message", "role": "assistant",
                        "content": [
                            [
                                "type": "output_text",
                                "text": String(repeating: "Validated source and regression test. ", count: 20)
                                    + "Turn \(turn)",
                            ]
                        ],
                    ],
                ]
                data.append(try JSONSerialization.data(withJSONObject: record))
                data.append(0x0A)
            }
            try data.write(to: root.appendingPathComponent("rollout-\(index).jsonl"))
        }
        let start = ContinuousClock.now
        let cold = NativeSessionScanner.scan(provider: .codex, root: root, cache: [:], ignoringCache: false)
        let coldDuration = start.duration(to: .now)
        let warmStart = ContinuousClock.now
        let warm = NativeSessionScanner.scan(provider: .codex, root: root, cache: cold.cache, ignoringCache: false)
        let warmDuration = warmStart.duration(to: .now)
        let searchStart = ContinuousClock.now
        let results = cold.sessions.filter { SessionScanner.matches($0, query: "API") }
        let searchDuration = searchStart.duration(to: .now)
        #expect(results.count == 900)
        #expect(warm.sessions == cold.sessions)
        #expect(cold.cache.values.allSatisfy { $0.contents.isEmpty })
        print("Native history 900 sessions: cold=\(coldDuration), cached=\(warmDuration), search=\(searchDuration)")
    }

    private func codexFixture(
        version: String = "0.157.1", nativeID: String? = nil, timestamp: String = "2026-09-27T10:00:00Z"
    ) -> Data {
        Data(
            """
            {"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(nativeID ?? id)","cwd":"/tmp/project","cli_version":"\(version)","source":"cli"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"Check the API"}}
            """.utf8)
    }
}
