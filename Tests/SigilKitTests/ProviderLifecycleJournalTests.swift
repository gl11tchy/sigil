import Foundation
import Testing

@testable import SigilKit

struct ProviderLifecycleJournalTests {
    let session = "11111111-1111-4111-8111-111111111111"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [CLIProvider.claudeCode, .devin, .cursor, .kimi])
    func unsupportedProviderCannotObserveEvenWithAJournal(provider: CLIProvider) throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(url: fixture.file, provider: provider, sessionID: session, notBefore: now)
        try fixture.append(
            try grok(type: "agent_message_chunk", turn: "one") + grok(type: "turn_completed", turn: "one"))
        #expect(!reader.canObserve)
        #expect(reader.poll().isEmpty)
    }

    @Test func grokCanObserveAJournalThatHasNotBeenCreatedYet() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let missing = fixture.root.appendingPathComponent("later.jsonl")
        let reader = ProviderLifecycleJournal(url: missing, provider: .grokBuild, sessionID: session, notBefore: now)
        #expect(reader.canObserve)
        #expect(!ProviderLifecycleJournal(url: missing, provider: .codex, sessionID: session).canObserve)
    }

    @Test func completeRequiresMatchingSessionTurnAndPostSubmissionTime() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(
            url: fixture.file, provider: .grokBuild, sessionID: session, notBefore: now)
        try fixture.append(try grok(type: "turn_completed", turn: "missing-start"))
        #expect(reader.poll().isEmpty)
        try fixture.append(try grok(type: "agent_message_chunk", turn: "old", time: now.addingTimeInterval(-1)))
        try fixture.append(try grok(type: "turn_completed", turn: "old"))
        #expect(reader.poll().isEmpty)
        try fixture.append(try grok(type: "agent_message_chunk", turn: "active"))
        #expect(reader.poll() == [.working])
        try fixture.append(try grok(type: "turn_completed", turn: "other"))
        try fixture.append(try grok(type: "turn_completed", turn: "active", nativeID: UUID().uuidString))
        #expect(reader.poll().isEmpty)
        let completed = try grok(type: "turn_completed", turn: "active")
        try fixture.append(completed)
        #expect(reader.poll() == [.idle])
        try fixture.append(completed)
        #expect(reader.poll().isEmpty)
    }

    @Test func fileReplacementOrTruncationCannotReplayACompletion() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(
            url: fixture.file, provider: .grokBuild, sessionID: session, notBefore: now)
        let records = try grok(type: "agent_message_chunk", turn: "one") + grok(type: "turn_completed", turn: "one")
        try fixture.append(records)
        #expect(reader.poll() == [.working, .idle])
        try records.write(to: fixture.file, options: .atomic)
        #expect(reader.poll() == [.unknown])
        #expect(reader.poll().isEmpty)
        try Data().write(to: fixture.file)
        #expect(reader.poll() == [.unknown])
        try fixture.append(try grok(type: "turn_completed", turn: "one"))
        #expect(reader.poll().isEmpty)
    }

    @Test func sameInodeRewriteBeyondTheOldSizeInvalidatesTurnEvidence() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(
            url: fixture.file, provider: .grokBuild, sessionID: session, notBefore: now)
        let start = try grok(type: "agent_message_chunk", turn: "old")
        try fixture.append(start)
        #expect(reader.poll() == [.working])
        let before = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.systemFileNumber] as? NSNumber
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x78, count: start.count + 20) + Data([0x0A]))
        try handle.close()
        try fixture.append(try grok(type: "turn_completed", turn: "old"))
        let after = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.systemFileNumber] as? NSNumber
        #expect(before == after)
        #expect(reader.poll() == [.unknown])
        #expect(reader.poll().isEmpty)
    }

    @Test func partialOversizedAndMalformedRecordsDoNotManufactureCompletion() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(
            url: fixture.file, provider: .grokBuild, sessionID: session, notBefore: now)
        let started = try grok(type: "agent_message_chunk", turn: "one")
        try fixture.append(Data(started.dropLast(5)))
        #expect(reader.poll().isEmpty)
        try fixture.append(Data(started.suffix(5)))
        #expect(reader.poll() == [.working])
        try fixture.append(Data(repeating: 0x78, count: 1_100_000))
        for _ in 0..<5 { #expect(reader.poll().isEmpty) }
        try fixture.append(Data("\nnot JSON\n".utf8))
        try fixture.append(try grok(type: "turn_completed", turn: "one", reason: "cancelled"))
        #expect(reader.poll() == [.interrupted])
    }

    @Test func codexMatchesNativeFileAndTurnBeforeCompleting() throws {
        let meta = Data(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"cwd\":\"/tmp\",\"cli_version\":\"0.157.1\"}}\n"
                .utf8)
        let fixture = try JournalFixture(initial: meta)
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(url: fixture.file, provider: .codex, sessionID: session, notBefore: now)
        var wrong = ProviderLifecycleJournal(
            url: fixture.file, provider: .codex, sessionID: UUID().uuidString, notBefore: now)
        #expect(reader.canObserve)
        #expect(!wrong.canObserve)
        try fixture.append(try codex(type: "task_started", turn: "one"))
        try fixture.append(try codex(type: "task_complete", turn: "different"))
        #expect(reader.poll() == [.working])
        #expect(wrong.poll().isEmpty)
        try fixture.append(try codex(type: "task_complete", turn: "one"))
        #expect(reader.poll() == [.idle])
    }

    @Test func appendedNativeMetadataInvalidatesExistingWriterEvidence() throws {
        let meta = Data(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"cwd\":\"/tmp\",\"cli_version\":\"0.157.1\"}}\n"
                .utf8)
        let fixture = try JournalFixture(initial: meta)
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(url: fixture.file, provider: .codex, sessionID: session, notBefore: now)
        try fixture.append(try codex(type: "task_started", turn: "one"))
        #expect(reader.poll() == [.working])
        try fixture.append(meta)
        try fixture.append(try codex(type: "task_complete", turn: "one"))
        #expect(reader.poll() == [.unknown])
        #expect(!reader.canObserve)
    }

    @Test func mixedNativeMetadataCannotValidateALifecycleReader() throws {
        let other = "22222222-2222-4222-8222-222222222222"
        let metadata = [session, other].map {
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\($0)\",\"cwd\":\"/tmp\",\"cli_version\":\"0.157.1\"}}\n"
        }.joined()
        let fixture = try JournalFixture(initial: Data(metadata.utf8))
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(url: fixture.file, provider: .codex, sessionID: other, notBefore: now)
        #expect(!reader.canObserve)
        try fixture.append(try codex(type: "task_started", turn: "one"))
        try fixture.append(try codex(type: "task_complete", turn: "one"))
        #expect(reader.poll().isEmpty)
    }

    @Test func realProcessJournalWritesAreObservedWithoutTitleOrOutputSignals() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(
            url: fixture.file, provider: .grokBuild, sessionID: session, notBefore: now)
        let records = try grok(type: "agent_message_chunk", turn: "one") + grok(type: "turn_completed", turn: "one")
        let source = fixture.root.appendingPathComponent("events")
        try records.write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cat \"$1\" >> \"$2\"", "journal-writer", source.path, fixture.file.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(reader.poll() == [.working, .idle])
    }

    private func grok(
        type: String, turn: String, time: Date? = nil, nativeID: String? = nil, reason: String = "end_turn"
    ) throws -> Data {
        try line([
            "timestamp": Int64((time ?? now).timeIntervalSince1970),
            "params": [
                "sessionId": nativeID ?? session,
                "_meta": [
                    "eventId": UUID().uuidString, "promptId": turn,
                    "agentTimestampMs": Int64((time ?? now).timeIntervalSince1970 * 1000),
                ],
                "update": ["sessionUpdate": type, "prompt_id": turn, "stop_reason": reason],
            ],
        ])
    }
    private func codex(type: String, turn: String) throws -> Data {
        try line(["timestamp": timestamp(now), "type": "event_msg", "payload": ["type": type, "turn_id": turn]])
    }
    private func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func line(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value) + Data([0x0A])
    }
}

private struct JournalFixture {
    let root: URL
    let file: URL
    init(initial: Data = Data()) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("journal.jsonl")
        try initial.write(to: file)
    }
    func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
