import Foundation
import Observation
import Testing
import os

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

    @Test func malformedEntriesAreReportedWithoutAborting() async throws {
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
        #expect(harness.store.historyNotice?.contains("4 session summary file(s)") == true)
        #expect(!harness.store.isLoading)
        let ids = Set(harness.store.sessions.map(\.id))
        #expect(
            ids == [
                "019f780a-34d7-7993-aadc-f23a46c40a73",
                "019f8cfd-a25d-7d73-aecb-812cca14bc0e",
            ]
        )
    }

    @Test func aMissingRootBeforeTheFirstSessionIsAnEmptyListNotAnError() async {
        // A fresh Grok install has no sessions folder until the first chat.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sigil-missing-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(root: missing)
        await store.scan(ignoringCache: false)
        #expect(store.sessions.isEmpty)
        #expect(store.loadError == nil)
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

    @Test func startDiscoversRootCreatedAfterMissingReload() async throws {
        let timing = SessionStoreTiming(
            debounceDelay: .milliseconds(50),
            maximumDebounceDelay: .milliseconds(150),
            watcherRetryDelay: .milliseconds(100),
            watcherLatency: 0.05
        )
        let harness = try FixtureHarness(createRoot: false, timing: timing)
        defer { harness.tearDown() }

        harness.store.start()
        await harness.store.reload()
        #expect(harness.store.sessions.isEmpty)
        #expect(harness.store.loadError == nil)

        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )

        try await waitUntil(timeout: .seconds(4)) {
            harness.store.sessions.map(\.id) == ["019ffeab-c76b-7fe1-be40-508369febd51"]
                && harness.store.loadError == nil
        }
    }

    @Test func watcherRecoversAfterRootIsDeletedAndRecreated() async throws {
        let timing = SessionStoreTiming(
            debounceDelay: .milliseconds(50),
            maximumDebounceDelay: .milliseconds(150),
            watcherRetryDelay: .milliseconds(100),
            watcherLatency: 0.05
        )
        let harness = try FixtureHarness(timing: timing)
        defer { harness.tearDown() }
        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )
        harness.store.start()
        try await waitUntil(timeout: .seconds(4)) {
            harness.store.sessions.map(\.id) == ["019ffeab-c76b-7fe1-be40-508369febd51"]
        }

        try FileManager.default.removeItem(at: harness.root)
        try await waitUntil(timeout: .seconds(4)) {
            harness.store.loadError?.contains("does not exist") == true
        }
        try harness.write(
            fixture: "full.json",
            cwd: "/Users/exec/Documents/keyholding-v0-v2",
            id: "019f780a-34d7-7993-aadc-f23a46c40a73"
        )

        try await waitUntil(timeout: .seconds(4)) {
            harness.store.sessions.map(\.id) == ["019f780a-34d7-7993-aadc-f23a46c40a73"]
                && harness.store.loadError == nil
        }
    }

    @Test func retryLoopRescansARootDeletedBeforeFSEventsReportsIt() async throws {
        let timing = SessionStoreTiming(
            debounceDelay: .milliseconds(50),
            maximumDebounceDelay: .milliseconds(150),
            watcherRetryDelay: .milliseconds(50),
            watcherLatency: 0.05
        )
        let harness = try FixtureHarness(timing: timing)
        defer { harness.tearDown() }
        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )
        harness.store.start()
        try await waitUntil(timeout: .seconds(4)) {
            harness.store.sessions.map(\.id) == ["019ffeab-c76b-7fe1-be40-508369febd51"]
        }

        // Under load a retry tick can stop the stream before FSEvents delivers
        // the deletion, which drops the event. Stop it first to force that order,
        // and let queued scans finish so none of them sees the deletion.
        harness.store.watcher.stop()
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.removeItem(at: harness.root)

        try await waitUntil(timeout: .seconds(4)) {
            harness.store.loadError?.contains("does not exist") == true
        }
    }

    @Test func aMissingRootDoesNotRescanOnUnrelatedFolderChanges() async throws {
        // Without ~/.grok the nearest existing folder is the home folder;
        // its churn must not drive scans.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sigil-missing-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = ScanRecorder()
        let store = SessionStore(
            root: base.appendingPathComponent("grok/sessions", isDirectory: true),
            timing: SessionStoreTiming(
                debounceDelay: .milliseconds(50),
                maximumDebounceDelay: .milliseconds(150),
                watcherRetryDelay: .seconds(30),
                watcherLatency: 0.05
            ),
            scanOperation: { root, cache, _ in
                await recorder.record()
                return SessionScanner.scan(root: root, cache: cache)
            }
        )
        store.start()
        defer { store.stop() }
        try await waitUntil { !store.isLoading }
        try await Task.sleep(for: .milliseconds(400))
        let baseline = await recorder.count

        for index in 0..<5 {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent("unrelated-\(index)/child"),
                withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(500))

        #expect(await recorder.count == baseline)
    }

    @Test func continuousEventsCannotStarveScans() async throws {
        let recorder = ScanRecorder()
        let timing = SessionStoreTiming(
            debounceDelay: .milliseconds(100),
            maximumDebounceDelay: .milliseconds(220),
            watcherRetryDelay: .seconds(30),
            watcherLatency: 0.05
        )
        let harness = try FixtureHarness(
            timing: timing,
            scanOperation: { root, cache, _ in
                await recorder.record()
                return SessionScanner.scan(root: root, cache: cache)
            }
        )
        defer { harness.tearDown() }
        harness.store.start()
        try await waitUntil { !harness.store.isLoading }
        try await Task.sleep(for: .milliseconds(180))
        let baseline = await recorder.count

        var scannedDuringEventStream = false
        for _ in 0..<12 {
            harness.store.scheduleDebouncedScan()
            try await Task.sleep(for: .milliseconds(35))
            if await recorder.count > baseline {
                scannedDuringEventStream = true
            }
        }

        #expect(scannedDuringEventStream)
    }

    @Test(arguments: SessionQueryCase.all)
    func searchFindsAndOrdersSessions(_ queryCase: SessionQueryCase) async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.installOrderingFixtures()

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.sessions.map(\.id) == ["a1", "b1", "g1", "a2", "b2"])
        #expect(harness.store.search(queryCase.query).map(\.id) == queryCase.expectedIDs)
    }

    @Test func searchFollowsTheLatestScan() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )
        await harness.store.scan(ignoringCache: false)
        #expect(harness.store.search("keyholding").isEmpty)

        try harness.write(
            fixture: "full.json",
            cwd: "/Users/exec/Documents/keyholding-v0-v2",
            id: "019f780a-34d7-7993-aadc-f23a46c40a73"
        )
        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.search("keyholding").map(\.id) == ["019f780a-34d7-7993-aadc-f23a46c40a73"])
        #expect(harness.store.search("Users exec").count == 2)
    }

    @Test func emptySearchDoesNotComputeDisplayedTitleOrBoost() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.installOrderingFixtures()
        await harness.store.scan(ignoringCache: false)

        var displayedTitleCalls = 0
        var boostCalls = 0
        let boost: (GrokSession) -> Int = { _ in
            boostCalls += 1
            return 99
        }
        let displayedTitle: (GrokSession) -> String = { session in
            displayedTitleCalls += 1
            return session.title
        }

        let empty = harness.store.search("", boost: boost, displayedTitle: displayedTitle)
        #expect(empty.map(\.id) == harness.store.sessions.map(\.id))
        #expect(displayedTitleCalls == 0)
        #expect(boostCalls == 0)

        displayedTitleCalls = 0
        let whitespace = harness.store.search("  \n\t ", boost: boost, displayedTitle: displayedTitle)
        #expect(whitespace.map(\.id) == harness.store.sessions.map(\.id))
        #expect(displayedTitleCalls == 0)
        #expect(boostCalls == 0)

        displayedTitleCalls = 0
        _ = harness.store.search("alpha", displayedTitle: displayedTitle)
        #expect(displayedTitleCalls == harness.store.sessions.count)
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

    @Test func cacheDetectsSameSizeSameModificationDateReplacement() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        var object = try FixtureHarness.jsonObject("full.json")
        object["session_summary"] = "Initial"
        let url = try harness.write(
            json: object,
            cwd: "/Users/exec/Documents/keyholding-v0-v2",
            id: "019f780a-34d7-7993-aadc-f23a46c40a73"
        )
        await harness.store.scan(ignoringCache: false)
        let initialValues = try url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let initialDate = try #require(initialValues.contentModificationDate)
        let initialSize = try #require(initialValues.fileSize)

        object["session_summary"] = "Changed"
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            .write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: initialDate],
            ofItemAtPath: url.path
        )
        let changedValues = try url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        #expect(changedValues.fileSize == initialSize)
        #expect(changedValues.contentModificationDate == initialDate)

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.sessions.first?.title == "Changed")
    }

    @Test func forcedReloadIsNotDiscardedByLaterCachedScan() async throws {
        let recorder = ScanRecorder()
        let fresh = GrokSession(
            id: "fresh",
            cwd: "/fresh",
            summary: "Fresh forced result",
            createdAt: .distantPast,
            updatedAt: .distantFuture,
            messageCount: 1,
            modelID: nil,
            agentName: nil,
            reasoningEffort: nil,
            directory: URL(fileURLWithPath: "/sessions/fresh")
        )
        let entry = SessionCacheEntry(
            modificationDate: .distantPast,
            size: 2,
            contents: Data("{}".utf8),
            session: fresh
        )
        let store = SessionStore(
            root: URL(fileURLWithPath: "/unused"),
            timing: SessionStoreTiming(),
            scanOperation: { _, cache, ignoringCache in
                await recorder.record(forced: ignoringCache.ignoresGrokCache)
                if ignoringCache.ignoresGrokCache {
                    try? await Task.sleep(for: .milliseconds(180))
                    return SessionScanner.Result(
                        sessions: [fresh],
                        cache: [fresh.directory.path: entry],
                        loadError: nil
                    )
                }
                return SessionScanner.Result(
                    sessions: cache.values.map(\.session),
                    cache: cache,
                    loadError: nil
                )
            }
        )
        defer { store.stop() }

        let reload = Task { await store.reload() }
        try await waitUntilAsync { await recorder.forcedCount > 0 }
        await store.scan(ignoringCache: false)
        await reload.value
        try await waitUntilAsync { await recorder.cachedCount == 1 }
        try await waitUntil { !store.isLoading && store.sessions.map(\.id) == ["fresh"] }

        let cachedCount = await recorder.cachedCount
        #expect(cachedCount == 1)
        #expect(store.sessions.map(\.id) == ["fresh"])
    }

    @Test(arguments: [false, true])
    func cancelledProductionDetachedScanCannotPublish(forced: Bool) async throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let held = try fixture.writeNative(provider: .claudeCode, version: "2.1.283")
        let initial =
            try Data(contentsOf: held) + Data("\n{\"type\":\"custom-title\",\"customTitle\":\"Kept title\"}\n".utf8)
        try initial.write(to: held)
        let unsupported = fixture.claude.appendingPathComponent("unsupported.jsonl")
        try Data("{\"type\":\"summary\",\"summary\":\"Generated compatibility notice\"}\n".utf8).write(to: unsupported)
        let gate = DetachedHistoryReadGate()
        let store = SessionStore(
            root: fixture.grok, timing: SessionStoreTiming(), nativeRoots: [(.claudeCode, fixture.claude)],
            nativeContentReader: gate.reader)
        defer { store.stop() }
        await store.reload()
        #expect(store.sessions.first?.title == "Kept title")
        let previous = store.sessions
        let notice = try #require(store.historyNotice)
        let applied = store.appliedScanSequence
        #expect(store.loadError == nil)
        #expect(!store.canPruneMissingProjects)
        try FileManager.default.removeItem(at: unsupported)
        try (initial + Data("{\"type\":\"custom-title\",\"customTitle\":\"Fresh title\"}\n".utf8)).write(to: held)
        gate.arm()
        let operation = Task {
            if forced { await store.reload() } else { await store.scan(ignoringCache: false) }
        }
        defer {
            operation.cancel()
            gate.release()
        }
        try await waitUntil { gate.isWaiting }
        let waiting = gate.isWaiting
        #expect(waiting)
        guard waiting else {
            operation.cancel()
            gate.release()
            await operation.value
            return
        }
        operation.cancel()
        gate.release()
        await operation.value
        #expect(gate.observedCancellation)
        #expect(!gate.timedOut)
        #expect(store.sessions == previous)
        #expect(store.historyNotice == notice)
        #expect(store.loadError == nil)
        #expect(!store.canPruneMissingProjects)
        #expect(store.appliedScanSequence == applied)
        #expect(!store.isLoading)
        // A fresh request still applies and clears the genuinely repaired notice.
        await store.scan(ignoringCache: false)
        #expect(store.sessions.first?.title == "Fresh title")
        #expect(store.historyNotice == nil)
        #expect(store.canPruneMissingProjects)
        #expect(store.appliedScanSequence > applied)
    }

    @Test func malformedUpdateIsReportedAndPreservesLastKnownSession() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        let summary = try harness.write(
            fixture: "full.json",
            cwd: "/Users/exec/Documents/keyholding-v0-v2",
            id: "019f780a-34d7-7993-aadc-f23a46c40a73"
        )
        await harness.store.scan(ignoringCache: false)
        let originalTitle = harness.store.sessions.first?.title

        try Data("not valid json".utf8).write(to: summary, options: .atomic)
        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.sessions.first?.title == originalTitle)
        #expect(harness.store.loadError == nil)
        #expect(harness.store.historyNotice?.contains("incomplete or unsupported") == true)
    }

    @Test func compatibilityNoticesAggregateAndClearAfterVerifiedReplacement() async throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let summary = fixture.claude.appendingPathComponent("rollout.jsonl")
        try Data(#"{"type":"summary","summary":"Generated"}"#.utf8).write(to: summary)
        try fixture.writeNative(version: "1.0.0")
        let store = fixture.store()
        defer { store.stop() }
        await store.reload()
        #expect(store.sessions.isEmpty)
        #expect(store.loadError == nil)
        #expect(store.historyNotice?.contains("Claude Code history") == true)
        #expect(store.historyNotice?.contains("Codex history") == true)
        #expect(store.historyNotice?.contains("1.0.0") == true)
        #expect(!store.canPruneMissingProjects)
        try fixture.writeNative(provider: .claudeCode, version: "2.1.283")
        try fixture.writeNative()
        await store.reload()
        #expect(store.sessions.count == 2)
        #expect(store.loadError == nil)
        #expect(store.historyNotice == nil)
        #expect(store.canPruneMissingProjects)
    }

    @Test(arguments: [CLIProvider.grokBuild, .claudeCode, .codex])
    func lossOfAPreviouslyAvailableEmptyRootIsAReadProblem(provider: CLIProvider) async throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        defer { store.stop() }
        await store.reload()
        #expect(store.sessions.isEmpty)
        #expect(store.loadError == nil)
        try FileManager.default.removeItem(at: fixture.root(provider))
        await store.reload()
        #expect(store.sessions.isEmpty)
        #expect(store.loadError != nil)
        #expect(!store.canPruneMissingProjects)
        try FileManager.default.createDirectory(at: fixture.root(provider), withIntermediateDirectories: true)
        await store.reload()
        #expect(store.loadError == nil)
        #expect(store.canPruneMissingProjects)
    }

    @Test(arguments: [CLIProvider.grokBuild, .claudeCode, .codex])
    func anInaccessibleEmptyProviderRootIsAReadProblem(provider: CLIProvider) async throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        defer { store.stop() }
        let root = fixture.root(provider)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        await store.reload()
        #expect(store.sessions.isEmpty)
        #expect(store.loadError != nil)
        #expect(!store.canPruneMissingProjects)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        await store.reload()
        #expect(store.loadError == nil)
        #expect(store.canPruneMissingProjects)
    }

    @Test func neverAvailableProviderRootsAreNormalAbsence() async throws {
        let fixture = try HistoryCompatibilityFixture(createProviderRoots: false)
        defer { fixture.remove() }
        let store = fixture.store()
        defer { store.stop() }
        await store.reload()
        #expect(store.sessions.isEmpty)
        #expect(store.loadError == nil)
        #expect(store.historyNotice == nil)
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex])
    func rootLossCannotClearAnUncachedCompatibilityNotice(provider: CLIProvider) async throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        try fixture.writeNative(provider: provider, version: "1.0.0")
        let store = fixture.store()
        defer { store.stop() }
        await store.reload()
        #expect(store.sessions.isEmpty)
        let notice = try #require(store.historyNotice)
        try FileManager.default.removeItem(at: fixture.root(provider))
        await store.reload()
        #expect(store.loadError != nil)
        #expect(store.historyNotice == notice)
        try FileManager.default.createDirectory(at: fixture.root(provider), withIntermediateDirectories: true)
        await store.reload()
        #expect(store.loadError == nil)
        #expect(store.historyNotice == nil)
    }

    @Test func inaccessibleNativeRootKeepsTheEarlierNoticeAndCachedRows() async throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let held = try fixture.writeNative()
        try fixture.writeNative(id: HistoryCompatibilityFixture.secondID, filename: "blocked/second.jsonl")
        let store = fixture.store()
        defer { store.stop() }
        await store.reload()
        try fixture.writeNative(version: "1.0.0")
        await store.reload()
        let notice = try #require(store.historyNotice)
        let before = store.sessions
        let blocked = fixture.codex.appendingPathComponent("blocked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        try FileManager.default.removeItem(at: held)
        await store.reload()
        #expect(store.loadError != nil)
        #expect(store.historyNotice == notice)
        #expect(store.sessions == before)
        #expect(!store.canPruneMissingProjects)
    }

    @Test func aSummarylessGrokFolderProtectsMetadataWithoutKeepingAnUnrelatedDeletedRow() async throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let deleted = try fixture.writeGrok()
        let store = fixture.store()
        defer { store.stop() }
        await store.reload()
        #expect(store.sessions.count == 1)
        try FileManager.default.removeItem(at: deleted.deletingLastPathComponent())
        try fixture.grokDirectory(id: HistoryCompatibilityFixture.secondID)
        await store.reload()
        #expect(store.sessions.isEmpty)
        #expect(store.loadError == nil)
        #expect(store.historyNotice?.contains("Grok history") == true)
        #expect(
            store.protectsGrokMetadata(
                sessionID: HistoryCompatibilityFixture.secondID, cwd: HistoryCompatibilityFixture.cwd))
        #expect(
            !store.protectsGrokMetadata(
                sessionID: HistoryCompatibilityFixture.firstID, cwd: HistoryCompatibilityFixture.cwd))
        #expect(!store.canPruneMissingProjects)
        try fixture.writeGrok(id: HistoryCompatibilityFixture.secondID)
        await store.reload()
        #expect(store.historyNotice == nil)
        #expect(store.canPruneMissingProjects)
        #expect(
            !store.protectsGrokMetadata(
                sessionID: HistoryCompatibilityFixture.secondID, cwd: HistoryCompatibilityFixture.cwd))
    }

    @Test func supersededCachedScanCannotPublishOldNoticeOrCoverage() async throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let gate = CompatibilityScanGate()
        let root = fixture.grok
        let store = SessionStore(
            root: root, timing: SessionStoreTiming(),
            scanOperation: { _, _, forced in
                if !forced.ignoresGrokCache {
                    await gate.hold()
                    return .init(
                        sessions: [], cache: [:], loadError: "Superseded fixture error",
                        coverage: .init(notices: [root.path: "Superseded compatibility notice"]))
                }
                return .init(sessions: [], cache: [:], loadError: nil)
            })
        defer { store.stop() }
        let old = Task { await store.scan(ignoringCache: false) }
        for _ in 0..<1_000 {
            if await gate.isWaiting { break }
            await Task.yield()
        }
        let waiting = await gate.isWaiting
        #expect(waiting)
        guard waiting else {
            await gate.release()
            await old.value
            return
        }
        await store.reload()
        await gate.release()
        await old.value
        #expect(store.loadError == nil)
        #expect(store.historyNotice == nil)
        #expect(store.canPruneMissingProjects)
    }

    @Test func totalReadFailureIsReportedAndPreservesLastKnownSessions() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )
        await harness.store.scan(ignoringCache: false)
        try FileManager.default.removeItem(at: harness.root)

        await harness.store.reload()

        #expect(harness.store.sessions.map(\.id) == ["019ffeab-c76b-7fe1-be40-508369febd51"])
        #expect(harness.store.loadError?.contains("does not exist") == true)
    }

    @Test func aSecondUnchangedScanDoesNotPublishSessionsOrLoading() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )
        await harness.store.scan(ignoringCache: false)

        let sessionPublishes = ObservationCounter()
        let loadingPublishes = ObservationCounter()
        withObservationTracking {
            _ = harness.store.sessions
        } onChange: {
            sessionPublishes.increment()
        }
        withObservationTracking {
            _ = harness.store.isLoading
        } onChange: {
            loadingPublishes.increment()
        }

        await harness.store.scan(ignoringCache: false)

        #expect(sessionPublishes.value == 0)
        #expect(loadingPublishes.value == 0)
        #expect(harness.store.sessions.map(\.id) == ["019ffeab-c76b-7fe1-be40-508369febd51"])
        #expect(!harness.store.isLoading)
    }

    @Test func unreadableProjectIsReportedAndPreservesItsCachedSessions() async throws {
        let harness = try FixtureHarness()
        defer { harness.tearDown() }
        try harness.write(
            fixture: "minimal.json",
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        )
        await harness.store.scan(ignoringCache: false)
        let project = harness.sessionDirectory(
            cwd: "/Users/exec",
            id: "019ffeab-c76b-7fe1-be40-508369febd51"
        ).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: project.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: project.path
            )
        }

        await harness.store.scan(ignoringCache: false)

        #expect(harness.store.sessions.map(\.id) == ["019ffeab-c76b-7fe1-be40-508369febd51"])
        #expect(harness.store.loadError != nil)
    }
}

/// Pauses one real read in the production detached scan; no replacement ScanOperation.
extension SessionStoreTests {
    @Test func savedDisplayPublishesBeforeFirstScanAndDeletedRowsDisappearWithoutBodyReads() async throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let titles = CodexTitleIndexCache()
        #expect(fixture.file.save(fixture.snapshot(fixture.scan(titles: titles).cache, titles: titles)))
        try FileManager.default.removeItem(at: fixture.claudeFile)
        let gate = CompatibilityScanGate()
        let meter = HistoryIndexMeter()
        let restoredTitles = CodexTitleIndexCache()
        let store = SessionStore(
            root: fixture.grok,
            timing: SessionStoreTiming(indexWriteDelay: .milliseconds(5), historyValidationDelay: .milliseconds(200)),
            nativeRoots: fixture.nativeRoots, indexFile: fixture.file, titleIndexCache: restoredTitles,
            scanOperation: { _, cache, _ in
                await gate.hold()
                return fixture.scan(cache: cache, titles: restoredTitles, meter: meter)
            })
        defer { store.stop() }
        store.start()
        try await waitUntilAsync { await gate.isWaiting }
        #expect(store.appliedScanSequence == 0)
        #expect(store.sessions.count == 3)
        #expect(store.search("Generated index title").count == 1)
        #expect(store.isLoading && store.hasUnvalidatedHistory && !store.canPruneMissingProjects)
        await gate.release()
        try await waitUntil { !store.isLoading }
        #expect(store.appliedScanSequence > 0)
        #expect(store.sessions.count == 2)
        #expect(meter.count == 0)
        #expect(store.hasUnvalidatedHistory && !store.canPruneMissingProjects)
        let displayed = store.sessions
        // Ordinary launch eventually validates every saved source without a click or manual reload.
        try await waitUntil { !store.hasUnvalidatedHistory && !store.hasPendingHistoryValidation }
        #expect(store.canPruneMissingProjects && store.appliedScanSequence == 2)
        #expect(meter.count == 2)  // One Grok summary and one Codex sample; unchanged title index stays stat-only.
        #expect(await store.validatedSessions(for: displayed).count == 2)
        #expect(store.scanSequence == 2)  // Restoring multiple saved tabs shares the completed pass.
        try await waitUntil { fixture.file.load(roots: fixture.roots)?.entries.count == 2 }
    }

    @Test(arguments: [false, true])
    func invalidSavedIndexIsIgnoredThenRewritten(wrongVersion: Bool) async throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        var saved = fixture.snapshot(fixture.scan().cache)
        if wrongVersion { saved.version = 999 }
        try FileManager.default.createDirectory(
            at: fixture.file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = wrongVersion ? try JSONEncoder().encode(saved) : Data("{".utf8)
        try bytes.write(to: fixture.file.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.url.path)
        let gate = CompatibilityScanGate()
        let meter = HistoryIndexMeter()
        let store = SessionStore(
            root: fixture.grok, timing: SessionStoreTiming(indexWriteDelay: .milliseconds(5)),
            nativeRoots: fixture.nativeRoots, indexFile: fixture.file,
            scanOperation: { _, cache, _ in
                await gate.hold()
                return fixture.scan(cache: cache, meter: meter)
            })
        defer { store.stop() }
        store.start()
        try await waitUntilAsync { await gate.isWaiting }
        #expect(store.sessions.isEmpty && store.appliedScanSequence == 0)
        await gate.release()
        try await waitUntil { !store.isLoading }
        #expect(store.sessions.count == 3 && !store.hasUnvalidatedHistory)
        #expect(meter.count > 0)
        try await waitUntil { fixture.file.load(roots: fixture.roots)?.entries.count == 3 }
    }

    @Test func forcedScanSupersedesSavedStartupAndOnlyAppliedStateIsPersisted() async throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let saved = fixture.snapshot(fixture.scan().cache)
        #expect(fixture.file.save(saved))
        let gate = CompatibilityScanGate()
        let store = SessionStore(
            root: fixture.grok, timing: SessionStoreTiming(indexWriteDelay: .milliseconds(5)),
            nativeRoots: fixture.nativeRoots, indexFile: fixture.file,
            scanOperation: { _, cache, forced in
                if forced.ignoresGrokCache { return .init(sessions: [], cache: [:], loadError: nil) }
                await gate.hold()
                return .init(sessions: cache.values.map(\.session), cache: cache, loadError: nil)
            })
        defer { store.stop() }
        store.start()
        try await waitUntilAsync { await gate.isWaiting }
        #expect(store.appliedScanSequence == 0 && store.sessions.count == 3)
        await store.reload()
        let applied = store.appliedScanSequence
        await gate.release()
        try await waitUntil { !store.isLoading }
        #expect(store.sessions.isEmpty && store.appliedScanSequence == applied)
        try await waitUntil { fixture.file.load(roots: fixture.roots)?.entries.isEmpty == true }
    }

    @Test func forgedSavedIdentityCannotAuthorizeSourceActions() async throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        var cache = fixture.scan().cache
        let key = fixture.claudeFile.path
        var entry = try #require(cache[key])
        let original = entry.session
        entry.session = GrokSession(
            id: "22222222-2222-4222-8222-222222222222", cwd: original.cwd, summary: "Forged display identity",
            createdAt: original.createdAt, updatedAt: original.updatedAt, messageCount: 1,
            modelID: nil, agentName: nil, reasoningEffort: nil, directory: original.directory,
            provider: .claudeCode)
        cache[key] = entry
        #expect(fixture.file.save(fixture.snapshot(cache)))
        let store = SessionStore(
            root: fixture.grok, timing: SessionStoreTiming(), nativeRoots: fixture.nativeRoots,
            indexFile: fixture.file)
        defer { store.stop() }
        store.start()
        try await waitUntil { store.appliedScanSequence > 0 && !store.isLoading }
        let forged = try #require(store.sessions.first { $0.summary == "Forged display identity" })
        #expect(!forged.isHistoryValidated)
        #expect(await store.validatedSession(for: forged) == nil)
        #expect(
            store.sessions.contains {
                $0.provider == .claudeCode && $0.nativeSessionID == fixture.id && $0.isHistoryValidated
            })
    }

    @Test func savedActionWaitsForForcedScanRatherThanFailingOrTraversingAgain() async throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        #expect(fixture.file.save(fixture.snapshot(fixture.scan().cache)))
        let gate = CompatibilityScanGate()
        let store = SessionStore(
            root: fixture.grok, timing: SessionStoreTiming(historyValidationDelay: .seconds(30)),
            nativeRoots: fixture.nativeRoots, indexFile: fixture.file,
            scanOperation: { _, cache, forced in
                if forced.ignoresGrokCache { await gate.hold() }
                return SessionHistoryScanner(nativeRoots: fixture.nativeRoots).scan(
                    root: fixture.grok, cache: cache, policy: forced)
            })
        defer { store.stop() }
        store.start()
        try await waitUntil { store.appliedScanSequence == 1 && !store.isLoading }
        let displayed = store.sessions
        let forced = Task { await store.reload() }
        try await waitUntilAsync { await gate.isWaiting }
        let action = Task { await store.validatedSessions(for: displayed) }
        await Task.yield()
        #expect(store.appliedScanSequence == 1)
        await gate.release()
        await forced.value
        let ready = await action.value
        #expect(ready.count == 3 && ready.allSatisfy(\.isHistoryValidated))
        #expect(store.scanSequence == 2 && store.appliedScanSequence == 2)
        #expect(!store.hasUnvalidatedHistory && store.canPruneMissingProjects)
    }

    @Test func reloadValidatesSavedNativeRowsRatherThanTrustingMetadataHits() async throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let titles = CodexTitleIndexCache()
        #expect(fixture.file.save(fixture.snapshot(fixture.scan(titles: titles).cache, titles: titles)))
        let native = HistoryIndexMeter()
        let store = SessionStore(
            root: fixture.grok, timing: .init(historyValidationDelay: .seconds(30)),
            nativeRoots: fixture.nativeRoots, nativeContentReader: native.native, indexFile: fixture.file)
        defer { store.stop() }
        store.start()
        try await waitUntil { store.appliedScanSequence == 1 && !store.isLoading }
        #expect(store.sessions.count == 3 && store.hasUnvalidatedHistory)
        #expect(native.count == 0 && !store.canPruneMissingProjects)
        await store.reload()
        #expect(native.count > 0 && store.sessions.allSatisfy(\.isHistoryValidated))
        #expect(!store.hasUnvalidatedHistory && store.canPruneMissingProjects)
        let reads = native.count
        await store.reload()
        #expect(native.count == reads)
    }

    @Test func twoDeletesAndWatcherCoalesceBehindExplicitRecovery() async throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let secondID = "22222222-2222-4222-8222-222222222222"
        let secondDirectory = fixture.grokDirectory.deletingLastPathComponent().appendingPathComponent(secondID)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "info": ["id": secondID, "cwd": fixture.project.path], "session_summary": "Generated second Grok",
        ]).write(to: secondDirectory.appendingPathComponent("summary.json"))
        let gate = DetachedHistoryReadGate()
        defer { gate.release() }
        let store = SessionStore(
            root: fixture.grok, timing: .init(), nativeRoots: fixture.nativeRoots, nativeContentReader: gate.reader)
        defer { store.stop() }
        await store.reload()
        #expect(store.sessions.count == 4)
        gate.arm()
        let recovery = Task { await store.rebuildHistory() }
        try await waitUntil { gate.isWaiting }
        try FileManager.default.removeItem(at: fixture.grokDirectory)
        await store.refresh()
        try FileManager.default.removeItem(at: secondDirectory)
        await store.refresh()
        // The watcher uses this same cached scan entry point. Every pending request shares one follow-up.
        await store.scan(ignoringCache: false)
        #expect(store.scanSequence == 2)
        gate.release()
        await recovery.value
        try await waitUntil { store.appliedScanSequence == 3 && !store.isLoading }
        #expect(store.scanSequence == 3)
        #expect(store.sessions.count == 2 && store.sessions.allSatisfy { $0.provider != .grokBuild })
        #expect(!gate.timedOut && store.loadError == nil)
    }

    @Test func stoppingActiveSavedValidationCancelsItsReadAndQueuedWatcherScan() async throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let titles = CodexTitleIndexCache()
        #expect(fixture.file.save(fixture.snapshot(fixture.scan(titles: titles).cache, titles: titles)))
        let gate = DetachedHistoryReadGate()
        gate.arm()
        defer { gate.release() }
        let store = SessionStore(
            root: fixture.grok, timing: SessionStoreTiming(historyValidationDelay: .milliseconds(100)),
            nativeRoots: fixture.nativeRoots, nativeContentReader: gate.reader, indexFile: fixture.file)
        defer { store.stop() }
        store.start()
        try await waitUntil { store.appliedScanSequence == 1 && !store.isLoading }
        let displayed = store.sessions
        try await waitUntil { gate.isWaiting }
        #expect(store.scanSequence == 2)
        await store.scan(ignoringCache: false)
        #expect(store.scanSequence == 2)  // A watcher cannot supersede the active validation with saved rows.
        var entered = false
        let action = Task {
            entered = true
            return await store.validatedSessions(for: displayed)
        }
        try await waitUntil { entered }
        store.stop()
        gate.release()
        #expect(await action.value.isEmpty)
        #expect(gate.observedCancellation && !gate.timedOut)
        #expect(store.appliedScanSequence == 1 && store.sessions.allSatisfy { !$0.isHistoryValidated })
        #expect(!store.hasPendingHistoryValidation)
        #expect(await store.validatedSessions(for: displayed).isEmpty && store.scanSequence == 2)
    }
}

private final class DetachedHistoryReadGate: Sendable {
    private struct State: Sendable {
        var armed = false
        var waiting = false
        var observedCancellation = false
        var timedOut = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let resume = DispatchSemaphore(value: 0)

    var isWaiting: Bool { state.withLock { $0.waiting } }
    var observedCancellation: Bool { state.withLock { $0.observedCancellation } }
    var timedOut: Bool { state.withLock { $0.timedOut } }

    func arm() { state.withLock { $0.armed = true } }
    func release() { resume.signal() }

    var reader: NativeSessionScanner.ContentReader {
        NativeSessionScanner.ContentReader { handle, offset, count in
            let data = try NativeSessionScanner.ContentReader.disk.read(handle, offset, count)
            let pause = self.state.withLock { state in
                guard state.armed else { return false }
                state.armed = false
                state.waiting = true
                return true
            }
            if pause {
                let timedOut = self.resume.wait(timeout: .now() + 5) == .timedOut
                self.state.withLock {
                    $0.observedCancellation = Task.isCancelled
                    $0.timedOut = timedOut
                }
            }
            return data
        }
    }
}

private actor CompatibilityScanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isWaiting = false

    func hold() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            isWaiting = true
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

struct SessionQueryCase: Sendable, CustomTestStringConvertible {
    var query: String
    var expectedIDs: [String]

    var testDescription: String {
        query.isEmpty ? "empty" : query
    }

    static let all: [SessionQueryCase] = [
        SessionQueryCase(
            query: "",
            expectedIDs: ["a1", "b1", "g1", "a2", "b2"]
        ),
        SessionQueryCase(
            query: "   \t",
            expectedIDs: ["a1", "b1", "g1", "a2", "b2"]
        ),
        SessionQueryCase(
            query: "alpha",
            expectedIDs: ["a2", "a1"]
        ),
        SessionQueryCase(
            query: "cafe",
            expectedIDs: ["b1"]
        ),
        SessionQueryCase(
            query: "BETA",
            expectedIDs: ["b2", "b1"]
        ),
        SessionQueryCase(
            query: "Zebra",
            expectedIDs: ["a1"]
        ),
        SessionQueryCase(
            query: "zzz",
            expectedIDs: []
        ),
    ]
}

@MainActor
private struct FixtureHarness {
    let root: URL
    let store: SessionStore

    init(
        createRoot: Bool = true,
        timing: SessionStoreTiming? = nil,
        scanOperation: SessionStore.ScanOperation? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sigil-SessionStore-\(UUID().uuidString)", isDirectory: true)
        if createRoot {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        if let scanOperation {
            store = SessionStore(
                root: root,
                timing: timing ?? SessionStoreTiming(),
                scanOperation: scanOperation
            )
        } else if let timing {
            store = SessionStore(root: root, timing: timing)
        } else {
            store = SessionStore(root: root)
        }
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

@MainActor
private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    _ predicate: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for condition")
}

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private actor ScanRecorder {
    private(set) var count = 0
    private(set) var forcedCount = 0
    private(set) var cachedCount = 0

    func record(forced: Bool? = nil) {
        count += 1
        if forced == true {
            forcedCount += 1
        } else if forced == false {
            cachedCount += 1
        }
    }
}
