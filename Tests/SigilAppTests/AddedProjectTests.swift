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

        try FileManager.default.moveItem(at: detached, to: project)
        await fixture.store.reload()
        model.pruneMissingPins()
        #expect(fixture.settings.addedProjects == savedProjects)
        #expect(fixture.settings.pinnedProjects == savedPins)
        #expect(model.sidebarProjects.contains { $0.cwd == project.path })
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

    @Test(arguments: [false, true])
    func explicitRemovalOrArchiveKeepsFilesAndOtherCopiesProjects(archive: Bool) async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let project = try fixture.directory("project")
        let other = try fixture.directory("other")
        let file = project.appendingPathComponent("keep.txt")
        let bytes = Data("generated project data".utf8)
        try bytes.write(to: file)
        try fixture.writeListedSession(id: "seed", cwd: other.path)
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.addProject(other)
        model.addProject(project)
        let row = try #require(model.sidebarProjects.first { $0.cwd == project.path })
        model.pin(row)
        model.pin(try #require(model.sidebarProjects.first { $0.cwd == other.path }))

        let shared = fixture.root.appendingPathComponent("shared-unavailable")
        let anotherCopy = AppSettings(defaults: fixture.defaults)
        anotherCopy.addedProjects.append(AddedProject(path: shared.path, addedAt: Date()))
        anotherCopy.pinnedProjects.append(shared.path)
        if archive { model.archive(row) } else { model.removeProject(row) }

        #expect(!fixture.settings.addedProjects.contains { $0.path == project.path })
        #expect(fixture.settings.addedProjects.contains { $0.path == other.path })
        #expect(fixture.settings.addedProjects.contains { $0.path == shared.path })
        #expect(fixture.settings.pinnedProjects == [other.path, shared.path])
        #expect(try Data(contentsOf: file) == bytes)
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}
