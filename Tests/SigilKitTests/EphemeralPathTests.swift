import Foundation
import Testing

@testable import SigilKit

struct EphemeralPathTests {

    @Test(arguments: [
        "/tmp",
        "/tmp/",
        "/tmp/worktree",
        "/private/tmp",
        "/private/tmp/claude-xxx",
        "/private/var/folders",
        "/private/var/folders/zz/T/scratch",
        "/Users/someone/src/.claude/worktrees/chunk",
        "/Users/someone/src/.claude/worktrees",
        "/Users/someone/.claude/projects/encoded/wt-foo",
        "/Users/someone/.claude/scratch/ra-esc",
        "/Users/someone/.claude/scratchpads/qg",
        "/Users/someone/.claude/tmp/quick-grok-x",
        "/Users/someone/src/.worktrees/qg-foo",
        "/Users/someone/.t3/worktrees/foo",
        "/Users/someone/.codex/worktrees/foo",
        "/Users/someone/.cache/quick-grok/pa-button",
        "/Users/someone/src/scratchpad/wt-a",
        "/Users/someone/src/scratchpads/wt-a",
        "/Users/someone/.bb/worktrees/env_abc",
        "/Users/someone/.bb/worktrees",
        "/Users/someone/.bb/plugins/environment-git-worktree/sigil",
        "/Users/someone/.bb/thread-storage/thr_iimp24a4nc",
        "/Users/someone/.bb/personal-workspaces/thr_abc",
        "/Users/someone/.bb/plugins/environment-personal-workspace/host-data/workspaces/thr_abc",
        "/Users/someone/.claude/skills/write-swift/.claude/worktrees/agent-1",
        "/Users/someone/.bb/repos/app/.bb/plugins/environment-git-worktree/app",
    ])
    func treatsScratchLocationsAsEphemeral(path: String) {
        #expect(isEphemeral(path: path))
    }

    @Test(arguments: [
        "/Users/someone/src",
        "/Users/someone/tmp",
        "/usr/local/bin",
        "/Applications",
        "/tmpish",
        "/private/var/tmp",
        "/",
        "/Users/someone/Documents/sigil",
        "/Users/someone/.claude/skills/quick-grok/scripts",
        "/Users/someone/.claude",
        "/Users/someone/.cache/other",
        "/Users/someone/Documents/scratchpad-notes",
        "/Users/someone/.bb",
        "/Users/someone/.bb/plugins",
        "/Users/someone/.bb/plugins/other-plugin",
        "/Users/someone/src/environment-git-worktree",
        "/Users/someone/.sigil",
        "/Users/someone/.sigil/worktrees/%2FUsers%2Fsomeone%2Fsigil/017231be",
        "/Users/someone/src/thread-storage",
    ])
    func treatsRealLocationsAsPersistent(path: String) {
        #expect(!isEphemeral(path: path))
    }

    @Test func treatsSystemTemporaryDirectoryAsEphemeral() {
        let tmp = FileManager.default.temporaryDirectory
        #expect(isEphemeral(path: tmp.path))
        #expect(isEphemeral(path: tmp.appendingPathComponent("scratch").path))
    }

    @Test func treatsSymlinkToScratchLocationAsEphemeral() throws {
        let fm = FileManager.default
        let target = fm.temporaryDirectory.appendingPathComponent("sigil-wt-\(UUID().uuidString)")
        let alias = fm.homeDirectoryForCurrentUser.appendingPathComponent(
            "sigil-ephemeral-test-\(UUID().uuidString)")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: target)
        defer {
            try? fm.removeItem(at: alias)
            try? fm.removeItem(at: target)
        }

        #expect(!isEphemeral(path: alias.deletingLastPathComponent().path))
        #expect(isEphemeral(path: alias.path))
    }

    @Test func retargetedSymlinkIsReclassified() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("sigil-wt-\(UUID().uuidString)")
        let persistent = try #require(
            fm.urls(for: .applicationDirectory, in: .systemDomainMask).first)
        let alias = fm.homeDirectoryForCurrentUser.appendingPathComponent(
            "sigil-ephemeral-retarget-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: scratch)
        defer {
            try? fm.removeItem(at: alias)
            try? fm.removeItem(at: scratch)
        }

        #expect(isEphemeral(path: alias.path))
        try fm.removeItem(at: alias)
        try fm.createSymbolicLink(at: alias, withDestinationURL: persistent)
        #expect(!isEphemeral(path: alias.path))
    }

    @Test func treatsAnyToolsGitWorktreeAsEphemeral() throws {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(
            "sigil-ephemeral-git-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let repo = base.appendingPathComponent("app")
        let worktree = base.appendingPathComponent("repos/app/feature")
        let nested = worktree.appendingPathComponent("vendor/lib")
        let submodule = repo.appendingPathComponent("vendor/lib")
        let separate = base.appendingPathComponent("separate")
        try makeWorktree(worktree, of: repo, named: "feature")
        try fm.createDirectory(at: worktree.appendingPathComponent("web"), withIntermediateDirectories: true)
        try gitFile(in: nested, pointingTo: repo.appendingPathComponent(".git/worktrees/feature/modules/lib"))
        try gitFile(in: submodule, pointingTo: repo.appendingPathComponent(".git/modules/lib"))
        // `git init --separate-git-dir` into a folder that happens to be named `worktrees`.
        let metadata = base.appendingPathComponent("metadata/worktrees/separate")
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
        try gitFile(in: separate, pointingTo: metadata)

        #expect(isEphemeral(path: worktree.path))
        #expect(isEphemeral(path: worktree.appendingPathComponent("web").path))
        #expect(isEphemeral(path: nested.path))
        #expect(!isEphemeral(path: repo.path))
        #expect(!isEphemeral(path: submodule.path))
        #expect(!isEphemeral(path: separate.path))
    }

    @Test func reclassifiesAFolderThatBecomesAWorktree() throws {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(
            "sigil-ephemeral-late-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let folder = base.appendingPathComponent("later")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(!isEphemeral(path: folder.path))

        Thread.sleep(forTimeInterval: 0.01)
        try makeWorktree(folder, of: base.appendingPathComponent("app"), named: "later")
        #expect(isEphemeral(path: folder.path))
    }

    private func makeWorktree(_ folder: URL, of repo: URL, named name: String) throws {
        let admin = repo.appendingPathComponent(".git/worktrees/\(name)")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try "../..\n".write(to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try gitFile(in: folder, pointingTo: admin)
    }

    private func gitFile(in folder: URL, pointingTo target: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "gitdir: \(target.path)\n".write(
            to: folder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    }

    @Test func keepsSigilWorktreesWithTheirProject() throws {
        let fm = FileManager.default
        let project = SigilWorktree.root.appendingPathComponent(
            "%2FUsers%2Fsomeone%2Fsigil-ephemeral-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: project) }
        let worktree = project.appendingPathComponent("abcd1234")
        try makeWorktree(worktree, of: project.appendingPathComponent("repo"), named: "abcd1234")

        #expect(!isEphemeral(path: worktree.path))
    }

    @Test func treatsDeletedHomeFolderAsEphemeral() throws {
        let fm = FileManager.default
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent(
            "sigil-ephemeral-gone-\(UUID().uuidString)")
        #expect(isEphemeral(path: folder.path))
        #expect(!isEphemeral(path: "/Volumes/sigil-unmounted-\(UUID().uuidString)/project"))

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        #expect(!isEphemeral(path: folder.path))
    }
}
