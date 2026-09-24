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

/// Expected names come from the CLI's own `encode_cwd_dirname`
/// (xai-grok-config/src/paths.rs), run on these exact inputs.
@Test(arguments: [
    ("/Users/me/project", "%2FUsers%2Fme%2Fproject"),
    ("/" + String(repeating: "a", count: 252), "%2F" + String(repeating: "a", count: 252)),
    (
        "/" + String(repeating: "a", count: 253),
        String(repeating: "a", count: 40) + "-50c7dff428fae2f5"
    ),
    ("/Users/太郎/ドキュメント/開発プロジェクト/顧客向け在庫管理システム", "workspace-15372090c54a9144"),
    ("/Users/test/" + String(repeating: "中", count: 30), "workspace-43f12fb9a5ee1037"),
    (
        "/Users/me/" + String(repeating: "a", count: 300),
        String(repeating: "a", count: 40) + "-f7dc6e54ae78d59c"
    ),
    (
        "/Users/me/Café Project/" + String(repeating: "x/", count: 60) + "Résumé Ünïcode-Tool_v2",
        "r-sum-n-code-tool-v2-8adce93e205b3a25"
    ),
    ("/Users/me/" + String(repeating: "c", count: 2100) + "/Leaf Dir", "leaf-dir-12c3a99ff4273f0d"),
])
func sessionFolderNameMatchesTheCLI(cwd: String, expected: String) {
    #expect(GrokPaths.sessionFolderName(forCanonicalPath: cwd) == expected)
}

@Test func sessionDirectoryUsesTheCLIsHashedNameForALongPath() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-paths-\(UUID().uuidString)")
    let cwd = base.appendingPathComponent("太郎/ドキュメント/開発プロジェクト/顧客向け在庫管理システム")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let folder = GrokPaths.sessionDirectory(cwd: cwd.path, sessionID: "session")
        .deletingLastPathComponent()

    #expect(folder.lastPathComponent.utf8.count <= 255)
    #expect(folder.lastPathComponent.hasPrefix("workspace-"))
    #expect(
        folder.lastPathComponent
            == GrokPaths.sessionFolderName(forCanonicalPath: GrokPaths.canonicalPath(cwd.path)))
    // Compare paths: a URL for a folder that exists gains a trailing slash.
    #expect(folder.deletingLastPathComponent().path == GrokPaths.sessionsRoot.path)
}

@Test(arguments: [
    ("", "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
    ("abc", "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"),
    (
        "/Users/me/" + String(repeating: "b", count: 1100),
        "2672786d4a9bd868f52171fede1d9563c5404287770b248560b00d8340bbb25d"
    ),
    (
        "/Users/me/" + String(repeating: "c", count: 2100) + "/Leaf Dir",
        "12c3a99ff4273f0dc8dccc7ee3a64361e07b238d41b1de782f4751a5f81a2c4b"
    ),
    (
        "/Users/me/" + String(repeating: "d", count: 3000),
        "7929950973cfcd721ce22e53b2ee551adbe9ada3af361b84b75d7e5e869f9c28"
    ),
])
func blake3MatchesTheReferenceHash(input: String, expected: String) {
    #expect(BLAKE3.hexDigest(Array(input.utf8)) == expected)
}

/// A throwaway zsh home, so no test reads the developer's own profile.
private func loginShellEnvironment(zshrc: String) throws -> (home: URL, environment: [String: String]) {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-home-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try zshrc.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    let environment = [
        "HOME": home.path, "ZDOTDIR": home.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin",
    ]
    return (home, environment)
}

@Test func loginShellGrokHomeReadsTheProfilesExport() throws {
    // Noise on stdout and a helper that keeps stdout open must not matter.
    let shell = try loginShellEnvironment(
        zshrc: "echo 'welcome back'\n/bin/sleep 5 &!\nexport GROK_HOME=\"$HOME/tools/grok\"\n")
    defer { try? FileManager.default.removeItem(at: shell.home) }
    let start = Date()
    #expect(GrokPaths.loginShellGrokHome(environment: shell.environment) == shell.home.path + "/tools/grok")
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test func loginShellGrokHomeReadsPastAProfileThatFillsThePipe() throws {
    // More output than a pipe buffer holds must not stall the shell.
    let shell = try loginShellEnvironment(
        zshrc: "/usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' x\nexport GROK_HOME=/chatty\n")
    defer { try? FileManager.default.removeItem(at: shell.home) }
    #expect(GrokPaths.loginShellGrokHome(environment: shell.environment) == "/chatty")
}

@Test func loginShellGrokHomeFallsBackToZshForAnUnsupportedShell() throws {
    var shell = try loginShellEnvironment(zshrc: "export GROK_HOME=/from/zsh\n")
    defer { try? FileManager.default.removeItem(at: shell.home) }
    shell.environment["SHELL"] = "/bin/tcsh"
    #expect(GrokPaths.loginShellGrokHome(environment: shell.environment) == "/from/zsh")
}

@Test func loginShellGrokHomeIsNilWhenTheProfileSetsNone() throws {
    let shell = try loginShellEnvironment(zshrc: "echo 'GROK_HOME is not here'\n")
    defer { try? FileManager.default.removeItem(at: shell.home) }
    #expect(GrokPaths.loginShellGrokHome(environment: shell.environment) == nil)
}

@Test func loginShellGrokHomeGivesUpOnASlowProfile() throws {
    let shell = try loginShellEnvironment(zshrc: "/bin/sleep 10\nexport GROK_HOME=/slow\n")
    defer { try? FileManager.default.removeItem(at: shell.home) }
    let start = Date()
    #expect(GrokPaths.loginShellGrokHome(environment: shell.environment, timeout: 0.5) == nil)
    #expect(Date().timeIntervalSince(start) < 2)
}
