import Foundation
import Testing
import os

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

    @Test func brokenNewVersionMetadataShowsACompatibilityNotice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try codexFixture(version: "0.158.0", nativeID: "broken").write(to: root.appendingPathComponent("rollout.jsonl"))
        let result = NativeSessionScanner.scan(provider: .codex, root: root, cache: [:], ignoringCache: false)
        #expect(result.sessions.isEmpty)
        #expect(result.loadError == nil)
        #expect(result.notice?.contains("Codex history") == true)
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
        #expect(next.loadError == nil)
        #expect(next.notice?.contains("9.0") == true)
        #expect(try Data(contentsOf: file) == unsupported)
        let missing = NativeSessionScanner.scan(
            provider: .codex, root: root.appendingPathComponent("missing"), cache: initial.cache, ignoringCache: false)
        #expect(missing.sessions == initial.sessions)
    }

    @Test(arguments: ["summary", "partial", "major", "schema", "ambiguous", "symlink", "directory"])
    func unrecognizedFilesProtectOnlyTheirOwnCachedRow(kind: String) throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let held = try fixture.writeNative()
        let deleted = try fixture.writeNative(id: HistoryCompatibilityFixture.secondID, filename: "deleted.jsonl")
        let initial = NativeSessionScanner.scan(provider: .codex, root: fixture.codex, cache: [:], ignoringCache: false)
        #expect(initial.sessions.count == 2)
        let replacement: Data
        switch kind {
        case "summary": replacement = Data(#"{"type":"summary","summary":"Generated"}"#.utf8)
        case "partial": replacement = Data(#"{"type":"session_meta","payload":{"id":"unfinished""#.utf8)
        case "major": replacement = codexFixture(version: "1.0.0")
        case "schema": replacement = Data(#"{"type":"session_meta","payload":[]}"#.utf8)
        default:
            replacement = codexFixture() + Data([0x0A]) + codexFixture(nativeID: HistoryCompatibilityFixture.secondID)
        }
        if kind == "symlink" || kind == "directory" {
            try FileManager.default.removeItem(at: held)
            if kind == "symlink" {
                let target = try fixture.writeNative(filename: "generated-target")
                try FileManager.default.createSymbolicLink(at: held, withDestinationURL: target)
            } else {
                try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
            }
        } else {
            try replacement.write(to: held)
        }
        try FileManager.default.removeItem(at: deleted)
        let next = NativeSessionScanner.scan(
            provider: .codex, root: fixture.codex, cache: initial.cache, ignoringCache: false)
        #expect(next.loadError == nil)
        #expect(next.notice != nil)
        #expect(next.sessions.map(\.nativeSessionID) == [HistoryCompatibilityFixture.firstID])
        #expect(next.cache.count == 1)
        if kind != "symlink" && kind != "directory" {
            #expect(try Data(contentsOf: held) == replacement)
        }
        try FileManager.default.removeItem(at: held)
        let cleared = NativeSessionScanner.scan(
            provider: .codex, root: fixture.codex, cache: next.cache, ignoringCache: false)
        #expect(cleared.sessions.isEmpty)
        #expect(cleared.notice == nil)
        #expect(cleared.loadError == nil)
    }

    @Test(arguments: ["summary", "partial", "1.9.0"])
    func claudeCompatibilityFilesDoNotBlockAnOtherwiseCompleteScan(kind: String) throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let file = fixture.claude.appendingPathComponent("generated.jsonl")
        if kind == "1.9.0" {
            try fixture.writeNative(provider: .claudeCode, version: kind, filename: file.lastPathComponent)
        } else {
            let content = kind == "summary" ? #"{"type":"summary","summary":"Generated"}"# : #"{"type":"user""#
            try Data(content.utf8).write(to: file)
        }
        let result = NativeSessionScanner.scan(
            provider: .claudeCode, root: fixture.claude, cache: [:], ignoringCache: false)
        #expect(result.sessions.isEmpty)
        #expect(result.loadError == nil)
        #expect(result.notice?.contains("Claude Code history") == true)
        if kind == "1.9.0" { #expect(result.notice?.contains(kind) == true) }
    }

    @Test func inaccessibleNativeSubdirectoryPreservesCachedRowsAndReportsUncertainty() throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let blockedFile = try fixture.writeNative(filename: "blocked/held.jsonl")
        let deleted = try fixture.writeNative(id: HistoryCompatibilityFixture.secondID, filename: "deleted.jsonl")
        let initial = NativeSessionScanner.scan(provider: .codex, root: fixture.codex, cache: [:], ignoringCache: false)
        let blocked = blockedFile.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        try FileManager.default.removeItem(at: deleted)
        let next = NativeSessionScanner.scan(
            provider: .codex, root: fixture.codex, cache: initial.cache, ignoringCache: false)
        #expect(next.loadError != nil)
        #expect(Set(next.sessions.map(\.id)) == Set(initial.sessions.map(\.id)))
        #expect(next.coverage.uncertainRoots.contains(fixture.codex.path))
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

    @Test func claudeMiddleRenameSurvivesGrowthWithoutStreamingOldRecordsAgain() throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.remove() }
        let original = try fixture.longTranscript()
        try original.write(to: fixture.file)
        let coldMeter = ClaudeReadMeter()
        let cold = fixture.scan(reader: coldMeter.reader())
        #expect(cold.sessions.first?.title == "Older title")
        #expect(cold.notice == nil)
        let appended = fixture.padding(1024 * 1024)
        try fixture.append(appended)
        let meter = ClaudeReadMeter()
        let grown = fixture.scan(cache: cold.cache, reader: meter.reader())
        #expect(grown.sessions.first?.title == "Older title")
        #expect(grown.sessions.first?.createdAt == cold.sessions.first?.createdAt)
        let reads = meter.snapshot()
        #expect(reads.filter { $0.offset >= UInt64(original.count) }.reduce(0) { $0 + $1.count } == appended.count)
        // Continuity requires bounded reads of old anchors; old transcript records are not streamed again.
        #expect(reads.filter { $0.offset < UInt64(original.count) }.reduce(0) { $0 + $1.count } < 10 * 1024)
        #expect((coldMeter.snapshot() + reads).allSatisfy { $0.requested <= 1024 * 1024 })
        try fixture.append(fixture.rename("Newest 解析✨"))
        let renamed = fixture.scan(cache: grown.cache)
        #expect(renamed.sessions.first?.title == "Newest 解析✨")
        let unchangedMeter = ClaudeReadMeter()
        #expect(fixture.scan(cache: renamed.cache, reader: unchangedMeter.reader()).sessions == renamed.sessions)
        #expect(unchangedMeter.snapshot().isEmpty)
        #expect(renamed.cache.values.allSatisfy { $0.contents.isEmpty })
    }

    @Test(arguments: [1, 7, 31, NativeSessionScanner.chunkLimit])
    func claudeCompleteJSONAndUTF8SurviveChunkSplits(maximumRead: Int) throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.remove() }
        let rename = try ClaudeTranscriptFixture.record([
            "type": "custom-title", "customTitle": "解析 🌗 café",
            "padding": String(repeating: "x", count: NativeSessionScanner.chunkLimit),
        ])
        try (fixture.header() + rename).write(to: fixture.file)
        let meter = ClaudeReadMeter()
        let scanned = fixture.scan(reader: meter.reader(maximumRead: maximumRead))
        #expect(scanned.sessions.first?.title == "解析 🌗 café")
        #expect(scanned.notice == nil)
        #expect(meter.snapshot().allSatisfy { $0.count <= maximumRead && $0.requested <= 1024 * 1024 })
    }

    @Test func claudePartialUTF8AndExplicitClearCarryAcrossScans() throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.remove() }
        let rename = try fixture.rename("Renamed 🌗解析")
        let unicode = try #require(rename.range(of: Data("🌗".utf8)))
        let split = rename.distance(from: rename.startIndex, to: unicode.lowerBound) + 1
        try (fixture.header() + rename.prefix(split)).write(to: fixture.file)
        let partial = fixture.scan()
        #expect(partial.sessions.first?.title == "First generated prompt")
        #expect(partial.notice != nil)
        #expect(fixture.scan(cache: partial.cache).notice != nil)
        try fixture.append(Data(rename.dropFirst(split)))
        let completed = fixture.scan(cache: partial.cache)
        #expect(completed.sessions.first?.title == "Renamed 🌗解析")
        #expect(completed.notice == nil)
        try fixture.append(fixture.header(prompt: "A later generated prompt") + fixture.rename(""))
        let cleared = fixture.scan(cache: completed.cache)
        #expect(cleared.sessions.first?.title == "First generated prompt")
        try fixture.append(fixture.padding(1024 * 1024))
        #expect(fixture.scan(cache: cleared.cache).sessions.first?.title == "First generated prompt")
    }

    @Test func claudeLegacyCompleteEOFIsProjectedWithoutCommittingAPartialLine() throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.remove() }
        try Data(fixture.header().dropLast()).write(to: fixture.file)
        let first = fixture.scan()
        #expect(first.sessions.first?.title == "First generated prompt")
        #expect(first.notice == nil)
        try fixture.append(Data([10]) + Data(fixture.rename("EOF rename").dropLast()))
        let renamed = fixture.scan(cache: first.cache)
        #expect(renamed.sessions.first?.title == "EOF rename")
        try fixture.append(Data([10]))
        #expect(fixture.scan(cache: renamed.cache).sessions.first?.title == "EOF rename")
    }

    @Test(arguments: ["replacement", "truncation", "same-size", "growth-title", "growth-header", "growth-tail"])
    func claudeReplacementAndRewritesInvalidateIncrementalState(kind: String) throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.remove() }
        let original = try fixture.longTranscript()
        try original.write(to: fixture.file)
        let first = fixture.scan()
        let modified = try #require(first.cache[fixture.file.path]?.modificationDate)
        var replacement = Data(
            String(decoding: original, as: UTF8.self).replacingOccurrences(
                of: "Older title", with: "Newer title"
            ).utf8)
        var expected = "Newer title"
        switch kind {
        case "truncation": replacement = try fixture.header() + fixture.rename("Newer title")
        case "growth-title": replacement.append(fixture.padding(1024 * 1024))
        case "growth-header":
            replacement = Data(
                String(decoding: original, as: UTF8.self).replacingOccurrences(
                    of: "First generated prompt", with: "Other generated prompt"
                ).utf8)
            replacement.append(try fixture.rename("") + fixture.padding(1024 * 1024))
            expected = "Other generated prompt"
        case "growth-tail":
            replacement = original
            replacement[replacement.count - 4] = UInt8(ascii: "y")
            replacement.append(fixture.padding(1024 * 1024))
            expected = "Older title"
        default: break
        }
        try replacement.write(to: fixture.file, options: kind == "replacement" ? .atomic : [])
        if kind == "replacement" || kind == "same-size" {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fixture.file.path)
        }
        let meter = ClaudeReadMeter()
        let scanned = fixture.scan(cache: first.cache, reader: meter.reader())
        #expect(scanned.sessions.first?.title == expected)
        #expect(scanned.loadError == nil)
        #expect(
            meter.snapshot().contains {
                $0.offset == 0 && $0.requested == min(replacement.count, NativeSessionScanner.chunkLimit)
            })
        #expect(scanned.cache[fixture.file.path]?.claudeScan?.offset == UInt64(replacement.count))
    }

    @Test func claudeOversizedRecordsDiscardThroughNewlineWithBoundedState() throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.remove() }
        let oversized = Data(
            ("{\"type\":\"custom-title\",\"customTitle\":\""
                + String(
                    repeating: "x", count: NativeSessionScanner.prefixLimit + NativeSessionScanner.chunkLimit)).utf8)
        try (fixture.header() + fixture.rename("Kept title") + oversized).write(to: fixture.file)
        let meter = ClaudeReadMeter()
        let first = fixture.scan(reader: meter.reader())
        #expect(first.sessions.first?.title == "Kept title")
        #expect(first.notice != nil)
        #expect(first.cache[fixture.file.path]?.claudeScan?.discardingOversized == true)
        let unchanged = ClaudeReadMeter()
        #expect(fixture.scan(cache: first.cache, reader: unchanged.reader()).notice != nil)
        #expect(unchanged.snapshot().isEmpty)
        try fixture.append(
            Data((String(repeating: "x", count: 1024 * 1024) + "\"}\n").utf8) + fixture.rename("After oversized"))
        let next = fixture.scan(cache: first.cache, reader: meter.reader())
        #expect(next.sessions.first?.title == "After oversized")
        let state = try #require(next.cache[fixture.file.path]?.claudeScan)
        #expect(state.remainder.count <= NativeSessionScanner.prefixLimit)
        #expect(state.prefix.count <= NativeSessionScanner.anchorLimit)
        #expect(state.tail.count <= NativeSessionScanner.anchorLimit)
        #expect(state.anchors.count <= 5)
        #expect(meter.snapshot().allSatisfy { $0.requested <= 1024 * 1024 })
    }

    @Test(arguments: [false, true])
    func claudeCancelledScanKeepsCoverageAndDoesNotPublishPartialProgress(warm: Bool) throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.remove() }
        try fixture.longTranscript().write(to: fixture.file)
        let old = warm ? fixture.scan() : nil
        try fixture.append(fixture.padding(1024 * 1024) + fixture.rename("After cancellation"))
        let meter = ClaudeReadMeter()
        let cancelled = fixture.scan(cache: old?.cache ?? [:], reader: meter.reader(cancelAfter: 2))
        #expect(cancelled.sessions == old?.sessions ?? [])
        #expect(cancelled.cache == old?.cache ?? [:])
        #expect(cancelled.loadError != nil)
        #expect(cancelled.coverage.uncertainRoots.contains(fixture.root.path))
        #expect(meter.snapshot().count == 2)
        #expect(fixture.scan(cache: cancelled.cache).sessions.first?.title == "After cancellation")
    }

    @Test(arguments: ["append", "replacement"])
    func claudeMutationDuringReadKeepsPreviousValidatedRow(kind: String) throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.remove() }
        try fixture.longTranscript().write(to: fixture.file)
        let old = fixture.scan()
        try fixture.append(fixture.rename("Before racing write"))
        let file = fixture.file
        let replacement = try fixture.header() + fixture.rename("Replacement")
        let meter = ClaudeReadMeter()
        let reader = meter.reader(onFirstRead: {
            if kind == "replacement" {
                try replacement.write(to: file, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("{\"type\":\"progress\"}\n".utf8))
            }
        })
        let raced = fixture.scan(cache: old.cache, reader: reader)
        #expect(raced.sessions == old.sessions)
        #expect(raced.cache == old.cache)
        #expect(raced.loadError != nil)
    }

    @Test func claudeMiddleIdentityConflictCannotSupplyARename() throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.remove() }
        let original = try fixture.longTranscript()
        try original.write(to: fixture.file)
        let known = fixture.scan()
        let mixed =
            try fixture.header() + fixture.padding(700 * 1024)
            + fixture.header(id: "22222222-2222-4222-8222-222222222222") + fixture.rename("Wrong identity")
            + fixture.padding(200 * 1024)
        try mixed.write(to: fixture.file)
        let cold = fixture.scan()
        #expect(cold.sessions.isEmpty)
        #expect(cold.notice != nil)
        let kept = fixture.scan(cache: known.cache)
        #expect(kept.sessions == known.sessions)
        #expect(kept.notice != nil)
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

private struct ClaudeTranscriptFixture {
    let root: URL
    var file: URL { root.appendingPathComponent("generated-claude.jsonl") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rea-1266-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func record(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) + Data([10])
    }

    func header(prompt: String = "First generated prompt", id: String = "11111111-1111-4111-8111-111111111111") throws
        -> Data
    {
        try Self.record([
            "type": "user", "sessionId": id, "cwd": "/tmp/generated-project", "version": "2.1.283",
            "timestamp": "2026-10-11T03:00:00Z", "message": ["content": prompt],
        ])
    }

    func rename(_ title: String) throws -> Data {
        try Self.record(["type": "custom-title", "customTitle": title])
    }

    func padding(_ minimum: Int) -> Data {
        let row = Data(("{\"type\":\"progress\",\"data\":\"" + String(repeating: "x", count: 1000) + "\"}\n").utf8)
        var data = Data()
        while data.count < minimum { data.append(row) }
        return data
    }

    func longTranscript() throws -> Data {
        try header() + padding(700 * 1024) + rename("Older title") + padding(200 * 1024)
    }

    func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func scan(cache: [String: SessionCacheEntry] = [:], reader: NativeSessionScanner.ContentReader = .disk)
        -> SessionScanner.Result
    {
        NativeSessionScanner.scan(
            provider: .claudeCode, root: root, cache: cache, ignoringCache: false, contentReader: reader)
    }
}

private final class ClaudeReadMeter: Sendable {
    struct Read: Sendable {
        var offset: UInt64
        var count: Int
        var requested: Int
    }
    let reads = OSAllocatedUnfairLock(initialState: [Read]())

    func snapshot() -> [Read] { reads.withLock { $0 } }

    func reader(
        maximumRead: Int = NativeSessionScanner.chunkLimit, cancelAfter: Int? = nil,
        onFirstRead: (@Sendable () throws -> Void)? = nil
    ) -> NativeSessionScanner.ContentReader {
        NativeSessionScanner.ContentReader(
            read: { handle, offset, count in
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: min(count, maximumRead)) ?? Data()
                let first = self.reads.withLock { reads in
                    reads.append(Read(offset: offset, count: data.count, requested: count))
                    return reads.count == 1
                }
                if first { try onFirstRead?() }
                return data
            },
            isCancelled: { cancelAfter.map { self.snapshot().count >= $0 } ?? Task.isCancelled })
    }
}
