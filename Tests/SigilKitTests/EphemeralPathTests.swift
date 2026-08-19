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
