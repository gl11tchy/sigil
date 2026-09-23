import Foundation
import Testing

@testable import SigilKit

struct CLIProviderTests {
    @Test(arguments: [CLIProvider.claudeCode, .codex, .devin, .cursor])
    func otherProvidersDoNotReceiveGrokFlagsOrState(provider: CLIProvider) {
        let spec = GrokLaunchSpec(
            workingDirectory: URL(fileURLWithPath: "/tmp/project with spaces"),
            mode: .new(sessionID: UUID()),
            model: "grok-only-model", reasoningEffort: "high",
            themeName: "sigil-host", themeVariables: ["GROK_THEME_BG": "000000"],
            bridgeTabID: "grok-tab", bridgeSocketPath: "/tmp/grok.sock",
            provider: provider
        )
        #expect(spec.arguments().isEmpty)
        #expect(spec.sessionDirectory == nil)
        let env = spec.environment(processEnvironment: [
            "PATH": "/usr/bin:/bin", "GROK_WRAPPER": "inherited",
            "GROK_THEME": "inherited", "GROK_THEME_BG": "FFFFFF",
            BridgePaths.tabEnvironmentKey: "inherited",
            BridgePaths.socketEnvironmentKey: "/tmp/inherited.sock",
        ])
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["GROK_WRAPPER"] == nil)
        #expect(env["GROK_THEME"] == nil)
        #expect(env["GROK_THEME_BG"] == nil)
        #expect(env[BridgePaths.tabEnvironmentKey] == nil)
        #expect(env[BridgePaths.socketEnvironmentKey] == nil)
        let command = spec.hostCommand(processEnvironment: ["SHELL": "/bin/zsh"])
        #expect(command.executable.path == "/bin/zsh")
        #expect(command.arguments.last == provider.command)
    }

    @Test func claudeCodesLocalInstallFolderIsOnTheFallbackPath() {
        // The local installer puts the binary there and adds only a shell
        // alias, which `exec "$@"` does not see.
        let spec = GrokLaunchSpec(
            workingDirectory: URL(fileURLWithPath: "/tmp"), mode: .new(sessionID: UUID()),
            provider: .claudeCode)
        let command = spec.hostCommand(processEnvironment: ["SHELL": "/bin/zsh"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(command.arguments.count > 3)
        #expect(command.arguments.dropFirst(3).first?.split(separator: ":").contains("\(home)/.claude/local") == true)
    }

    @Test func cursorUsesItsUnambiguousCLIName() {
        // Grok also installs an `agent` binary. Never use that ambiguous alias.
        #expect(CLIProvider.cursor.command == "cursor-agent")
    }
}
