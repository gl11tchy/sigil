import Foundation
import Testing

@testable import SigilKit

@MainActor
struct NativeSessionWatcherTests {
    @Test(arguments: [CLIProvider.claudeCode, .codex])
    func existingNativeFoldersDiscoverAppendsAndNewTranscripts(provider: CLIProvider) async throws {
        let fixture = try NativeWatcherFixture(provider: provider)
        defer {
            fixture.cleanup()
            traceNativeWatcherStage("test defer: cleanup returned")
        }
        let firstID = UUID().uuidString.lowercased()
        let file = try fixture.writeSession(id: firstID)
        fixture.store.start()
        try await fixture.waitUntil("initial session") { fixture.store.sessions.count == 1 }
        try await fixture.settleInitialEvents()
        #expect(fixture.store.sessions.first?.summary == "")
        #expect(fixture.store.sessions.first?.hasObservedMessages == false)

        try fixture.appendMessage(to: file, text: "First native message")
        try await fixture.waitUntil("appended message") {
            fixture.store.sessions.first?.summary == "First native message"
        }
        #expect(fixture.store.sessions.first?.hasObservedMessages == true)
        #expect(fixture.store.search("First native message").map(\.nativeSessionID) == [firstID])

        let secondID = UUID().uuidString.lowercased()
        let second = try fixture.writeSession(id: secondID)
        try fixture.appendMessage(to: second, text: "Second native conversation")
        try await fixture.waitUntil("new transcript") {
            Set(fixture.store.sessions.map(\.nativeSessionID)) == [firstID, secondID]
        }
        #expect(fixture.store.search("Second native conversation").map(\.nativeSessionID) == [secondID])

        try FileManager.default.removeItem(at: second)
        try await fixture.waitUntil("deleted transcript") { fixture.store.sessions.map(\.nativeSessionID) == [firstID] }
    }

    @Test func codexAdjacentIndexUpdatesAnUnchangedTranscriptWithoutReload() async throws {
        traceNativeWatcherStage("adjacent index: before fixture creation")
        let fixture = try NativeWatcherFixture(provider: .codex)
        traceNativeWatcherStage("adjacent index: after fixture creation")
        defer {
            fixture.cleanup()
            traceNativeWatcherStage("test defer: cleanup returned")
        }
        let id = UUID().uuidString.lowercased()
        traceNativeWatcherStage("adjacent index: before transcript setup")
        let transcript = try fixture.writeSession(id: id)
        try fixture.appendMessage(to: transcript, text: "Original transcript title")
        let originalData = try Data(contentsOf: transcript)
        traceNativeWatcherStage("adjacent index: after transcript setup; before store.start")
        fixture.store.start()
        traceNativeWatcherStage("adjacent index: after store.start; before initial title wait")
        try await fixture.waitUntil("initial title") {
            fixture.store.sessions.first?.summary == "Original transcript title"
        }
        traceNativeWatcherStage("adjacent index: after initial title wait; before settling initial events")
        try await fixture.settleInitialEvents()
        traceNativeWatcherStage("adjacent index: after settling initial events")

        let index = fixture.nativeRoot.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
        traceNativeWatcherStage("adjacent index: before creating index")
        try fixture.append(["id": id, "thread_name": "Native renamed conversation"], to: index)
        traceNativeWatcherStage("adjacent index: after creating index; before created index wait")
        try await fixture.waitUntil("created index") {
            fixture.store.sessions.first?.summary == "Native renamed conversation"
        }
        traceNativeWatcherStage("adjacent index: after created index wait; before search assertion")
        #expect(fixture.store.search("Native renamed conversation").map(\.nativeSessionID) == [id])
        traceNativeWatcherStage("adjacent index: after search assertion; before appending index")
        try fixture.append(["id": id, "thread_name": "Renamed again"], to: index)
        traceNativeWatcherStage("adjacent index: after appending index; before appended index wait")
        try await fixture.waitUntil("appended index") { fixture.store.sessions.first?.summary == "Renamed again" }
        traceNativeWatcherStage("adjacent index: after appended index wait; before transcript assertion")
        #expect(try Data(contentsOf: transcript) == originalData)
        traceNativeWatcherStage("adjacent index: after transcript assertion")
    }
}

@MainActor
private struct NativeWatcherFixture {
    let root: URL
    let nativeRoot: URL
    let folder: URL
    let provider: CLIProvider
    let store: SessionStore

    init(provider: CLIProvider) throws {
        self.provider = provider
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Sigil-native-watch-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        nativeRoot = root.appendingPathComponent(provider == .codex ? "codex/sessions" : "claude/projects")
        folder = nativeRoot.appendingPathComponent(provider == .codex ? "2026/09/27" : "project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = SessionStore(
            root: root.appendingPathComponent("grok/sessions"),
            timing: .init(
                debounceDelay: .milliseconds(50), maximumDebounceDelay: .milliseconds(150),
                watcherRetryDelay: .seconds(30), watcherLatency: 0.05),
            nativeRoots: [(provider, nativeRoot)])
    }

    func cleanup() {
        traceNativeWatcherStage("\(provider.rawValue) cleanup: before store.stop")
        store.stop()
        traceNativeWatcherStage("\(provider.rawValue) cleanup: after store.stop; before removing fixture")
        try? FileManager.default.removeItem(at: root)
        traceNativeWatcherStage("\(provider.rawValue) cleanup: after fixture removal attempt")
    }

    func writeSession(id: String) throws -> URL {
        let file = folder.appendingPathComponent("\(id).jsonl")
        let record: [String: Any] =
            provider == .codex
            ? ["type": "session_meta", "payload": ["id": id, "cwd": root.path, "cli_version": "0.157.1"]]
            : ["type": "system", "sessionId": id, "cwd": root.path, "version": "2.1.283"]
        try append(record, to: file)
        return file
    }

    func appendMessage(to file: URL, text: String) throws {
        let record: [String: Any] =
            provider == .codex
            ? ["type": "event_msg", "payload": ["type": "user_message", "message": text]]
            : ["type": "user", "message": ["content": text]]
        try append(record, to: file)
    }

    func append(_ record: [String: Any], to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record))
        try handle.write(contentsOf: Data([0x0A]))
    }

    func settleInitialEvents() async throws {
        // Drain startup directory events before the tested file-only mutation.
        try await Task.sleep(for: .seconds(1))
        let sequence = store.appliedScanSequence
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.appliedScanSequence == sequence)
    }

    func waitUntil(_ stage: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), "Native history did not update through its filesystem watcher: \(stage)")
    }
}

// Temporary CI stage tracing for the adjacent-index stall; write directly to stderr.
private func traceNativeWatcherStage(_ stage: String) {
    let line = "[NativeSessionWatcherTests \(Date().timeIntervalSince1970)] \(stage)\n"
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
}
