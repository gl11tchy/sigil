import Foundation
import Testing

@testable import SigilKit

@Test func encodesWorkingDirectoryLikeTheCLI() {
    #expect(GrokPaths.encode(path: "/Users/exec") == "%2FUsers%2Fexec")
}

@Test func encodesAwkwardSegmentLikeTheCLI() {
    #expect(GrokPaths.encode(path: "enc test+dir~a.b_c") == "enc%20test%2Bdir~a.b_c")
}

@Test(arguments: [
    "/Users/exec/My Documents/project",
    "/tmp/plus+plus",
    "/Users/exec/~tilde",
    "/tmp/dot.dot",
    "/tmp/under_score",
    "/tmp/dash-dash",
    "/tmp/café/naïve",
    "/tmp/日本語/プロジェクト",
    "/tmp/double//slash",
    "/tmp/trailing/",
    "/tmp/enc test+dir~a.b_c",
    "/tmp/mix +plus/~tilde/dot.d/_u/-d",
    "/tmp///many////slashes/",
    "/Users/exec/Library/Application Support/App",
    "/",
    "/tmp/emoji-📁",
])
func encodeDecodeRoundTrip(path: String) {
    #expect(GrokPaths.decode(directoryName: GrokPaths.encode(path: path)) == path)
}

@Test func canonicalPathMatchesMacOSRealpathForVar() {
    #expect(GrokPaths.canonicalPath("/var") == "/private/var")
    #expect(
        GrokPaths.sessionDirectory(cwd: "/var", sessionID: "session").path
            == GrokPaths.sessionsRoot
            .appendingPathComponent("%2Fprivate%2Fvar")
            .appendingPathComponent("session").path
    )
}
