import Foundation
import Testing

@testable import SigilKit

struct SessionHistoryScannerTests {
    @Test func reloadRereadsGrokButReusesNativeBodiesAndTitleIndex() throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let grok = HistoryIndexMeter()
        let native = HistoryIndexMeter()
        let scanner = SessionHistoryScanner(
            nativeRoots: fixture.nativeRoots, contentReader: grok.grok, nativeContentReader: native.native)
        let warm = scanner.scan(root: fixture.grok, cache: [:], policy: .cached)
        #expect(warm.sessions.count == 3)
        let originalNativeReads = native.count
        let originalGrokReads = grok.count
        let reloaded = scanner.scan(root: fixture.grok, cache: warm.cache, policy: .reload)
        #expect(reloaded.sessions == warm.sessions)
        #expect(native.count == originalNativeReads)
        #expect(grok.count == originalGrokReads + 1)
        let rebuilt = scanner.scan(root: fixture.grok, cache: reloaded.cache, policy: .rebuild)
        #expect(rebuilt.sessions == warm.sessions)
        #expect(native.count > originalNativeReads)
        #expect(grok.count == originalGrokReads + 2)
    }

    @Test func cachedRefreshDropsRemovedGrokWithoutReadingNativeBodies() throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let native = HistoryIndexMeter()
        let scanner = SessionHistoryScanner(nativeRoots: fixture.nativeRoots, nativeContentReader: native.native)
        let warm = scanner.scan(root: fixture.grok, cache: [:], policy: .cached)
        let reads = native.count
        try FileManager.default.removeItem(at: fixture.grokDirectory)
        let refreshed = scanner.scan(root: fixture.grok, cache: warm.cache, policy: .cached)
        #expect(refreshed.sessions.count == 2 && refreshed.sessions.allSatisfy { $0.provider != .grokBuild })
        #expect(native.count == reads && refreshed.loadError == nil)
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex], [false, true])
    func reloadReadsReplacementAndInPlaceRewriteWithRestoredMtime(provider: CLIProvider, atomic: Bool) throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        // Observe the native prompt, without a separate Codex name override.
        try FileManager.default.removeItem(at: fixture.titleFile)
        let native = HistoryIndexMeter()
        let scanner = SessionHistoryScanner(nativeRoots: fixture.nativeRoots, nativeContentReader: native.native)
        let warm = scanner.scan(root: fixture.grok, cache: [:], policy: .cached)
        let file =
            provider == .claudeCode ? fixture.claudeFile : fixture.codex.appendingPathComponent("generated.jsonl")
        let entry = try #require(warm.cache[file.path])
        let original = try Data(contentsOf: file)
        let rewritten = Data(
            String(decoding: original, as: UTF8.self).replacingOccurrences(of: "Generated", with: "Rewritten").utf8)
        #expect(original.count == rewritten.count)
        try rewritten.write(to: file, options: atomic ? .atomic : [])
        try FileManager.default.setAttributes([.modificationDate: entry.modificationDate], ofItemAtPath: file.path)
        let reads = native.count
        let reloaded = scanner.scan(root: fixture.grok, cache: warm.cache, policy: .reload)
        #expect(native.count > reads)
        #expect(
            reloaded.sessions.first { $0.provider == provider }?.summary
                == "Rewritten \(provider == .codex ? "Codex" : "Claude") title")
        #expect(reloaded.loadError == nil)
    }

    @Test func explicitRecoveryRetainsFailedRowsAndRetriesUnchangedSources() throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let scanner = SessionHistoryScanner(nativeRoots: fixture.nativeRoots)
        let warm = scanner.scan(root: fixture.grok, cache: [:], policy: .cached)
        var failing = scanner
        failing.nativeContentReader = .init { _, _, _ in throw CocoaError(.fileReadUnknown) }
        let failed = failing.scan(root: fixture.grok, cache: warm.cache, policy: .rebuild)
        #expect(failed.loadError != nil && !failed.coverage.uncertainRoots.isEmpty)
        #expect(failed.sessions.contains { $0.provider == .claudeCode && $0.summary == "Generated Claude title" })
        #expect(failed.cache[fixture.claudeFile.path] == warm.cache[fixture.claudeFile.path])
        let native = HistoryIndexMeter()
        var retry = scanner
        retry.nativeContentReader = native.native
        let recovered = retry.scan(root: fixture.grok, cache: failed.cache, policy: .rebuild)
        #expect(native.count > 0 && recovered.sessions == warm.sessions && recovered.loadError == nil)
        #expect(recovered.coverage.uncertainRoots.isEmpty)
    }

    @Test func explicitRecoveryRebuildsAStaleRowEvenWhenMetadataMatches() throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let native = HistoryIndexMeter()
        let scanner = SessionHistoryScanner(nativeRoots: fixture.nativeRoots, nativeContentReader: native.native)
        let warm = scanner.scan(root: fixture.grok, cache: [:], policy: .cached)
        var stale = warm.cache
        let old = try #require(stale[fixture.claudeFile.path]?.session)
        stale[fixture.claudeFile.path]?.session = GrokSession(
            id: old.nativeSessionID, cwd: old.cwd, summary: "Generated stale cache", createdAt: old.createdAt,
            updatedAt: old.updatedAt, messageCount: old.messageCount, modelID: old.modelID,
            agentName: old.agentName, reasoningEffort: old.reasoningEffort, directory: old.directory,
            provider: old.provider, hasObservedMessages: old.hasObservedMessages)
        let reads = native.count
        let reloaded = scanner.scan(root: fixture.grok, cache: stale, policy: .reload)
        #expect(native.count == reads)
        #expect(reloaded.sessions.contains { $0.summary == "Generated stale cache" })
        let recovered = scanner.scan(root: fixture.grok, cache: reloaded.cache, policy: .rebuild)
        #expect(native.count > reads && recovered.sessions == warm.sessions)
    }
}
