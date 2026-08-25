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
    ])
    func treatsRealLocationsAsPersistent(path: String) {
        #expect(!isEphemeral(path: path))
    }

    @Test func treatsSystemTemporaryDirectoryAsEphemeral() {
        let tmp = FileManager.default.temporaryDirectory
        #expect(isEphemeral(path: tmp.path))
        #expect(isEphemeral(path: tmp.appendingPathComponent("scratch").path))
    }
}
