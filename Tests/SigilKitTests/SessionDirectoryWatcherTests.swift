import CoreServices
import Foundation
import Testing

@testable import SigilKit

struct SessionDirectoryWatcherTests {
    @Test func sidebarPolicyWatchesIdentityAndGitMarkersWithoutSourceFileChurn() {
        let contents = SessionDirectoryWatcher.Contents.sidebarPaths([
            "/generated/project", "/generated/project/.git", "/generated/link",
        ])
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let directory = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        #expect(SessionDirectoryWatcher.shouldScan(path: "/generated/link", flags: file, contents: contents))
        #expect(SessionDirectoryWatcher.shouldScan(path: "/generated/project/.git", flags: file, contents: contents))
        #expect(SessionDirectoryWatcher.shouldScan(path: "/generated", flags: directory, contents: contents))
        for path in ["/generated/project/code.swift", "/generated/project/.git/index", "/generated/unrelated"] {
            #expect(!SessionDirectoryWatcher.shouldScan(path: path, flags: file, contents: contents))
        }
    }

    @Test func sidebarWatchPlanIncludesMissingRootsAndAliasParents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let plan = SidebarPathWatcher.plan(paths: [alias.appendingPathComponent("missing/child").path])
        #expect(plan.roots.contains(root.path))
        #expect(plan.roots.contains(actual.path))
        #expect(plan.identities.contains(alias.path))
        #expect(plan.identities.contains(actual.appendingPathComponent("missing/child").path))
        #expect(!plan.roots.contains("/"))
        #expect(!plan.needsFallback)
        let partial = SidebarPathWatcher.plan(paths: [actual.path, "/Sigil1255-Generated-\(UUID().uuidString)"])
        #expect(!partial.roots.isEmpty && partial.needsFallback)
        let admin = root.appendingPathComponent("repo/.git/worktrees/generated")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try Data("gitdir: \(admin.path)\n".utf8).write(to: actual.appendingPathComponent(".git"))
        let worktreePlan = SidebarPathWatcher.plan(paths: [actual.path])
        #expect(worktreePlan.identities.contains(admin.appendingPathComponent("commondir").path))
        #expect(worktreePlan.roots.contains(admin.deletingLastPathComponent().path))
    }
    @Test func notesPolicyIncludesMarkdownAndParentReplacementEventsOnly() {
        let contents = SessionDirectoryWatcher.Contents.notes(root: URL(fileURLWithPath: "/sigil/notes"))
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let directory = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        for path in ["/sigil/notes/project/id.md", "/sigil/notes/codex/project/id.md"] {
            #expect(SessionDirectoryWatcher.shouldScan(path: path, flags: file, contents: contents))
        }
        for path in ["/sigil/notes-other/id.md", "/sigil/notes/id.md.tmp", "/sigil/other/id.md"] {
            #expect(!SessionDirectoryWatcher.shouldScan(path: path, flags: file, contents: contents))
        }
        for path in ["/sigil", "/sigil/notes", "/sigil/notes/project"] {
            #expect(SessionDirectoryWatcher.shouldScan(path: path, flags: directory, contents: contents))
        }
        #expect(!SessionDirectoryWatcher.shouldScan(path: "/sigil/other", flags: directory, contents: contents))
    }
    @Test func nativePolicyIncludesOnlyTranscriptsAndExactAdjacentIndex() {
        let contents = SessionDirectoryWatcher.Contents.nativeHistory(
            root: URL(fileURLWithPath: "/codex/sessions"),
            titleIndex: URL(fileURLWithPath: "/codex/session_index.jsonl"))
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        for path in ["/codex/sessions/2026/09/27/session.jsonl", "/codex/session_index.jsonl"] {
            #expect(SessionDirectoryWatcher.shouldScan(path: path, flags: flags, contents: contents))
            #expect(!SessionDirectoryWatcher.shouldScan(path: path, flags: flags))
        }
        for path in [
            "/codex/history.jsonl", "/codex/log/session_index.jsonl", "/codex/sessions-other/session.jsonl",
            "/codex/sessions/session.jsonl.lock", "/codex/sessions/summary.json",
        ] {
            #expect(!SessionDirectoryWatcher.shouldScan(path: path, flags: flags, contents: contents))
        }
        let directory = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        for path in ["/codex", "/codex/sessions", "/codex/sessions/2026/09"] {
            #expect(SessionDirectoryWatcher.shouldScan(path: path, flags: directory, contents: contents))
        }
        #expect(!SessionDirectoryWatcher.shouldScan(path: "/codex/log", flags: directory, contents: contents))
        let coalesced = SessionDirectoryWatcher.decision(
            paths: ["/codex"], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)],
            contents: contents)
        #expect(coalesced.scan && !coalesced.restart)
        let restarted = SessionDirectoryWatcher.decision(
            paths: ["/codex"], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)],
            contents: contents)
        #expect(restarted.scan && restarted.restart)
    }

    @Test func nativePolicyMatchesCanonicalEventsThroughConfiguredSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Sigil-watch-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let contents = SessionDirectoryWatcher.Contents.nativeHistory(
            root: alias.appendingPathComponent("sessions"),
            titleIndex: alias.appendingPathComponent("session_index.jsonl"))
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        #expect(
            SessionDirectoryWatcher.shouldScan(
                path: actual.appendingPathComponent("sessions/record.jsonl").resolvingSymlinksInPath().path,
                flags: flags, contents: contents))
        #expect(
            SessionDirectoryWatcher.shouldScan(
                path: actual.appendingPathComponent("session_index.jsonl").resolvingSymlinksInPath().path,
                flags: flags, contents: contents))
    }

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
