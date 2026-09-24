import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
@MainActor
struct SidebarSnapshotTests {

    @Test func snapshotEqualsTheComputedListsOnEverySurface() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.directory("alpha")
        let beta = try fixture.directory("beta")
        let gamma = try fixture.directory("gamma")
        try fixture.writeListedSession(
            id: "a-new", cwd: alpha.path, summary: "Quartz rewrite", updatedAt: "2026-08-05T00:00:00Z")
        try fixture.writeListedSession(
            id: "b-live", cwd: beta.path, summary: "Quartz tests", updatedAt: "2026-08-04T00:00:00Z")
        try fixture.writeListedSession(
            id: "g-one", cwd: gamma.path, summary: "Deploy", updatedAt: "2026-08-03T00:00:00Z")
        try fixture.writeListedSession(
            id: "a-old", cwd: alpha.path, summary: "Build notes", updatedAt: "2026-08-02T00:00:00Z")
        try fixture.writeListedSession(
            id: "b-gone", cwd: beta.path, summary: "Old quartz", updatedAt: "2026-08-01T00:00:00Z")
        try fixture.writeListedSession(
            id: "g-gone", cwd: gamma.path, summary: "Old deploy", updatedAt: "2026-07-30T00:00:00Z")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        func session(_ id: String) throws -> GrokSession {
            try #require(model.store.sessions.first { $0.id == id })
        }
        func keys(_ ids: [String]) throws -> [String] {
            try ids.map { model.sessionKey(try session($0)) }
        }
        model.archive(try session("b-gone"))
        model.archive(try session("g-gone"))
        model.pin(try session("b-live"))
        model.pin(try session("a-old"))
        let alphaProject = try #require(model.sidebarProjects.first { $0.name == "alpha" })
        let betaProject = try #require(model.sidebarProjects.first { $0.name == "beta" })
        let gammaProject = try #require(model.sidebarProjects.first { $0.name == "gamma" })
        model.pin(gammaProject)

        // Home: the nav items, then the pinned folder, then folders by newest chat.
        var snapshot = model.sidebarSnapshot()
        expectMatchesModelLists(snapshot, model)
        #expect(snapshot.listKind == .projectList)
        #expect(snapshot.pinnedProjects.map(\.name) == ["gamma"])
        #expect(snapshot.unpinnedProjects.map(\.name) == ["alpha", "beta"])
        #expect(snapshot.destinations == .init(recentsCount: 4, archivedCount: 2))
        #expect(
            snapshot.rowIDs
                == [
                    SidebarOrganization.recentsID, SidebarOrganization.archivedID,
                    gammaProject.id, alphaProject.id, betaProject.id,
                ])
        #expect(!snapshot.isListEmpty)

        // Recents: pinned chats in pin order, then the rest newest first.
        model.openRecents()
        snapshot = model.sidebarSnapshot()
        expectMatchesModelLists(snapshot, model)
        #expect(snapshot.listKind == .recents)
        #expect(snapshot.pinned.map(\.id) == ["a-old", "b-live"])
        #expect(snapshot.unpinned.map(\.id) == ["a-new", "g-one"])
        #expect(snapshot.destinations == .init(recentsCount: 4, archivedCount: 2))
        #expect(snapshot.rowIDs == (try keys(["a-old", "b-live", "a-new", "g-one"])))

        // Archived: grouped by folder, the pinned folder first.
        model.openArchived()
        snapshot = model.sidebarSnapshot()
        expectMatchesModelLists(snapshot, model)
        #expect(snapshot.listKind == .archived)
        #expect(snapshot.sessions.map(\.id) == ["b-gone", "g-gone"])
        #expect(snapshot.pinnedProjects.map(\.name) == ["gamma"])
        #expect(snapshot.rowIDs == (try keys(["g-gone", "b-gone"])))

        // An open folder: only its chats, and only its pinned chats above them.
        model.openProject(alphaProject)
        snapshot = model.sidebarSnapshot()
        expectMatchesModelLists(snapshot, model)
        #expect(snapshot.listKind == .projectChats)
        #expect(snapshot.focusedProject?.name == "alpha")
        #expect(snapshot.listed.map(\.id) == ["a-new", "a-old"])
        #expect(snapshot.pinned.map(\.id) == ["a-old"])
        #expect(snapshot.unpinned.map(\.id) == ["a-new"])
        #expect(snapshot.rowIDs == (try keys(["a-old", "a-new"])))

        // Search from inside the folder: every folder, archived chats included.
        model.searchText = "quartz"
        snapshot = model.sidebarSnapshot()
        expectMatchesModelLists(snapshot, model)
        #expect(snapshot.listKind == .search)
        #expect(snapshot.focusedProject?.name == "alpha")
        #expect(Set(snapshot.listed.map(\.id)) == ["a-new", "b-live", "b-gone"])
        #expect(snapshot.rowIDs == snapshot.listed.map { model.sessionKey($0) })

        // A query that matches nothing leaves an empty list.
        model.searchText = "no-such-chat"
        snapshot = model.sidebarSnapshot()
        expectMatchesModelLists(snapshot, model)
        #expect(snapshot.isListEmpty)
        #expect(snapshot.rowIDs.isEmpty)
    }

    @Test func snapshotFollowsSearchArchivePinTabAndFilterChanges() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.directory("alpha")
        let beta = try fixture.directory("beta")
        try fixture.writeListedSession(
            id: "a-one", cwd: alpha.path, summary: "Quartz rewrite", updatedAt: "2026-08-05T00:00:00Z")
        try fixture.writeListedSession(
            id: "b-one", cwd: beta.path, summary: "Deploy", updatedAt: "2026-08-04T00:00:00Z")
        try fixture.writeListedSession(
            id: "b-sub", cwd: beta.path, summary: "Helper", sessionKind: "subagent",
            updatedAt: "2026-08-06T00:00:00Z")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        func session(_ id: String) throws -> GrokSession {
            try #require(model.store.sessions.first { $0.id == id })
        }
        model.openRecents()
        expectMatchesModelLists(model.sidebarSnapshot(), model)
        #expect(model.sidebarSnapshot().listed.map(\.id) == ["a-one", "b-one"])

        model.settings.showSubagentSessions = true
        expectMatchesModelLists(model.sidebarSnapshot(), model)
        #expect(model.sidebarSnapshot().listed.map(\.id) == ["b-sub", "a-one", "b-one"])

        model.pin(try session("b-one"))
        expectMatchesModelLists(model.sidebarSnapshot(), model)
        #expect(model.sidebarSnapshot().pinned.map(\.id) == ["b-one"])

        model.archive(try session("a-one"))
        expectMatchesModelLists(model.sidebarSnapshot(), model)
        #expect(model.sidebarSnapshot().listed.map(\.id) == ["b-sub", "b-one"])

        model.searchText = "quartz"
        expectMatchesModelLists(model.sidebarSnapshot(), model)
        #expect(model.sidebarSnapshot().listed.map(\.id) == ["a-one"])

        model.searchText = ""
        model.leaveProject()
        model.open(try session("b-one"))
        let tab = try #require(model.selectedTab)
        let snapshot = model.sidebarSnapshot()
        expectMatchesModelLists(snapshot, model)
        #expect(
            Array(snapshot.rowIDs.prefix(3)) == [
                SidebarOrganization.recentsID, SidebarOrganization.archivedID,
                SidebarOrganization.openTabRowID(tab.id),
            ])
        #expect(snapshot.destinations == .init(recentsCount: 2, archivedCount: 1))
    }

    @Test func snapshotListsAnAddedFolderBeforeItHasAChat() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let alpha = try fixture.directory("alpha")
        try fixture.writeListedSession(
            id: "a-one", cwd: alpha.path, summary: "Quartz rewrite", updatedAt: "2026-08-05T00:00:00Z")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()
        let added = try fixture.directory("added")

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.addProject(added)

        var snapshot = model.sidebarSnapshot()
        expectMatchesModelLists(snapshot, model)
        #expect(snapshot.unpinnedProjects.map(\.name) == ["added", "alpha"])
        let addedProject = try #require(snapshot.unpinnedProjects.first)
        #expect(addedProject.sessions.isEmpty)
        #expect(snapshot.rowIDs.contains(addedProject.id))

        // A search lists only matching chats, so the chatless folder drops out.
        model.searchText = "quartz"
        snapshot = model.sidebarSnapshot()
        expectMatchesModelLists(snapshot, model)
        #expect(!snapshot.projects.contains { $0.id == addedProject.id })
    }
}

/// The lists SidebarView used to read one at a time from the model during a render.
@MainActor
private func expectMatchesModelLists(
    _ snapshot: SidebarSnapshot,
    _ model: AppModel,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let kind = SidebarOrganization.listKind(
        surface: model.sidebarSurface,
        isSearching: SidebarOrganization.isSearching(model.searchText)
    )
    let listed = kind == .projectChats ? model.focusedSidebarSessions : model.sidebarSessions
    let pinned =
        kind == .projectChats ? model.pinnedSessions(in: model.focusedProject) : model.pinnedSessions()
    #expect(snapshot.listKind == kind, sourceLocation: sourceLocation)
    #expect(snapshot.sessions == model.sidebarSessions, sourceLocation: sourceLocation)
    #expect(snapshot.projects == model.sidebarProjects, sourceLocation: sourceLocation)
    #expect(snapshot.focusedProject == model.focusedProject, sourceLocation: sourceLocation)
    #expect(snapshot.listed == listed, sourceLocation: sourceLocation)
    #expect(snapshot.pinned == pinned, sourceLocation: sourceLocation)
    #expect(snapshot.unpinned == model.unpinnedSessions(from: listed), sourceLocation: sourceLocation)
    #expect(snapshot.pinnedProjects == model.pinnedProjects(), sourceLocation: sourceLocation)
    #expect(snapshot.unpinnedProjects == model.unpinnedProjects(), sourceLocation: sourceLocation)
    #expect(
        snapshot.isListEmpty
            == (kind == .projectList ? model.sidebarProjects.isEmpty : listed.isEmpty),
        sourceLocation: sourceLocation)
    #expect(
        snapshot.destinations
            == .init(recentsCount: model.sidebarSessions.count, archivedCount: model.archivedCount),
        sourceLocation: sourceLocation)
}
