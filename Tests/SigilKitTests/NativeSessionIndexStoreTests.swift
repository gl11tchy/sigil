import Foundation
import Testing
import os

@testable import SigilKit

@MainActor
struct NativeSessionIndexStoreTests {
    /// Uses the real initializer and detached scan, not a replacement ScanOperation.
    /// Observation-backed execution belongs to ordinary CI.
    @Test func productionStoreReloadReusesIndexAndExplicitRecoveryRebuildsIt() async throws {
        let fixture = try HistoryCompatibilityFixture()
        defer { fixture.remove() }
        let id = HistoryCompatibilityFixture.firstID
        try fixture.writeNative()
        let index = fixture.codex.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
        try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Generated index title"])
            .write(to: index)
        let indexDecodes = OSAllocatedUnfairLock(initialState: 0)
        let decoder = NativeSessionRecordDecoder(didDecode: { source in
            if case .codexTitleIndex = source { indexDecodes.withLock { $0 += 1 } }
        })
        let store = SessionStore(
            root: fixture.grok, timing: .init(), nativeRoots: [(.codex, fixture.codex)],
            nativeRecordDecoder: decoder)
        defer { store.stop() }
        await store.scan(ignoringCache: false)
        #expect(store.sessions.first?.summary == "Generated index title")
        #expect(indexDecodes.withLock { $0 } == 1)
        let original = store.sessions
        await store.scan(ignoringCache: false)
        #expect(store.sessions == original)
        #expect(indexDecodes.withLock { $0 } == 1)
        await store.reload()
        #expect(store.sessions == original)
        #expect(indexDecodes.withLock { $0 } == 1)
        await store.rebuildHistory()
        #expect(store.sessions == original)
        #expect(indexDecodes.withLock { $0 } == 2)
        try FileManager.default.removeItem(at: index)
        await store.scan(ignoringCache: false)
        #expect(store.sessions.first?.summary == "")
    }
}
