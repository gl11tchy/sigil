import CoreServices
import Foundation
import Testing

@testable import SigilKit

struct SessionDirectoryWatcherTests {
    @Test func summaryWritesAndDirectoryEventsRefresh() {
        #expect(
            SessionDirectoryWatcher.shouldScan(
                path: "/sessions/proj/id/summary.json",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
            )
        )
        #expect(
            SessionDirectoryWatcher.shouldScan(
                path: "/sessions/proj/id",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
            )
        )
    }

    @Test func journalAndLockWritesDoNotRefresh() {
        let noise = [
            "updates.jsonl",
            "updates.jsonl.lock",
            "chat_history.jsonl",
            "events.jsonl",
            "prompt_context.json",
            "summary.json.lock",
            "title_refresh_idx",
        ]
        for name in noise {
            #expect(
                !SessionDirectoryWatcher.shouldScan(
                    path: "/sessions/proj/id/\(name)",
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
                ),
                "\(name) must not rescan the sidebar"
            )
        }
    }

    @Test func aCoalescedMustScanSubDirsEventRefreshesWithoutARestart() {
        let decision = SessionDirectoryWatcher.decision(
            paths: ["/sessions/proj"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)]
        )
        #expect(decision.scan)
        #expect(!decision.restart)
    }

    @Test func aBatchWithOnlyJournalWritesDoesNotRefresh() {
        let decision = SessionDirectoryWatcher.decision(
            paths: [
                "/sessions/proj/id/updates.jsonl",
                "/sessions/proj/id/chat_history.jsonl",
            ],
            flags: [
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
            ]
        )
        #expect(!decision.scan)
        #expect(!decision.restart)
    }

    @Test func aBatchWithASummaryWriteStillRefreshes() {
        let decision = SessionDirectoryWatcher.decision(
            paths: [
                "/sessions/proj/id/updates.jsonl",
                "/sessions/proj/id/summary.json",
            ],
            flags: [
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
            ]
        )
        #expect(decision.scan)
        #expect(!decision.restart)
    }
}
