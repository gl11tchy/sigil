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
        "/Users/someone/.sigil/worktrees/%2FUsers%2Fsomeone%2Fsigil/017231be",
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
}
