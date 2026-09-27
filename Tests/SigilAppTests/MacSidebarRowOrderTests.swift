import Foundation
import SigilKit
import Testing

@testable import SigilApp

/// Event-time row order reuses the snapshot the last render built, and builds
/// a new one after any change the snapshot reads.
@Suite(.serialized)
@MainActor
struct MacSidebarRowOrderTests {

    @Test func eventsReuseTheRenderedSnapshot() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.directory("alpha")
        try fixture.writeListedSession(id: "a-one", cwd: alpha.path, updatedAt: "2026-08-02T00:00:00Z")
        try fixture.writeListedSession(id: "a-two", cwd: alpha.path, updatedAt: "2026-08-01T00:00:00Z")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.openRecents()

        // No render yet: the first event builds one.
        let first = model.eventSidebarSnapshot()
        #expect(model.sidebarSnapshotBuildCount == 1)
        #expect(first.listed.map(\.id) == ["a-one", "a-two"])

        // A render always builds; the arrow keys and cleanup after it do not.
        let rendered = model.sidebarSnapshot()
        #expect(model.sidebarSnapshotBuildCount == 2)
        for _ in 0..<5 {
            #expect(model.eventSidebarSnapshot() == rendered)
        }
        #expect(model.sidebarSnapshotBuildCount == 2)
    }

    @Test func everyInputChangeBuildsANewSnapshot() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.directory("alpha")
        let beta = try fixture.directory("beta")
        try fixture.writeListedSession(
            id: "a-one", cwd: alpha.path, summary: "Quartz rewrite", updatedAt: "2026-08-04T00:00:00Z")
        try fixture.writeListedSession(
            id: "b-one", cwd: beta.path, summary: "Deploy", updatedAt: "2026-08-03T00:00:00Z")
        try fixture.writeListedSession(
            id: "b-empty", cwd: beta.path, summary: "", messages: 1, updatedAt: "2026-08-02T00:00:00Z")
        try fixture.writeListedSession(
            id: "a-empty", cwd: alpha.path, summary: "", messages: 1, updatedAt: "2026-08-02T00:00:00Z")
        try fixture.writeListedSession(
            id: "b-sub", cwd: beta.path, summary: "Helper", sessionKind: "subagent",
            updatedAt: "2026-08-01T00:00:00Z")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        func session(_ id: String) throws -> GrokSession {
            try #require(model.store.sessions.first { $0.id == id })
        }
        let betaProject = try #require(model.sidebarProjects.first { $0.name == "beta" })

        var previous = model.sidebarSnapshot()
        /// The event after a change builds once, draws what a render would,
        /// differs from the rows before the change, then is reused.
        func expectRebuilt(_ change: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
            let builds = model.sidebarSnapshotBuildCount
            let event = model.eventSidebarSnapshot()
            #expect(model.sidebarSnapshotBuildCount == builds + 1, change, sourceLocation: sourceLocation)
            #expect(event != previous, change, sourceLocation: sourceLocation)
            #expect(model.eventSidebarSnapshot() == event, change, sourceLocation: sourceLocation)
            #expect(model.sidebarSnapshotBuildCount == builds + 1, change, sourceLocation: sourceLocation)
            #expect(event == model.sidebarSnapshot(), change, sourceLocation: sourceLocation)
            previous = event
        }

        model.openRecents()
        expectRebuilt("navigation scope: Recents")
        model.openProject(betaProject)
        expectRebuilt("navigation scope: a folder")
        model.openArchived()
        expectRebuilt("navigation scope: Archived")
        model.leaveProject()
        expectRebuilt("navigation scope: home")
        model.searchText = "quartz"
        expectRebuilt("query")
        model.searchText = ""
        expectRebuilt("query cleared")

        model.openRecents()
        expectRebuilt("back to Recents")
        model.pin(try session("b-one"))
        expectRebuilt("pin")
        model.archive(try session("a-one"))
        expectRebuilt("archive")
        model.settings.conversationNames = [
            ConversationName(sessionID: "b-empty", cwd: beta.path, name: "Named now")
        ]
        expectRebuilt("name")
        model.settings.showEmptySessions = true
        expectRebuilt("empty filter")
        model.settings.showSubagentSessions = true
        expectRebuilt("subagent filter")
        model.settings.showWorktreeSessions = false
        expectRebuilt("worktree filter")
        model.settings.showWorktreeSessions = true
        expectRebuilt("worktree filter back")

        // Next to a-one on disk: other suites move GROK_HOME while this one waits.
        let fresh = try session("a-one").directory.deletingLastPathComponent().appendingPathComponent("a-new")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try JSONSerialization.data(
            withJSONObject: [
                "info": ["id": "a-new", "cwd": alpha.path],
                "session_summary": "Fresh",
                "created_at": "2026-08-05T00:00:00Z",
                "updated_at": "2026-08-05T00:00:00Z",
                "num_chat_messages": 4,
            ] as [String: Any]
        ).write(to: fresh.appendingPathComponent("summary.json"))
        await fixture.store.reload()
        expectRebuilt("sessions")

        model.leaveProject()
        expectRebuilt("home again")
        model.pin(betaProject)
        expectRebuilt("pinned folder")
        model.addProject(try fixture.directory("added"))
        expectRebuilt("added folder")
        model.open(try session("b-one"))
        expectRebuilt("open tab")
    }
}
