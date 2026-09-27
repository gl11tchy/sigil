import Foundation
import SigilKit
import Testing

@testable import SigilApp

/// The id-first sidebar snapshot draws exactly what the per-entry scans drew,
/// on random saved lists with shared chat ids and symlinked folders.
@Suite(.serialized)
@MainActor
struct MacSidebarSnapshotEquivalenceTests {
    private static let summaries = ["Quartz rewrite", "Deploy notes", "Build", "", "quartz tests"]
    private static let names = ["", "  ", "Quartz named", " Renamed deploy "]
    private static let queries = ["", "  ", "quartz", "deploy", "renamed", "no-such-chat"]

    @Test func indexedSnapshotMatchesTheScanOnRandomLists() async throws {
        // What the random lists covered, so a weak seed range cannot pass quietly.
        var linkedRows = 0, sharedIDs = 0, pinnedRows = 0, archivedRows = 0, namedRows = 0
        for seed in UInt64(1)...8 {
            var rng = SplitMix64(seed: seed)
            let fixture = try ModelFixture()
            defer { fixture.cleanup() }
            // Each folder has its real path and a symlink to it; both spellings
            // are one folder.
            var spellings: [[String]] = []
            for name in ["alpha", "beta", "gamma"] {
                let real = try fixture.directory(name)
                let link = fixture.root.appendingPathComponent("link-\(name)")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
                spellings.append([real.path, link.path])
            }
            func spelling(_ folder: Int) -> String { spellings[folder].randomElement(using: &rng)! }

            // Few ids across three folders: the same id is a different chat in
            // each folder it appears in.
            let ids = (0..<6).map { "id\($0)" }
            var written = Set<String>()
            for index in 0..<Int.random(in: 8...24, using: &rng) {
                let id = ids.randomElement(using: &rng)!
                let folder = Int.random(in: 0..<spellings.count, using: &rng)
                guard written.insert("\(id)|\(folder)").inserted else { continue }
                try fixture.writeListedSession(
                    id: id, cwd: spelling(folder),
                    summary: Self.summaries.randomElement(using: &rng)!,
                    messages: Int.random(in: 0...4, using: &rng),
                    updatedAt: String(format: "2026-08-%02dT00:00:00Z", 1 + index))
            }
            func entry() -> OpenTabsSnapshot.Entry {
                OpenTabsSnapshot.Entry(
                    sessionID: Bool.random(using: &rng) ? ids.randomElement(using: &rng)! : "missing",
                    cwd: spelling(Int.random(in: 0..<spellings.count, using: &rng)))
            }
            fixture.settings.showEmptySessions = false
            fixture.settings.showWorktreeSessions = true
            fixture.settings.pinnedConversations = (0..<Int.random(in: 0...8, using: &rng)).map { _ in entry() }
            fixture.settings.archivedConversations = (0..<Int.random(in: 0...8, using: &rng)).map { _ in entry() }
            fixture.settings.conversationNames = (0..<Int.random(in: 0...8, using: &rng)).map { _ in
                let target = entry()
                return ConversationName(
                    sessionID: target.sessionID, cwd: target.cwd, name: Self.names.randomElement(using: &rng)!)
            }
            await fixture.store.reload()

            let model = fixture.model()
            defer { model.closeAllTabsAndWait() }
            let all = model.store.sessions
            linkedRows += all.filter { $0.cwd.contains("/link-") }.count
            sharedIDs += Dictionary(grouping: all, by: \.id).values.filter { $0.count > 1 }.count
            pinnedRows += all.filter { model.isPinned($0) }.count
            archivedRows += all.filter { model.isArchived($0) }.count
            namedRows += all.filter { model.hasCustomName($0) }.count
            let folderPaths = spellings.map { $0[Int.random(in: 0...1, using: &rng)] }
            let surfaces: [() -> Void] =
                [model.leaveProject, model.openRecents, model.openArchived]
                + folderPaths.map { path in { model.settings.focusedProjectPath = path } }
            for (surface, open) in surfaces.enumerated() {
                open()
                for query in Self.queries {
                    model.searchText = query
                    expectMatchesTheScan(
                        model.sidebarSnapshot(), model, "seed \(seed) surface \(surface) query \(query)")
                    #expect(model.sidebarSessions == model.sidebarSnapshot().sessions)
                    #expect(model.archivedCount == model.sidebarSnapshot().destinations.archivedCount)
                }
            }
        }
        #expect(
            linkedRows > 0 && sharedIDs > 0 && pinnedRows > 0 && archivedRows > 0 && namedRows > 0,
            "\(linkedRows) \(sharedIDs) \(pinnedRows) \(archivedRows) \(namedRows)")
    }
}

/// The pre-index pipeline: per-chat `title(for:)` and `isArchived` scans and
/// the per-pin `samePath` scans, compared field by field and row by row.
@MainActor
private func expectMatchesTheScan(
    _ snapshot: SidebarSnapshot,
    _ model: AppModel,
    _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let canonical: (String) -> String = { GrokPaths.canonicalPath($0) }
    let samePath: (String, String) -> Bool = { canonical($0) == canonical($1) }
    let searching = SidebarOrganization.isSearching(model.searchText)
    let surface = model.sidebarSurface
    // No tabs are open and every other filter is off, so the empty filter is
    // the one left: a summary, more than the opening exchange, or a name.
    let passes: (GrokSession) -> Bool = {
        !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || $0.messageCount > 2 || model.hasCustomName($0)
    }
    var sessions = model.store.search(model.searchText) { model.title(for: $0) }.filter(passes)
    if !searching {
        sessions = sessions.filter { model.isArchived($0) == (surface == .archived) }
    }
    let archivedCount = model.store.sessions.filter { model.isArchived($0) && passes($0) }.count
    let kind = SidebarOrganization.listKind(surface: surface, isSearching: searching)
    var projects = SidebarOrganization.projects(from: sessions, canonicalPath: canonical)
    if !searching, surface != .archived {
        projects = SidebarOrganization.merging(
            added: model.settings.addedProjects, into: projects, canonicalPath: canonical)
    }
    let path = model.settings.focusedProjectPath
    let isFolder: (SidebarProject) -> Bool = { $0.id == canonical(path) || samePath($0.cwd, path) }
    let focused =
        surface == .project
        ? projects.first(where: isFolder)
            ?? SidebarOrganization.projects(from: model.store.sessions, canonicalPath: canonical)
            .first(where: isFolder)
        : nil
    let folder = kind == .projectChats ? focused : nil
    let pins = model.settings.pinnedConversations
    let listed = SidebarOrganization.sessions(sessions, in: folder, samePath: samePath)
    let pinned = MacSidebarReferenceScan.pinned(sessions: sessions, entries: pins, in: folder, samePath: samePath)
    let unpinned = MacSidebarReferenceScan.without(sessions: listed, entries: pins, samePath: samePath)
    let pinnedProjects = SidebarOrganization.matching(
        projects: projects, paths: model.settings.pinnedProjects, samePath: samePath)
    let unpinnedProjects = SidebarOrganization.without(
        projects: projects, paths: model.settings.pinnedProjects, samePath: samePath)
    let rowIDs: [String]
    switch kind {
    case .projectList:
        rowIDs = SidebarOrganization.homeRowIDs(
            recentsCount: sessions.count, archivedCount: archivedCount,
            pinnedIDs: pinnedProjects.map(\.id), restIDs: unpinnedProjects.map(\.id), openTabIDs: [])
    case .search:
        rowIDs = listed.map(model.sessionKey)
    case .recents, .projectChats:
        rowIDs = (pinned + unpinned).map(model.sessionKey)
    case .archived:
        let listedDirectories = Set(unpinned.map(\.directory))
        rowIDs = (pinned + (pinnedProjects + unpinnedProjects).flatMap {
            SidebarOrganization.listedRows(in: $0, listed: listedDirectories)
        }).map(model.sessionKey)
    }

    #expect(snapshot.listKind == kind, comment, sourceLocation: sourceLocation)
    #expect(snapshot.sessions == sessions, comment, sourceLocation: sourceLocation)
    #expect(snapshot.projects == projects, comment, sourceLocation: sourceLocation)
    #expect(snapshot.focusedProject == focused, comment, sourceLocation: sourceLocation)
    #expect(snapshot.listed == listed, comment, sourceLocation: sourceLocation)
    #expect(snapshot.pinned == pinned, comment, sourceLocation: sourceLocation)
    #expect(snapshot.unpinned == unpinned, comment, sourceLocation: sourceLocation)
    #expect(snapshot.pinnedProjects == pinnedProjects, comment, sourceLocation: sourceLocation)
    #expect(snapshot.unpinnedProjects == unpinnedProjects, comment, sourceLocation: sourceLocation)
    #expect(
        snapshot.destinations == .init(recentsCount: sessions.count, archivedCount: archivedCount),
        comment, sourceLocation: sourceLocation)
    #expect(snapshot.rowIDs == rowIDs, comment, sourceLocation: sourceLocation)
}
