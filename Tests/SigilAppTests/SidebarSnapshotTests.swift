import Foundation
import Observation
import Testing
import os

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct SidebarSnapshotTests {
    @Test func heldInitialNotePublicationDoesNotInvalidateAnIdleObservedSnapshot() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        let folder = try fixture.directory("held-note-publication")
        try fixture.writeListedSession(id: "note", cwd: folder.path, summary: "Weekly")
        await fixture.store.reload()
        let note = try #require(fixture.store.sessions.first)
        let writer = ConversationNotesStore(root: fixture.notesRoot)
        writer.setNote("zirconia", for: note.id, cwd: note.cwd)
        writer.flushNow()
        let gate = SnapshotNoteReadGate()
        defer { gate.release() }
        let notes = ConversationNotesStore(root: fixture.notesRoot, searchReader: gate.reader)
        let model = snapshotModel(fixture, clock: SnapshotClock(), notesStore: notes)
        defer { model.closeAllTabsAndWait() }
        model.openRecents()
        let enteredDeadline = ContinuousClock.now + .seconds(4)
        while !gate.entered, ContinuousClock.now < enteredDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(gate.entered)
        #expect(notes.searchPublishedCount == 0)
        let generation = notes.searchGeneration
        let observed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.sidebarSnapshot()
        } onChange: {
            observed.withLock { $0 = true }
        }
        let builds = model.sidebarSnapshotBuildCount
        gate.release()
        let publicationDeadline = ContinuousClock.now + .seconds(4)
        while notes.searchPublishedCount == 0, ContinuousClock.now < publicationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(notes.searchPublishedCount > 0)
        #expect(notes.searchGeneration > generation)
        #expect(!observed.withLock { $0 })
        #expect(model.sidebarSnapshot().listed == [note])
        #expect(model.sidebarSnapshotBuildCount == builds)
    }

    @Test func notesPublicationAndUnsavedEditsInvalidateTheCachedSidebar() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        fixture.settings.showWorktreeSessions = true
        let folder = try fixture.directory("note-search")
        try fixture.writeListedSession(
            id: "title", cwd: folder.path, summary: "Zirconia", updatedAt: "2026-01-01T00:00:00Z")
        try fixture.writeListedSession(
            id: "note", cwd: folder.path, summary: "Weekly", updatedAt: "2026-06-01T00:00:00Z")
        await fixture.store.reload()
        let note = try #require(fixture.store.sessions.first { $0.id == "note" })
        let writer = ConversationNotesStore(root: fixture.notesRoot)
        writer.setNote("zirconia", for: note.id, cwd: note.cwd)
        writer.flushNow()
        let model = snapshotModel(fixture, clock: SnapshotClock())
        defer { model.closeAllTabsAndWait() }
        model.openRecents()
        model.searchText = "zirconia"
        _ = model.eventSidebarSnapshot()
        let deadline = ContinuousClock.now + .seconds(4)
        while !model.panel.notesStore.matchesSearch(for: note.reference), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.eventSidebarSnapshot().listed.map(\.id) == ["title", "note"])
        let count = model.sidebarSnapshotBuildCount
        model.panel.notesStore.setNote("sapphire", for: note.id, cwd: note.cwd)
        #expect(model.eventSidebarSnapshot().listed.map(\.id) == ["title"])
        #expect(model.sidebarSnapshotBuildCount == count + 1)
        model.searchText = "sapphire"
        _ = model.eventSidebarSnapshot()
        let editedDeadline = ContinuousClock.now + .seconds(4)
        while !model.panel.notesStore.matchesSearch(for: note.reference), ContinuousClock.now < editedDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.eventSidebarSnapshot().listed == [note])
        model.archive(note)
        // Search remains global and includes archived conversations.
        #expect(model.eventSidebarSnapshot().listed == [note])
        model.searchText = " \n "
        #expect(model.eventSidebarSnapshot().sessions.map(\.id) == ["title"])
        model.openArchived()
        #expect(model.eventSidebarSnapshot().sessions == [note])
        model.unarchive(note)
        model.openRecents()
        #expect(model.eventSidebarSnapshot().sessions == fixture.store.sessions)
        model.panel.notesStore.flushNow()
    }

    @Test func editingNotesDoesNotInvalidateAnIdleSidebarSnapshot() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        let folder = try fixture.directory("idle-notes")
        try fixture.writeListedSession(id: "note", cwd: folder.path, summary: "Weekly")
        await fixture.store.reload()
        let note = try #require(fixture.store.sessions.first)
        let model = snapshotModel(fixture, clock: SnapshotClock())
        defer { model.closeAllTabsAndWait() }
        model.openRecents()
        let original = model.eventSidebarSnapshot()
        let count = model.sidebarSnapshotBuildCount
        model.panel.notesStore.setNote("unsaved zirconia", for: note.id, cwd: note.cwd)
        #expect(model.eventSidebarSnapshot().sessions == original.sessions)
        #expect(model.sidebarSnapshotBuildCount == count)
        model.panel.notesStore.flushNow()
    }

    @Test func searchCategoriesAndTheirCacheInputsChangeOrderImmediately() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        fixture.settings.showWorktreeSessions = true
        let openFolder = try fixture.directory("search-open")
        let focusedFolder = try fixture.directory("search-focused")
        let otherFolder = try fixture.directory("search-other")
        for (id, folder, month) in [
            ("open", openFolder, "01"), ("pin", otherFolder, "02"),
            ("project", focusedFolder, "03"), ("other", otherFolder, "06"),
        ] {
            try fixture.writeListedSession(
                id: id, cwd: folder.path, summary: "Lim", updatedAt: "2026-\(month)-01T00:00:00Z")
        }
        await fixture.store.reload()
        let model = snapshotModel(fixture, clock: SnapshotClock())
        defer { model.closeAllTabsAndWait() }
        let open = try #require(fixture.store.sessions.first { $0.id == "open" })
        let pin = try #require(fixture.store.sessions.first { $0.id == "pin" })
        let project = try #require(model.sidebarProjects.first { $0.name == "search-focused" })
        model.openRecents()
        model.searchText = "lim"

        func expectRows(_ ids: [String]) {
            let snapshot = model.eventSidebarSnapshot()
            #expect(snapshot.listKind == .search)
            #expect(snapshot.listed.map(\.id) == ids)
            #expect(snapshot.rowIDs == snapshot.listed.map(model.sessionKey))
            _ = model.sidebarSnapshot()
        }
        func change(_ mutation: () -> Void, expecting ids: [String]) {
            let count = model.sidebarSnapshotBuildCount
            mutation()
            expectRows(ids)
            #expect(model.sidebarSnapshotBuildCount == count + 1)
        }

        expectRows(["other", "project", "pin", "open"])
        change({ model.openProject(project) }, expecting: ["project", "other", "pin", "open"])
        change({ model.pin(pin) }, expecting: ["pin", "project", "other", "open"])
        let count = model.sidebarSnapshotBuildCount
        let tab = try #require(model.newTab(in: openFolder))
        // Cwd alone is never an open-conversation identity.
        expectRows(["pin", "project", "other", "open"])
        #expect(model.sidebarSnapshotBuildCount == count + 1)
        change(
            {
                tab.learnedSessionReference = .init(provider: .codex, sessionID: "open", cwd: openFolder.path)
            }, expecting: ["pin", "project", "other", "open"])
        change(
            {
                tab.learnedSessionReference = .init(provider: .grokBuild, sessionID: "open", cwd: openFolder.path)
            }, expecting: ["open", "pin", "project", "other"])
        change({ model.pin(open) }, expecting: ["open", "pin", "project", "other"])

        let second = try #require(model.newTab(in: otherFolder))
        expectRows(["open", "pin", "project", "other"])
        // Both are open: the older one's pin adds nothing to that category.
        change(
            {
                second.learnedSessionReference = .init(provider: .grokBuild, sessionID: "other", cwd: otherFolder.path)
            }, expecting: ["other", "open", "pin", "project"])
        change({ model.leaveProject() }, expecting: ["other", "open", "pin", "project"])
        change({ tab.learnedSessionReference = nil }, expecting: ["other", "pin", "open", "project"])
        change({ model.unpin(open) }, expecting: ["other", "pin", "project", "open"])
        let beforeEmpty = model.sidebarSnapshotBuildCount
        model.openRecents()
        model.searchText = " \n "
        let empty = model.eventSidebarSnapshot()
        #expect(empty.listKind == .recents)
        #expect(empty.sessions.map(\.id) == ["other", "project", "pin", "open"])
        #expect(model.sidebarSnapshotBuildCount == beforeEmpty + 1)
    }

    @Test func rendersAndEventsReuseOneSnapshotUntilTheInjectedDeadline() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        fixture.settings.showWorktreeSessions = true
        let folder = try fixture.directory("reuse")
        try fixture.writeListedSession(id: "one", cwd: folder.path)
        await fixture.store.reload()
        let clock = SnapshotClock()
        let model = snapshotModel(fixture, clock: clock)
        defer { model.closeAllTabsAndWait() }
        let rows = model.sidebarSnapshot().rowIDs
        #expect(model.sidebarSnapshot().rowIDs == rows)
        #expect(model.eventSidebarSnapshot().rowIDs == rows)
        for _ in 0..<20 {
            _ = model.sidebarSnapshot()
            _ = model.sidebarFilesystemPaths
        }
        #expect(model.sidebarSnapshotBuildCount == 1)
        #expect(model.sidebarFilesystemPathBuildCount == 1)
        clock.advance(0.999)
        _ = model.sidebarSnapshot()
        #expect(model.sidebarSnapshotBuildCount == 1)
        clock.advance(0.001)
        _ = model.eventSidebarSnapshot()
        #expect(model.sidebarSnapshotBuildCount == 2)
        _ = model.sidebarSnapshot()
        #expect(model.sidebarSnapshotBuildCount == 2)
    }

    @Test func everyVisibilityInputRebuildsImmediately() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        fixture.settings.showWorktreeSessions = true
        let folder = try fixture.directory("keys")
        try fixture.writeListedSession(id: "one", cwd: folder.path, summary: "Quartz")
        await fixture.store.reload()
        let model = snapshotModel(fixture, clock: SnapshotClock())
        defer { model.closeAllTabsAndWait() }
        let session = try #require(fixture.store.sessions.first)
        _ = model.sidebarSnapshot()
        func change(_ mutation: () -> Void) {
            let before = model.sidebarSnapshotBuildCount
            mutation()
            expectMatchesModelLists(model.eventSidebarSnapshot(), model)
            _ = model.sidebarSnapshot()
            #expect(model.sidebarSnapshotBuildCount == before + 1)
        }
        change { model.searchText = "Quartz" }
        change { model.searchText = "" }
        change { model.openRecents() }
        change { model.pin(session) }
        change { model.archive(session) }
        change { model.settings.showEmptySessions.toggle() }
        change { model.settings.showSubagentSessions.toggle() }
        change { model.settings.showWorktreeSessions.toggle() }
        change { model.settings.showWorktreeSessions.toggle() }
        change { model.settings.showOtherAppSessions = false }
        change { model.settings.recordSigilConversations([session.id]) }
        change { model.rename(session, to: "Named") }
        change { model.openArchived() }
        let project = try #require(model.sidebarProjects.first)
        change { model.pin(project) }
        let added = try fixture.directory("added-key")
        change { model.addProject(added) }
        try fixture.writeListedSession(id: "two", cwd: folder.path)
        let count = model.sidebarSnapshotBuildCount
        await fixture.store.reload()
        _ = model.sidebarSnapshot()
        #expect(model.sidebarSnapshotBuildCount == count + 1)
    }

    @Test func learnedTabIdentityChangesVisibilityWithoutAnActivityCacheKey() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        fixture.settings.showWorktreeSessions = true
        fixture.settings.showOtherAppSessions = false
        let folder = try fixture.directory("binding")
        try fixture.writeListedSession(id: "one", cwd: folder.path)
        await fixture.store.reload()
        let session = try #require(fixture.store.sessions.first)
        let model = snapshotModel(fixture, clock: SnapshotClock())
        defer { model.closeAllTabsAndWait() }
        model.openRecents()
        let tab = try #require(model.newTab(in: folder))
        #expect(model.sidebarSnapshot().listed.isEmpty)
        let count = model.sidebarSnapshotBuildCount
        tab.learnedSessionReference = .init(provider: .grokBuild, sessionID: session.id, cwd: folder.path)
        #expect(model.eventSidebarSnapshot().listed.map(\.id) == [session.id])
        #expect(model.sidebarSnapshotBuildCount == count + 1)
        tab.noteDisconnected()
        #expect(model.activity(of: session) == .disconnected)
        _ = model.sidebarSnapshot()
        #expect(model.sidebarSnapshotBuildCount == count + 1)
        tab.noteInterrupted()
        #expect(model.activity(of: session) == .interrupted)
        _ = model.sidebarSnapshot()
        #expect(model.sidebarSnapshotBuildCount == count + 1)
        tab.learnedSessionReference = nil
        #expect(model.sidebarSnapshot().listed.isEmpty)
        #expect(model.sidebarSnapshotBuildCount == count + 2)
    }

    @Test func expiryRechecksSymlinkGroupingWithUnchangedSessionCount() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        fixture.settings.showWorktreeSessions = true
        let first = try fixture.directory("first")
        let second = try fixture.directory("second")
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        try fixture.writeListedSession(id: "one", cwd: alias.path)
        await fixture.store.reload()
        let clock = SnapshotClock()
        let model = snapshotModel(fixture, clock: clock)
        defer { model.closeAllTabsAndWait() }
        #expect(model.sidebarSnapshot().projects.first?.id == GrokPaths.canonicalPath(first.path))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        clock.advance(1)
        #expect(model.sidebarSnapshot().projects.first?.id == GrokPaths.canonicalPath(second.path))
        #expect(model.eventSidebarSnapshot().projects.first?.id == GrokPaths.canonicalPath(second.path))
        #expect(model.sidebarSnapshotBuildCount == 2)
    }

    @Test func filesystemEventsInvalidateAQuietObservedSnapshotAndStopWithTheView() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        fixture.settings.showWorktreeSessions = true
        let first = try fixture.directory("quiet-first")
        let second = try fixture.directory("quiet-second")
        let alias = fixture.root.appendingPathComponent("quiet-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        try fixture.writeListedSession(id: "one", cwd: alias.path)
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let task = Task { await model.observeSidebarFilesystem() }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let observed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.sidebarSnapshot()
        } onChange: {
            observed.withLock { $0 = true }
        }
        let idleBuilds = model.sidebarSnapshotBuildCount
        // No one-second full-list timer on an unchanged, visible sidebar.
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(!observed.withLock { $0 })
        #expect(model.sidebarSnapshotBuildCount == idleBuilds)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        let deadline = ContinuousClock.now + .seconds(4)
        while !observed.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(observed.withLock { $0 }, "FSEvents must invalidate without hover or input")
        #expect(model.sidebarSnapshot().projects.first?.id == GrokPaths.canonicalPath(second.path))
        task.cancel()
        await task.value
        let stopped = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.sidebarSnapshot()
        } onChange: {
            stopped.withLock { $0 = true }
        }
        try FileManager.default.removeItem(at: alias)
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(!stopped.withLock { $0 })
    }

    @Test func partiallyUnwatchedPathsKeepQuietFallbackRefresh() async throws {
        let fixture = try ModelFixture()
        defer {
            fixture.store.stop()
            fixture.cleanup()
        }
        fixture.settings.showWorktreeSessions = true
        let folder = try fixture.directory("partial-watch")
        try fixture.writeListedSession(id: "watched", cwd: folder.path)
        // Only a synthetic cwd string: never create or alter a root-level folder.
        try fixture.writeListedSession(id: "unavailable", cwd: "/Sigil1255-Generated-\(UUID().uuidString)")
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let task = Task { await model.observeSidebarFilesystem() }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.sidebarSnapshot()
        } onChange: {
            changed.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !changed.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(changed.withLock { $0 }, "A working root must not disable freshness for an unwatched root")
        task.cancel()
        await task.value
    }

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

private final class SnapshotClock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: TimeInterval(100))
    func now() -> TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

@MainActor
private func snapshotModel(
    _ fixture: ModelFixture, clock: SnapshotClock, notesStore: ConversationNotesStore? = nil
) -> AppModel {
    AppModel(
        settings: fixture.settings, store: fixture.store, trashConversation: { _ in },
        presentError: { _ in },
        panel: RightPanel(
            defaults: fixture.defaults,
            notesStore: notesStore ?? ConversationNotesStore(root: fixture.notesRoot)),
        pairingStore: InMemoryRemotePairingStore(),
        providerInstallations: fixtureProviderInstallations(fixture.executable),
        sidebarClock: { clock.now() })
}

/// Controls publication timing without extra Observation subscriptions or waits
/// inside the main actor. The original filesystem regression stays unchanged.
private final class SnapshotNoteReadGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    private let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { state.withLock { $0 } }
    func release() { semaphore.signal() }
    var reader: ConversationNotesIndex.Reader {
        .init(
            metadata: ConversationNotesIndex.Reader.disk.metadata,
            read: { url, stamp in
                let bytes = ConversationNotesIndex.Reader.disk.read(url, stamp)
                let first = self.state.withLock { entered in
                    if entered { return false }
                    entered = true
                    return true
                }
                if first { _ = self.semaphore.wait(timeout: .now() + 4) }
                return bytes
            })
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
