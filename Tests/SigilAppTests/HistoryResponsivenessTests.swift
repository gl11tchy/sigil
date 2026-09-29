import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct HistoryResponsivenessTests {
    @Test func nineHundredConversationsRemainResponsiveWithFourLiveTerminals() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("performance-project")
        for index in 0..<900 {
            try fixture.writeSession(
                id: "history-\(index)", cwd: folder.path,
                summary: "Conversation \(index) parser task", updatedAt: "2026-09-27T10:00:00Z", secret: "synthetic")
        }
        for _ in 0..<4 { _ = try #require(fixture.model.newTab(in: folder)) }
        let reloadStart = ContinuousClock.now
        var longestUIWait = Duration.zero
        var lastTick = ContinuousClock.now
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                longestUIWait = max(longestUIWait, lastTick.duration(to: now))
                lastTick = now
            }
        }
        await fixture.store.reload()
        let reload = reloadStart.duration(to: .now)
        #expect(fixture.store.sessions.count == 900)
        let searchStart = ContinuousClock.now
        var longestSearch = Duration.zero
        for index in 0..<100 {
            let actionStart = ContinuousClock.now
            fixture.model.searchText = "Conversation \(index)"
            let results = fixture.model.sidebarSessions
            longestSearch = max(longestSearch, actionStart.duration(to: .now))
            #expect(!results.isEmpty)
            // Separate user actions must let terminal output and UI work run.
            await Task.yield()
        }
        let search = searchStart.duration(to: .now)
        fixture.model.searchText = ""
        await Task.yield()
        let snapshotsStart = ContinuousClock.now
        var longestSnapshot = Duration.zero
        for _ in 0..<20 {
            let actionStart = ContinuousClock.now
            _ = fixture.model.sidebarSnapshot()
            longestSnapshot = max(longestSnapshot, actionStart.duration(to: .now))
            await Task.yield()
        }
        let snapshots = snapshotsStart.duration(to: .now)
        try await Task.sleep(for: .milliseconds(10))
        ticker.cancel()
        await ticker.value
        #expect(fixture.model.tabs.filter { $0.controller.isRunning }.count == 4)
        // Per-action budgets tolerate slower CI hardware without accepting a
        // multi-second UI stall. Batch totals are evidence, not interaction time.
        #expect(longestSearch < .milliseconds(500))
        #expect(longestSnapshot < .milliseconds(500))
        #expect(longestUIWait < .seconds(1))
        let memory = Process()
        let output = Pipe()
        memory.executableURL = URL(fileURLWithPath: "/bin/ps")
        memory.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
        memory.standardOutput = output
        try memory.run()
        memory.waitUntilExit()
        let rss = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print(
            "History benchmark: records=900 livePTYs=4 scan=\(reload) searches100=\(search) snapshots20=\(snapshots) maxSingleSearch=\(longestSearch) maxSingleSnapshot=\(longestSnapshot) longestMainActorWait=\(longestUIWait) testProcessRSSKiB=\(rss)"
        )
    }
}
