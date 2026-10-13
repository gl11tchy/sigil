import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
@MainActor
struct AddedProjectTests {
    @Test func anUnavailableAddedProjectAndItsPinSurviveScanAndRemount() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let project = try fixture.directory("volume/project")
        let other = try fixture.directory("other")
        try fixture.writeListedSession(id: "seed", cwd: other.path)
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.addProject(other)
        model.addProject(project)
        let row = try #require(model.sidebarProjects.first { $0.cwd == project.path })
        model.pin(row)
        model.openProject(row)
        let savedProjects = fixture.settings.addedProjects
        let savedPins = fixture.settings.pinnedProjects
        let detached = fixture.root.appendingPathComponent("detached-project")

        try FileManager.default.moveItem(at: project, to: detached)
        await fixture.store.reload()
        model.pruneMissingPins()
        #expect(fixture.settings.addedProjects == savedProjects)
        #expect(fixture.settings.pinnedProjects == savedPins)
        #expect(fixture.settings.focusedProjectPath == project.path)
        #expect(model.sidebarProjects.contains { $0.cwd == project.path })
        model.retryProjectAvailability()
        let unavailable = try #require(model.sidebarSnapshot().projects.first { $0.cwd == project.path })
        #expect(!unavailable.isAvailable)
        #expect(model.focusedProject?.isAvailable == false)

        try FileManager.default.moveItem(at: detached, to: project)
        await fixture.store.reload()
        model.pruneMissingPins()
        model.retryProjectAvailability()
        #expect(fixture.settings.addedProjects == savedProjects)
        #expect(fixture.settings.pinnedProjects == savedPins)
        #expect(model.sidebarProjects.contains { $0.cwd == project.path })
        #expect(model.sidebarSnapshot().projects.first { $0.cwd == project.path }?.isAvailable == true)
    }

    @Test func anUnavailableStoredWorktreeStillFoldsIntoItsProject() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let project = try fixture.directory("project")
        let other = try fixture.directory("other")
        try fixture.writeListedSession(id: "seed", cwd: other.path)
        await fixture.store.reload()
        let worktree = SigilWorktree.root
            .appendingPathComponent(GrokPaths.encode(path: project.path))
            .appendingPathComponent("ab12cd34")
        let addedAt = Date(timeIntervalSince1970: 20)
        fixture.settings.addedProjects = [AddedProject(path: worktree.path, addedAt: addedAt)]
        fixture.settings.pinnedProjects = [worktree.path]
        fixture.settings.focusedProjectPath = worktree.path
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        try FileManager.default.moveItem(at: project, to: fixture.root.appendingPathComponent("detached-project"))
        model.pruneMissingPins()
        #expect(fixture.settings.addedProjects == [AddedProject(path: project.path, addedAt: addedAt)])
        #expect(fixture.settings.pinnedProjects == [project.path])
        #expect(fixture.settings.focusedProjectPath == project.path)
        #expect(model.sidebarProjects.contains { $0.cwd == project.path })
    }

    @Test(arguments: [false, true], [false, true])
    func explicitRemovalOrArchiveKeepsFilesAndOtherCopiesProjects(archive: Bool, unavailable: Bool) async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let project = try fixture.directory("project")
        let other = try fixture.directory("other")
        let file = project.appendingPathComponent("keep.txt")
        let bytes = Data("generated project data".utf8)
        try bytes.write(to: file)
        try fixture.writeListedSession(id: "seed", cwd: other.path)
        if archive { try fixture.writeListedSession(id: "archive-target", cwd: project.path) }
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.addProject(other)
        model.addProject(project)
        var row = try #require(model.sidebarProjects.first { $0.cwd == project.path })
        #expect(model.isRemovableOnly(row) == !archive)
        model.pin(row)
        model.pin(try #require(model.sidebarProjects.first { $0.cwd == other.path }))

        var survivingFile = file
        if unavailable {
            let detached = fixture.root.appendingPathComponent("detached-project")
            try FileManager.default.moveItem(at: project, to: detached)
            survivingFile = detached.appendingPathComponent("keep.txt")
            model.pruneMissingPins()
            model.retryProjectAvailability()
            row = try #require(model.sidebarSnapshot().projects.first { $0.cwd == project.path })
            #expect(!row.isAvailable)
        }

        let shared = fixture.root.appendingPathComponent("shared-unavailable")
        let anotherCopy = AppSettings(defaults: fixture.defaults)
        anotherCopy.addedProjects.append(AddedProject(path: shared.path, addedAt: Date()))
        anotherCopy.pinnedProjects.append(shared.path)
        model.archiveOrRemove(row)

        #expect(!fixture.settings.addedProjects.contains { $0.path == project.path })
        #expect(fixture.settings.addedProjects.contains { $0.path == other.path })
        #expect(fixture.settings.addedProjects.contains { $0.path == shared.path })
        #expect(fixture.settings.pinnedProjects == [other.path, shared.path])
        #expect(try Data(contentsOf: survivingFile) == bytes)
        #expect(FileManager.default.fileExists(atPath: other.path))
        if archive {
            let session = try #require(fixture.store.sessions.first { $0.id == "archive-target" })
            #expect(model.isArchived(session))
            #expect(FileManager.default.fileExists(atPath: session.directory.path))
        }
    }

    @Test(arguments: ["missing", "not-directory", "permission-denied"])
    func unavailableFoldersStayVisibleAndRetryObservesRecovery(problem: String) async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let project = try fixture.directory("project")
        let other = try fixture.directory("other")
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: project.path)
        let permissions = try #require(attributes[.posixPermissions])
        defer { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: project.path) }
        try fixture.writeListedSession(id: "seed", cwd: other.path)
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.addProject(project)
        let initial = try #require(model.sidebarSnapshot().projects.first { $0.cwd == project.path })
        #expect(initial.isAvailable)
        model.pin(initial)
        model.openProject(initial)
        let saved = fixture.settings.addedProjects
        let sequence = fixture.store.scanSequence
        let detached = fixture.root.appendingPathComponent("detached-project")
        if problem == "permission-denied" {
            // Only this generated CI fixture changes access; no real folder is touched.
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: project.path)
        } else {
            try fm.moveItem(at: project, to: detached)
            if problem == "not-directory" { try Data("generated stand-in".utf8).write(to: project) }
        }
        model.pruneMissingPins()
        model.retryProjectAvailability()
        let snapshot = model.sidebarSnapshot()
        let unavailable = try #require(snapshot.projects.first { $0.cwd == project.path })
        #expect(!unavailable.isAvailable)
        #expect(snapshot.rowIDs.contains(unavailable.id))
        #expect(snapshot.pinnedProjects.contains { $0.cwd == project.path })
        #expect(model.focusedProject?.isAvailable == false)
        #expect(fixture.settings.addedProjects == saved)
        #expect(fixture.settings.pinnedProjects == [project.path])
        #expect(fixture.store.scanSequence == sequence)  // Retry is a folder check, not a history traversal.

        if problem == "permission-denied" {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: project.path)
        } else {
            if problem == "not-directory" { try fm.removeItem(at: project) }
            try fm.moveItem(at: detached, to: project)
        }
        model.retryProjectAvailability()
        #expect(model.sidebarSnapshot().projects.first { $0.cwd == project.path }?.isAvailable == true)
        #expect(fixture.settings.addedProjects == saved && fixture.settings.pinnedProjects == [project.path])
    }

    @Test func aSavedSymlinkReferenceSurvivesAbsenceAndRetargetingWithoutRemovingOtherData() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let first = try fixture.directory("first")
        let second = try fixture.directory("second")
        let other = try fixture.directory("other")
        let fm = FileManager.default
        let bytes = Data("generated project data".utf8)
        try bytes.write(to: first.appendingPathComponent("keep.txt"))
        try bytes.write(to: second.appendingPathComponent("keep.txt"))
        let alias = fixture.root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: first)
        try fixture.writeListedSession(id: "seed", cwd: other.path)
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.addProject(second)
        model.addProject(other)
        model.addProject(alias)
        let row = try #require(model.sidebarProjects.first { $0.cwd == alias.path })
        #expect(row.id == GrokPaths.canonicalPath(first.path))
        model.pin(row)
        model.pin(try #require(model.sidebarProjects.first { $0.cwd == other.path }))
        model.pin(try #require(model.sidebarProjects.first { $0.cwd == second.path }))
        model.openProject(row)
        let saved = fixture.settings.addedProjects
        let pins = fixture.settings.pinnedProjects
        let detached = fixture.root.appendingPathComponent("detached-first")
        try fm.moveItem(at: first, to: detached)
        model.pruneMissingPins()
        model.retryProjectAvailability()
        #expect(model.sidebarSnapshot().projects.first { $0.cwd == alias.path }?.isAvailable == false)
        #expect(fixture.settings.addedProjects == saved && fixture.settings.pinnedProjects == pins)

        try fm.removeItem(at: alias)  // This is the generated symlink, never either target.
        try fm.createSymbolicLink(at: alias, withDestinationURL: second)
        model.retryProjectAvailability()
        model.pruneMissingPins()
        let restored = try #require(model.sidebarSnapshot().projects.first { $0.cwd == alias.path })
        #expect(restored.isAvailable && restored.id == GrokPaths.canonicalPath(second.path))
        #expect(fixture.settings.addedProjects == saved && fixture.settings.pinnedProjects == pins)
        let converged = model.sidebarSnapshot()
        #expect(converged.pinnedProjects.count == 2)
        #expect(Set(converged.pinnedProjects.map(\.id)).count == 2)

        try fm.moveItem(at: detached, to: first)
        try fm.removeItem(at: alias)
        try fm.createSymbolicLink(at: alias, withDestinationURL: first)
        model.retryProjectAvailability()
        model.pruneMissingPins()
        let separated = model.sidebarSnapshot()
        #expect(separated.pinnedProjects.count == 3)
        #expect(fixture.settings.addedProjects == saved && fixture.settings.pinnedProjects == pins)
        let original = try #require(separated.projects.first { $0.cwd == alias.path })
        model.removeProject(original)
        #expect(fixture.settings.addedProjects.map(\.path) == [other.path, second.path])
        #expect(fixture.settings.pinnedProjects == [second.path, other.path])
        #expect(try Data(contentsOf: first.appendingPathComponent("keep.txt")) == bytes)
        #expect(try Data(contentsOf: second.appendingPathComponent("keep.txt")) == bytes)
        #expect(try fm.destinationOfSymbolicLink(atPath: alias.path) == first.path)
    }

    @Test func filteredAndFocusedProjectsKeepAvailabilityWithoutChangingHistoryDates() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let project = try fixture.directory("project")
        try fixture.writeListedSession(id: "seed", cwd: project.path, summary: "needle")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()
        let session = try #require(fixture.store.sessions.first)
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.addProject(project)
        model.openProject(try #require(model.sidebarProjects.first))
        try FileManager.default.moveItem(at: project, to: fixture.root.appendingPathComponent("detached-project"))
        model.pruneMissingPins()
        model.searchText = "needle"
        model.retryProjectAvailability()
        let searched = try #require(model.sidebarSnapshot().projects.first)
        #expect(!searched.isAvailable && searched.updatedAt == session.updatedAt)
        #expect(model.focusedProject?.isAvailable == false)

        model.searchText = ""
        model.archive(session)
        model.openArchived()
        model.retryProjectAvailability()
        let archived = try #require(model.sidebarSnapshot().projects.first)
        #expect(!archived.isAvailable && archived.updatedAt == session.updatedAt)
        #expect(fixture.settings.addedProjects.map(\.path) == [project.path])
    }
}
