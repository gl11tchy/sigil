import Foundation
import Testing

@testable import SigilKit

struct TerminalLaunchSpecTests {

    private let cwd = URL(fileURLWithPath: "/tmp/grok-build-spec-cwd")

    @Test func newModeArguments() {
        let sessionID = UUID()
        let spec = GrokLaunchSpec(workingDirectory: cwd, mode: .new(sessionID: sessionID))
        #expect(
            spec.arguments() == [
                "--cwd", cwd.path,
                "--session-id", sessionID.uuidString.lowercased(),
            ]
        )
    }

    @Test func resumeModeArguments() {
        let spec = GrokLaunchSpec(workingDirectory: cwd, mode: .resume(sessionID: "abc-123"))
        #expect(spec.arguments() == ["--cwd", cwd.path, "--resume", "abc-123"])
    }

    @Test func continueLatestArguments() {
        let spec = GrokLaunchSpec(workingDirectory: cwd, mode: .continueLatest)
        #expect(spec.arguments() == ["--cwd", cwd.path, "--continue"])
    }

    @Test func optionalFlagsAndExtraArgumentsFollowMode() {
        let spec = GrokLaunchSpec(
            workingDirectory: cwd,
            mode: .continueLatest,
            model: "grok-4",
            reasoningEffort: "high",
            extraArguments: ["--verbose"]
        )
        #expect(
            spec.arguments() == [
                "--cwd", cwd.path,
                "--continue",
                "--model", "grok-4",
                "--reasoning-effort", "high",
                "--verbose",
            ]
        )
    }

    @Test func environmentPutsGrokBinOnPATHOnceAndSetsTERM() {
        let custom = URL(fileURLWithPath: "/opt/custom-grok/bin/grok")
        let spec = GrokLaunchSpec(
            executable: custom, workingDirectory: cwd, mode: .continueLatest)
        let env = spec.environment()
        let grokBin = GrokPaths.home.appendingPathComponent("bin").path
        let pathEntries = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(pathEntries.filter { $0 == grokBin }.count == 1)
        #expect(pathEntries.filter { $0 == custom.deletingLastPathComponent().path }.count == 1)
        #expect(Set(pathEntries).count == pathEntries.count)
        #expect(env["TERM"] == "xterm-256color")
    }

    @Test func hostCommandUsesLoginShellAndExecsExactCLIArguments() {
        let executable = URL(fileURLWithPath: "/opt/grok with spaces/grok")
        let spec = GrokLaunchSpec(
            executable: executable,
            workingDirectory: cwd,
            mode: .resume(sessionID: "abc")
        )

        let command = spec.hostCommand(processEnvironment: ["SHELL": "/bin/zsh"])
        #expect(command.executable.path == "/bin/zsh")
        #expect(command.arguments.prefix(3) == ["-lic", "exec \"$@\"", "sigil-grok"])
        #expect(command.arguments.dropFirst(3).first == executable.path)
        #expect(command.arguments.suffix(4) == ["--cwd", cwd.path, "--resume", "abc"])
    }

    struct BridgeEnvCase {
        let tabID: String?
        let socketPath: String?
        let expectPresent: Bool
    }

    @Test(arguments: [
        BridgeEnvCase(tabID: "tab-1", socketPath: "/tmp/sigil.sock", expectPresent: true),
        BridgeEnvCase(tabID: "tab-1", socketPath: nil, expectPresent: false),
        BridgeEnvCase(tabID: nil, socketPath: "/tmp/sigil.sock", expectPresent: false),
        BridgeEnvCase(tabID: nil, socketPath: nil, expectPresent: false),
    ])
    func bridgeEnvironmentKeysFollowBothOrNeither(c: BridgeEnvCase) {
        let spec = GrokLaunchSpec(
            workingDirectory: cwd,
            mode: .continueLatest,
            bridgeTabID: c.tabID,
            bridgeSocketPath: c.socketPath
        )
        let env = spec.environment()
        if c.expectPresent {
            #expect(env[BridgePaths.tabEnvironmentKey] == c.tabID)
            #expect(env[BridgePaths.socketEnvironmentKey] == c.socketPath)
        } else {
            #expect(env[BridgePaths.tabEnvironmentKey] == nil)
            #expect(env[BridgePaths.socketEnvironmentKey] == nil)
        }
        #expect(spec.arguments() == ["--cwd", cwd.path, "--continue"])
    }

    /// The window and the CLI inside it have to agree on one theme.
    @Test func themeNameReachesTheCLIAsAnEnvironmentVariable() {
        let themed = GrokLaunchSpec(
            workingDirectory: cwd,
            mode: .continueLatest,
            themeName: TerminalTheme.sigilNeon.grokThemeName
        )
        #expect(themed.environment()["GROK_THEME"] == "sigil-neon")

        let host = GrokLaunchSpec(
            workingDirectory: cwd,
            mode: .continueLatest,
            themeName: TerminalTheme.githubDark.grokThemeName,
            themeVariables: TerminalTheme.githubDark.grokThemeEnvironment
        )
        #expect(host.environment()["GROK_THEME"] == "sigil-host")
        #expect(host.environment()["GROK_THEME_BG"] == "0D1117")
        #expect(host.environment()["GROK_THEME_ACCENT"] == "58A6FF")

        let stale = ["GROK_THEME_BG": "140E0C", "GROK_THEME_ACCENT": "E8934A"]
        let neon = GrokLaunchSpec(
            workingDirectory: cwd,
            mode: .continueLatest,
            themeName: TerminalTheme.sigilNeon.grokThemeName
        )
        let neonEnv = neon.environment(processEnvironment: stale)
        #expect(neonEnv["GROK_THEME"] == "sigil-neon")
        #expect(neonEnv["GROK_THEME_BG"] == nil)
        #expect(neonEnv["GROK_THEME_ACCENT"] == nil)

        let plain = GrokLaunchSpec(workingDirectory: cwd, mode: .continueLatest)
        #expect(plain.environment()["GROK_THEME"] == nil)
    }

    @Test func inheritedBridgeKeysAreDroppedWhenSpecOmitsThem() {
        let tabKey = BridgePaths.tabEnvironmentKey
        let socketKey = BridgePaths.socketEnvironmentKey
        let previousTab = getenv(tabKey).map { String(cString: $0) }
        let previousSocket = getenv(socketKey).map { String(cString: $0) }
        setenv(tabKey, "stale-tab", 1)
        setenv(socketKey, "/tmp/stale.sock", 1)
        defer {
            if let previousTab {
                setenv(tabKey, previousTab, 1)
            } else {
                unsetenv(tabKey)
            }
            if let previousSocket {
                setenv(socketKey, previousSocket, 1)
            } else {
                unsetenv(socketKey)
            }
        }

        #expect(ProcessInfo.processInfo.environment[tabKey] == "stale-tab")
        let spec = GrokLaunchSpec(workingDirectory: cwd, mode: .continueLatest)
        let env = spec.environment()
        #expect(env[tabKey] == nil)
        #expect(env[socketKey] == nil)
        #expect(spec.arguments() == ["--cwd", cwd.path, "--continue"])
    }

    @Test(arguments: [
        ("", "/tmp/sigil.sock"),
        ("tab-1", ""),
        ("  ", "/tmp/sigil.sock"),
        ("tab-1", " \n\t "),
        ("\n", ""),
        ("  tab-1  ", "   "),
    ])
    func blankBridgeValuesCountAsMissing(tabID: String, socketPath: String) {
        let spec = GrokLaunchSpec(
            workingDirectory: cwd,
            mode: .continueLatest,
            bridgeTabID: tabID,
            bridgeSocketPath: socketPath
        )
        let env = spec.environment()
        #expect(env[BridgePaths.tabEnvironmentKey] == nil)
        #expect(env[BridgePaths.socketEnvironmentKey] == nil)
        #expect(spec.arguments() == ["--cwd", cwd.path, "--continue"])
    }
}
