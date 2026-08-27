import Foundation
import Testing

@testable import SigilKit

struct ShellLaunchSpecTests {

    @Test
    func theLoginShellIsStartedInteractively() {
        let spec = ShellLaunchSpec(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let command = spec.hostCommand(processEnvironment: ["SHELL": "/bin/zsh"])
        #expect(command.executable.path == "/bin/zsh")
        #expect(command.arguments == ["-il"])
    }

    @Test
    func anUnusableShellFallsBackToZsh() {
        let spec = ShellLaunchSpec(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let command = spec.hostCommand(processEnvironment: ["SHELL": "/nope/not-a-shell"])
        #expect(command.executable.path == "/bin/zsh")
    }

    @Test
    func aScratchShellNeverInheritsATabsBridgeIdentity() {
        let spec = ShellLaunchSpec(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let env = spec.environment(processEnvironment: [
            BridgePaths.tabEnvironmentKey: "tab-1",
            BridgePaths.socketEnvironmentKey: "/tmp/sock",
            "PATH": "/usr/bin",
        ])
        #expect(env[BridgePaths.tabEnvironmentKey] == nil)
        #expect(env[BridgePaths.socketEnvironmentKey] == nil)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["PATH"]?.contains("/usr/bin") == true)
    }
}
