import Darwin
import Foundation
import Testing

@testable import SigilKit

struct ProviderLifecycleJournalTests {
    let session = "11111111-1111-4111-8111-111111111111"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func catchUpRestoresTheFirstActiveTurnAndThenTailsItsCompletion() throws {
        let fixture = try JournalFixture(initial: metadata() + codex(type: "task_started", turn: "first"))
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(
            url: fixture.file, provider: .codex, sessionID: session, notBefore: now, readFromBeginning: true)
        #expect(reader.isCatchingUp)
        #expect(reader.poll() == [.working])
        #expect(!reader.isCatchingUp)
        try fixture.append(try codex(type: "task_complete", turn: "other"))
        #expect(reader.poll().isEmpty)
        try fixture.append(try codex(type: "task_complete", turn: "first"))
        #expect(reader.poll() == [.idle])
    }

    @Test func completedCatchUpPublishesOnlyTheFinalStateAndRejectsPreLaunchEvents() throws {
        let fixture = try JournalFixture(
            initial: metadata()
                + codex(type: "task_started", turn: "old", time: now.addingTimeInterval(-1))
                + codex(type: "task_complete", turn: "old")
                + codex(type: "task_started", turn: "first")
                + codex(type: "task_complete", turn: "first"))
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(
            url: fixture.file, provider: .codex, sessionID: session, notBefore: now, readFromBeginning: true)
        #expect(reader.poll() == [.idle])
        #expect(reader.poll().isEmpty)
        try fixture.append(try codex(type: "task_complete", turn: "first"))
        #expect(reader.poll().isEmpty)
    }

    @Test func catchUpIsBoundedAndKeepsPartialRecordsUntilTheyFinish() throws {
        let started = try codex(type: "task_started", turn: "first")
        let complete = try codex(type: "task_complete", turn: "first")
        let fixture = try JournalFixture(
            initial: metadata() + line(["type": "fixture", "padding": String(repeating: "x", count: 300_000)])
                + started + complete.dropLast(3))
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(
            url: fixture.file, provider: .codex, sessionID: session, notBefore: now, readFromBeginning: true)
        #expect(reader.poll().isEmpty)
        #expect(reader.isCatchingUp)
        #expect(reader.poll() == [.working])
        #expect(!reader.isCatchingUp)
        try fixture.append(Data(complete.suffix(3)))
        #expect(reader.poll() == [.idle])
    }

    @Test func aSecondMetadataHeaderDuringCatchUpInvalidatesEvenTheSameIdentity() throws {
        let fixture = try JournalFixture(initial: metadata() + codex(type: "task_started", turn: "first"))
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(
            url: fixture.file, provider: .codex, sessionID: session, notBefore: now, readFromBeginning: true)
        try fixture.append(try metadata())
        #expect(reader.poll() == [.working])
        #expect(reader.poll() == [.unknown])
        #expect(!reader.canObserve)
    }

    @Test(arguments: ["replace", "truncate", "rewrite"])
    func anOwnedAttachmentRejectsFileChangesBeforeItsFirstRead(change: String) throws {
        let fixture = try JournalFixture(initial: metadata() + codex(type: "task_started", turn: "first"))
        defer { fixture.cleanup() }
        let (transcript, _) = try ownedTranscript(fixture)
        var reader = ProviderLifecycleJournal(transcript: transcript)
        #expect(reader.canObserve)
        if change == "replace" {
            try (metadata() + codex(type: "task_complete", turn: "first")).write(to: fixture.file, options: .atomic)
        } else if change == "truncate" {
            try Data().write(to: fixture.file)
        } else {
            let handle = try FileHandle(forWritingTo: fixture.file)
            defer { try? handle.close() }
            try handle.write(contentsOf: metadata(version: "1.158.0"))
        }
        #expect(reader.poll() == [.unknown])
        #expect(!reader.canObserve)
        #expect(reader.poll().isEmpty)
    }

    @Test(arguments: [false, true])
    func lostOrChangingOwnershipDiscardsTheWholePoll(afterRead: Bool) throws {
        let fixture = try JournalFixture(initial: metadata() + codex(type: "task_started", turn: "first"))
        defer { fixture.cleanup() }
        let (transcript, observations) = try ownedTranscript(fixture)
        var reader = ProviderLifecycleJournal(transcript: transcript)
        observations.allowReads(afterRead ? 1 : 0)
        #expect(reader.poll() == [.unknown])
        #expect(!reader.canObserve)
    }

    @Test func aFreshOwnedReaderAfterInterruptionDoesNotReplayLaunchHistory() throws {
        let fixture = try JournalFixture(
            initial: metadata() + codex(type: "task_started", turn: "old") + codex(type: "task_complete", turn: "old"))
        defer { fixture.cleanup() }
        let (transcript, _) = try ownedTranscript(fixture)
        var reader = ProviderLifecycleJournal(transcript: transcript, readFromBeginning: false)
        #expect(!reader.isCatchingUp)
        #expect(reader.poll().isEmpty)
        try fixture.append(try codex(type: "task_started", turn: "new") + codex(type: "task_complete", turn: "new"))
        #expect(reader.poll() == [.working, .idle])
    }

    @Test(arguments: ["replace", "truncate", "rewrite"])
    func aFileMutationAtTheFinalLeaseCannotPublishTheReadBatch(change: String) throws {
        let initial = try metadata() + codex(type: "task_started", turn: "first")
        let fixture = try JournalFixture(initial: initial)
        defer { fixture.cleanup() }
        let (transcript, observations) = try ownedTranscript(fixture)
        var reader = ProviderLifecycleJournal(transcript: transcript)
        observations.mutateAfterRead {
            if change == "replace" {
                try? initial.write(to: fixture.file, options: .atomic)
            } else if change == "truncate" {
                try? Data().write(to: fixture.file)
            } else {
                let rewritten = Data(
                    String(decoding: initial, as: UTF8.self).replacingOccurrences(of: "0.158.0", with: "1.158.0").utf8)
                try? rewritten.write(to: fixture.file)
            }
        }
        #expect(reader.poll() == [.unknown])
        #expect(!reader.canObserve)
    }

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

    @Test(arguments: ["0.157.1", "0.158.0", "0.158.0-alpha.2"])
    func codexMatchesNativeFileAndTurnBeforeCompleting(version: String) throws {
        let meta = Data(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"cwd\":\"/tmp\",\"cli_version\":\"\(version)\"}}\n"
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

    @Test func newerHistoryDoesNotCertifyUnsupportedOrMalformedLifecycleEvents() throws {
        let meta = try line([
            "type": "session_meta", "payload": ["id": session, "cwd": "/tmp", "cli_version": "0.158.0"],
        ])
        let fixture = try JournalFixture(initial: meta)
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(url: fixture.file, provider: .codex, sessionID: session, notBefore: now)
        // A supported history envelope alone cannot prove a start or completion.
        try fixture.append(try codex(type: "task_complete", turn: "missing-start"))
        try fixture.append(try codex(type: "future_task_started", turn: "future"))
        try fixture.append(try codex(type: "task_complete", turn: "future"))
        try fixture.append(
            try line([
                "timestamp": timestamp(now), "type": "event_msg", "payload": ["type": "task_started", "turn_id": 1],
            ]))
        #expect(reader.poll().isEmpty)
        try fixture.append(try codex(type: "task_started", turn: "active"))
        #expect(reader.poll() == [.working])
        try fixture.append(try codex(type: "future_task_complete", turn: "active"))
        try fixture.append(
            try line([
                "timestamp": timestamp(now), "type": "response_item",
                "payload": ["type": "task_complete", "turn_id": "active"],
            ]))
        try fixture.append(
            try line([
                "timestamp": timestamp(now), "type": "event_msg", "payload": ["type": "task_complete"],
            ]))
        try fixture.append(
            try line([
                "timestamp": "bad", "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "active"],
            ]))
        #expect(reader.poll().isEmpty)
        try fixture.append(try codex(type: "task_complete", turn: "active"))
        #expect(reader.poll() == [.idle])
    }

    @Test func continuedCodexReaderKeepsTheActiveTurnAndTracksTheQueuedTurn() throws {
        let metadata = try line([
            "type": "session_meta", "payload": ["id": session, "cwd": "/tmp", "cli_version": "0.158.0"],
        ])
        let fixture = try JournalFixture(initial: metadata)
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(url: fixture.file, provider: .codex, sessionID: session, notBefore: now)
        try fixture.append(try codex(type: "task_started", turn: "t1"))
        #expect(reader.poll() == [.working])

        // A second submission keeps this reader, including its active turn and offset.
        var continued = reader
        let complete1 = try codex(type: "task_complete", turn: "t1")
        try fixture.append(complete1)
        #expect(continued.poll() == [.idle])
        try fixture.append(complete1)
        #expect(continued.poll().isEmpty)
        let start2 = try codex(type: "task_started", turn: "t2")
        try fixture.append(start2)
        #expect(continued.poll() == [.working])
        try fixture.append(start2 + complete1)
        #expect(continued.poll().isEmpty)
        try fixture.append(try codex(type: "task_complete", turn: "t2"))
        #expect(continued.poll() == [.idle])
    }

    @Test func endingThePreviousCodexTurnCannotCompleteTheQueuedTurn() throws {
        let metadata = try line([
            "type": "session_meta", "payload": ["id": session, "cwd": "/tmp", "cli_version": "0.158.0"],
        ])
        let fixture = try JournalFixture(initial: metadata)
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(url: fixture.file, provider: .codex, sessionID: session, notBefore: now)
        try fixture.append(try codex(type: "task_started", turn: "t1"))
        #expect(reader.poll() == [.working])
        try fixture.append(try codex(type: "task_started", turn: "t2"))
        #expect(reader.poll() == [.working])
        try fixture.append(try codex(type: "task_complete", turn: "t1"))
        #expect(reader.poll().isEmpty)
        try fixture.append(try codex(type: "turn_aborted", turn: "t2"))
        #expect(reader.poll() == [.interrupted])
        try fixture.append(try codex(type: "task_complete", turn: "t2"))
        #expect(reader.poll().isEmpty)
    }

    @Test(arguments: ["1.0.0", "malformed"])
    func unsupportedOrBrokenMetadataCannotValidateLifecycle(version: String) throws {
        let meta = try line([
            "type": "session_meta", "payload": ["id": session, "cwd": "/tmp", "cli_version": version],
        ])
        let fixture = try JournalFixture(initial: meta)
        defer { fixture.cleanup() }
        var reader = ProviderLifecycleJournal(url: fixture.file, provider: .codex, sessionID: session, notBefore: now)
        try fixture.append(try codex(type: "task_started", turn: "one"))
        try fixture.append(try codex(type: "task_complete", turn: "one"))
        #expect(reader.poll().isEmpty)
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
    private func codex(type: String, turn: String, time: Date? = nil) throws -> Data {
        try line([
            "timestamp": timestamp(time ?? now), "type": "event_msg", "payload": ["type": type, "turn_id": turn],
        ])
    }
    private func metadata(version: String = "0.158.0") throws -> Data {
        try line(["type": "session_meta", "payload": ["id": session, "cwd": "/tmp", "cli_version": version]])
    }
    private func ownedTranscript(_ fixture: JournalFixture) throws -> (CodexSessionBinding.Transcript, JournalOwnership)
    {
        var info = stat()
        #expect(lstat(fixture.file.path, &info) == 0)
        let file = ProcessOpenFiles.FileIdentity(
            path: GrokPaths.canonicalPath(fixture.file.path), device: UInt32(bitPattern: info.st_dev),
            inode: info.st_ino)
        let process = ChildProcessGeneration(pid: 42, seconds: 1, microseconds: 0)
        let observations = JournalOwnership(
            ProcessOpenFiles.Snapshot(
                nodes: [ProcessOpenFiles.Node(generation: process, parent: getpid())],
                files: [file: .init(identity: file, writable: true, bornAt: 2)]))
        let parsed = try #require(
            NativeSessionScanner.parse(
                provider: .codex, data: Data(contentsOf: fixture.file), file: fixture.file, modified: now))
        let resolved = CodexSessionBinding.resolveTranscript(
            process: process, historyRoot: fixture.root, sessions: [parsed],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            snapshot: { _, _ in observations.read() })
        let transcript = try #require(resolved)
        return (transcript, observations)
    }
    private func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func line(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value) + Data([0x0A])
    }
}

/// Entirely synthetic kernel receipts; no process enumeration is needed.
private final class JournalOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: ProcessOpenFiles.Snapshot
    private var remaining: Int?
    private var mutate: (@Sendable () -> Void)?
    private var readsUntilMutation = 0
    init(_ snapshot: ProcessOpenFiles.Snapshot) { self.snapshot = snapshot }
    func allowReads(_ count: Int) { lock.withLock { remaining = count } }
    func mutateAfterRead(_ mutate: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.mutate = mutate
            readsUntilMutation = 2
        }
    }
    func read() -> ProcessOpenFiles.Snapshot? {
        lock.withLock {
            if mutate != nil {
                readsUntilMutation -= 1
                if readsUntilMutation == 0 {
                    mutate?()
                    mutate = nil
                }
            }
            if let count = remaining {
                guard count > 0 else { return nil }
                remaining = count - 1
            }
            return snapshot
        }
    }
}

private struct JournalFixture: Sendable {
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
