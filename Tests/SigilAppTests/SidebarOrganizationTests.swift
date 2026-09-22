import Foundation
import SigilKit
import Testing

@testable import SigilApp

struct SidebarOrganizationTests {
    @Test func activationKeyPrefersTheCurrentSelection() {
        let keys = ["a", "b", "c"]
        #expect(SidebarOrganization.activationKey(preferred: "b", in: keys) == "b")
        #expect(SidebarOrganization.activationKey(preferred: "stale", in: keys) == "a")
        #expect(SidebarOrganization.activationKey(preferred: nil, in: keys) == "a")
        #expect(SidebarOrganization.activationKey(preferred: "a", in: []) == nil)
    }

    @Test func projectsWithTheSameBasenameUseDisplayPaths() {
        let first = session(id: "a", cwd: "/workspace/a/web", updated: 2)
        let second = session(id: "b", cwd: "/workspace/b/web", updated: 1)
        let unique = session(id: "c", cwd: "/workspace/c/unique", updated: 3)
        let grouped = SidebarOrganization.projects(from: [unique, first, second]) { $0 }
        #expect(grouped.map(\.name) == ["unique", "/workspace/a/web", "/workspace/b/web"])
    }

    @Test func pinningPrependsAndIsIdempotentOnIdentity() {
        let first = session(id: "a", cwd: "/tmp/one", updated: 2)
        let second = session(id: "b", cwd: "/tmp/two", updated: 1)
        var pins: [OpenTabsSnapshot.Entry] = []
        pins = SidebarOrganization.inserting(first, onto: pins, samePath: ==)
        pins = SidebarOrganization.inserting(second, onto: pins, samePath: ==)
        #expect(pins.map(\.sessionID) == ["b", "a"])

        pins = SidebarOrganization.inserting(first, onto: pins, samePath: ==)
        #expect(pins.map(\.sessionID) == ["a", "b"])
    }

    @Test func pinsMatchByIdAndWorkingDirectory() {
        let kept = session(id: "same", cwd: "/tmp/one", updated: 2)
        let otherFolder = session(id: "same", cwd: "/tmp/two", updated: 1)
        let pins = [
            OpenTabsSnapshot.Entry(sessionID: "same", cwd: "/tmp/one")
        ]
        let matched = SidebarOrganization.matching(
            sessions: [otherFolder, kept],
            entries: pins,
            samePath: ==
        )
        #expect(matched.map(\.cwd) == ["/tmp/one"])
        #expect(
            SidebarOrganization.without(
                sessions: [otherFolder, kept],
                entries: pins,
                samePath: ==
            ).map(\.cwd) == ["/tmp/two"]
        )
    }

    @Test func projectPinningPrependsAndIsIdempotentOnPath() {
        var pins: [String] = []
        pins = SidebarOrganization.inserting("/tmp/one", onto: pins, samePath: ==)
        pins = SidebarOrganization.inserting("/tmp/two", onto: pins, samePath: ==)
        #expect(pins == ["/tmp/two", "/tmp/one"])

        pins = SidebarOrganization.inserting("/tmp/one", onto: pins, samePath: ==)
        #expect(pins == ["/tmp/one", "/tmp/two"])
    }

    @Test func projectPinsMatchByCanonicalWorkingDirectory() {
        let newer = session(id: "n", cwd: "/tmp/alias", name: "newer", updated: 3)
        let other = session(id: "p", cwd: "/tmp/other", name: "other", updated: 2)
        let grouped = SidebarOrganization.projects(from: [newer, other]) { path in
            path == "/tmp/alias" ? "/private/tmp/alias" : path
        }
        let samePath: (String, String) -> Bool = { lhs, rhs in
            let canon: (String) -> String = {
                $0 == "/tmp/alias" || $0 == "/private/tmp/alias" ? "/private/tmp/alias" : $0
            }
            return canon(lhs) == canon(rhs)
        }
        let matched = SidebarOrganization.matching(
            projects: grouped,
            paths: ["/private/tmp/alias"],
            samePath: samePath
        )
        #expect(matched.map(\.cwd) == ["/tmp/alias"])
        #expect(
            SidebarOrganization.without(
                projects: grouped,
                paths: ["/tmp/alias"],
                samePath: samePath
            ).map(\.cwd) == ["/tmp/other"]
        )
    }

    @Test func projectsGroupByCanonicalPathAndKeepNewestFirst() {
        let newer = session(id: "n", cwd: "/tmp/alias", name: "newer", updated: 3)
        let older = session(id: "o", cwd: "/tmp/alias", name: "older", updated: 1)
        let other = session(id: "p", cwd: "/tmp/other", name: "other", updated: 2)
        let grouped = SidebarOrganization.projects(from: [newer, other, older]) { path in
            path == "/tmp/alias" ? "/private/tmp/alias" : path
        }
        #expect(grouped.map(\.id) == ["/private/tmp/alias", "/tmp/other"])
        #expect(grouped[0].sessions.map(\.id) == ["n", "o"])
        #expect(grouped[0].count == 2)
        #expect(grouped[1].sessions.map(\.id) == ["p"])
    }

    @Test func foldersAreTheHomeList() {
        #expect(
            SidebarOrganization.listKind(surface: .folders, isSearching: false) == .projectList)
    }

    @Test func aFocusedProjectShowsItsChats() {
        #expect(
            SidebarOrganization.listKind(surface: .project, isSearching: false) == .projectChats)
    }

    @Test func aNonEmptyQueryIsNotLimitedToTheOpenFolder() {
        let project = SidebarOrganization.listKind(surface: .project, isSearching: true)
        let folders = SidebarOrganization.listKind(surface: .folders, isSearching: true)
        let recents = SidebarOrganization.listKind(surface: .recents, isSearching: true)
        let archived = SidebarOrganization.listKind(surface: .archived, isSearching: true)
        #expect(project == .search)
        #expect(project == folders)
        #expect(project == recents)
        #expect(project == archived)
        #expect(project != .projectChats)
        #expect(project != .projectSearch)
        #expect(project != .projectList)
        #expect(project != .recents)
        #expect(project != .archived)
    }

    @Test func recentsAndArchivedAreTheirOwnLists() {
        #expect(SidebarOrganization.listKind(surface: .recents, isSearching: false) == .recents)
        #expect(SidebarOrganization.listKind(surface: .archived, isSearching: false) == .archived)
    }

    @Test func sentinelPathsAreNotRealFolders() {
        #expect(SidebarOrganization.isSentinel(SidebarOrganization.recentsID))
        #expect(SidebarOrganization.isSentinel(SidebarOrganization.archivedID))
        #expect(!SidebarOrganization.isSentinel("/tmp/sigil"))
        #expect(!SidebarOrganization.isSentinel(""))
    }

    @Test func surfaceReadsSentinelPathsBeforeARealFolder() {
        #expect(SidebarOrganization.surface(focusedPath: SidebarOrganization.recentsID) == .recents)
        #expect(
            SidebarOrganization.surface(focusedPath: SidebarOrganization.archivedID) == .archived)
        #expect(SidebarOrganization.surface(focusedPath: "/tmp/sigil") == .project)
        #expect(SidebarOrganization.surface(focusedPath: "") == .folders)
    }

    @Test func folderListContainsOnlyProjects() {
        #expect(
            SidebarOrganization.folderListRowIDs(pinnedIDs: ["pin"], restIDs: ["rest"]) == [
                "pin", "rest",
            ])
        #expect(SidebarOrganization.folderListRowIDs(pinnedIDs: ["a"], restIDs: []) == ["a"])
    }

    @Test func destinationRowsAreRecentsThenArchived() {
        #expect(
            SidebarOrganization.destinationRowIDs(recentsCount: 2, archivedCount: 1) == [
                SidebarOrganization.recentsID, SidebarOrganization.archivedID,
            ])
        #expect(SidebarOrganization.destinationRowIDs(recentsCount: 0, archivedCount: 0).isEmpty)
        #expect(
            SidebarOrganization.destinationRowIDs(recentsCount: 1, archivedCount: 0) == [
                SidebarOrganization.recentsID
            ])
        #expect(
            SidebarOrganization.destinationRowIDs(recentsCount: 0, archivedCount: 3) == [
                SidebarOrganization.archivedID
            ])
    }

    @Test func homeListPutsDestinationsAfterProjects() {
        #expect(
            SidebarOrganization.homeRowIDs(
                recentsCount: 2,
                archivedCount: 1,
                pinnedIDs: ["pin"],
                restIDs: ["rest"]
            ) == [
                "pin", "rest", SidebarOrganization.recentsID, SidebarOrganization.archivedID,
            ])
        #expect(
            SidebarOrganization.homeRowIDs(
                recentsCount: 0, archivedCount: 0, pinnedIDs: ["a"], restIDs: []
            ) == ["a"])
    }

    @Test func pathHaystacksIncludeEveryMemberSpelling() {
        let sample = session(id: "a", cwd: "/var/folders/x", name: "n", updated: 2)
        let sibling = session(id: "b", cwd: "/private/var/folders/x", name: "n", updated: 1)
        let hay = SidebarOrganization.pathHaystacks(
            name: "x",
            displayPath: "/var/folders/x",
            cwd: "/var/folders/x",
            sessions: [sample, sibling]
        )
        #expect(hay.contains("/var/folders/x"))
        #expect(hay.contains("/private/var/folders/x"))
        #expect(hay.first == "x")
    }

    @Test func indexByDirectoryLooksUpAProjectInConstantTime() {
        let a1 = session(id: "a1", cwd: "/p/a", updated: 2)
        let a2 = session(id: "a2", cwd: "/p/a", updated: 1)
        let b1 = session(id: "b1", cwd: "/p/b", updated: 3)
        let grouped = SidebarOrganization.projects(from: [b1, a1, a2]) { $0 }
        let index = SidebarOrganization.indexByDirectory(grouped)
        #expect(index[a1.directory]?.id == "/p/a")
        #expect(index[a2.directory]?.id == "/p/a")
        #expect(index[b1.directory]?.id == "/p/b")
        #expect(index[URL(fileURLWithPath: "/missing")] == nil)
    }

    @Test func listedRowsKeepTheUnpinnedIntersectionWithoutNestedScans() {
        let pinned = session(id: "pin", cwd: "/p/a", updated: 3)
        let kept = session(id: "kept", cwd: "/p/a", updated: 2)
        let other = session(id: "other", cwd: "/p/b", updated: 1)
        let grouped = SidebarOrganization.projects(from: [pinned, kept, other]) { $0 }
        let project = grouped.first { $0.id == "/p/a" }!
        let rows = SidebarOrganization.listedRows(in: project, from: [kept, other])
        #expect(rows.map(\.id) == ["kept"])
    }
}

private func session(
    id: String,
    cwd: String,
    name: String = "Session",
    updated: TimeInterval
) -> GrokSession {
    GrokSession(
        id: id,
        cwd: cwd,
        summary: name,
        createdAt: Date(timeIntervalSince1970: updated),
        updatedAt: Date(timeIntervalSince1970: updated),
        messageCount: 4,
        modelID: nil,
        agentName: nil,
        reasoningEffort: nil,
        directory: URL(fileURLWithPath: cwd).appendingPathComponent(id)
    )
}
