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

    @Test(arguments: ["/bin/tcsh", "/bin/csh"])
    func cshFamilyShellsGetTheOnlyLoginFlagTheyAccept(shell: String) {
        // tcsh and csh accept -l only as the sole flag; `-il` makes them exit.
        let spec = ShellLaunchSpec(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let command = spec.hostCommand(processEnvironment: ["SHELL": shell])
        #expect(command.executable.path == shell)
        #expect(command.arguments == ["-l"])
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
