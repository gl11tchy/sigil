import Foundation
import Testing

@testable import SigilApp

@Suite
@MainActor
struct SidebarSearchTests {

    @Test func searchReachesEveryFolderIncludingArchivedAndRanksTheCloserTitle() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let api = try fixture.directory("acme-api")
        let web = try fixture.directory("acme-web")
        let tools = try fixture.directory("auth-tools")
        try fixture.writeListedSession(
            id: "exact", cwd: web.path, summary: "Auth", updatedAt: "2026-01-01T00:00:00Z")
        try fixture.writeListedSession(
            id: "prefix", cwd: api.path, summary: "Auth notes", updatedAt: "2026-03-01T00:00:00Z")
        try fixture.writeListedSession(
            id: "path", cwd: tools.path, summary: "Weekly", updatedAt: "2026-06-01T00:00:00Z")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let exact = try #require(model.store.sessions.first { $0.id == "exact" })
        model.archive(exact)
        let open = try #require(model.sidebarProjects.first { $0.name == "acme-api" })
        model.openProject(open)

        model.searchText = "auth"
        #expect(model.sidebarSessions.map(\.id) == ["exact", "prefix", "path"])
        #expect(model.focusedProject?.name == "acme-api")
        #expect(
            model.newSessionDirectory.resolvingSymlinksInPath().path
                == api.resolvingSymlinksInPath().path)

        let top = try #require(model.sidebarSessions.first)
        model.open(top)
        #expect(model.selectedTab?.sessionID == "exact")
    }

    @Test func emptyQueryHidesArchivedChatsAndKeepsTheOpenFolder() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let api = try fixture.directory("acme-api")
        let web = try fixture.directory("acme-web")
        try fixture.writeListedSession(
            id: "live", cwd: api.path, summary: "API chat", updatedAt: "2026-03-01T00:00:00Z")
        try fixture.writeListedSession(
            id: "old", cwd: web.path, summary: "Old chat", updatedAt: "2026-01-01T00:00:00Z")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let old = try #require(model.store.sessions.first { $0.id == "old" })
        model.archive(old)
        let open = try #require(model.sidebarProjects.first { $0.name == "acme-api" })
        model.openProject(open)

        #expect(model.searchText.isEmpty)
        #expect(model.sidebarSessions.map(\.id) == ["live"])
        #expect(model.focusedSidebarSessions.map(\.id) == ["live"])
        #expect(
            model.newSessionDirectory.resolvingSymlinksInPath().path
                == api.resolvingSymlinksInPath().path)
    }

    @Test func escapeLeavesTheQueryInPlace() {
        #expect(
            SidebarOrganization.escapeAction(isRenaming: true, isSearching: false, surface: .project)
                == .cancelRename)
        #expect(
            SidebarOrganization.escapeAction(isRenaming: false, isSearching: false, surface: .project)
                == .leaveFolder)
        #expect(
            SidebarOrganization.escapeAction(isRenaming: false, isSearching: false, surface: .recents)
                == .leaveFolder)
        #expect(
            SidebarOrganization.escapeAction(
                isRenaming: false, isSearching: false, surface: .archived) == .leaveFolder)
        #expect(
            SidebarOrganization.escapeAction(isRenaming: false, isSearching: false, surface: .folders)
                == .leaveList)
    }

    /// Search results are global, so leaving the folder behind them changes
    /// nothing on screen and loses where the user was. Escape leaves the list.
    @Test func escapeWhileSearchingInsideAFolderLeavesTheList() {
        #expect(
            SidebarOrganization.escapeAction(isRenaming: false, isSearching: true, surface: .project)
                == .leaveList)
        #expect(
            SidebarOrganization.escapeAction(isRenaming: false, isSearching: true, surface: .recents)
                == .leaveList)
        #expect(
            SidebarOrganization.escapeAction(isRenaming: true, isSearching: true, surface: .project)
                == .cancelRename)
    }

    @Test func queryChangeSelectsTheTopRankedRow() {
        #expect(
            SidebarOrganization.selectionAfterQueryChange(query: "auth", topRowID: "exact")
                == .row("exact"))
        #expect(
            SidebarOrganization.selectionAfterQueryChange(query: "  auth  ", topRowID: "exact")
                == .row("exact"))
        #expect(
            SidebarOrganization.selectionAfterQueryChange(query: "   ", topRowID: "exact") == .keep)
        #expect(
            SidebarOrganization.selectionAfterQueryChange(query: "", topRowID: "exact") == .keep)
        #expect(
            SidebarOrganization.selectionAfterQueryChange(query: "missing", topRowID: nil)
                == .row(nil))
    }

    @Test func whitespaceIsNotASearch() {
        #expect(!SidebarOrganization.isSearching("  \n\t "))
        #expect(SidebarOrganization.isSearching("a"))
    }
}
