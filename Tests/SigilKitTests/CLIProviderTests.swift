import Foundation
import Testing

@testable import SigilKit

struct CLIProviderTests {
    @Test(arguments: [CLIProvider.claudeCode, .codex, .devin, .cursor, .kimi])
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

    @Test func kimisInstallFolderIsOnTheFallbackPath() {
        // Kimi Code's installer puts `kimi` in its own bin folder.
        let spec = GrokLaunchSpec(
            workingDirectory: URL(fileURLWithPath: "/tmp"), mode: .new(sessionID: UUID()),
            provider: .kimi)
        let command = spec.hostCommand(processEnvironment: ["SHELL": "/bin/zsh"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(command.arguments.dropFirst(3).first?.split(separator: ":").contains("\(home)/.kimi-code/bin") == true)
        #expect(command.arguments.last == "kimi")
    }

    @Test func onlyTheOtherCLIReceivesItsProviderVariables() {
        let variables = ["KIMI_MODEL_NAME": "kimi-k3", "KIMI_MODEL_API_KEY": "sk-test"]
        let kimi = GrokLaunchSpec(
            workingDirectory: URL(fileURLWithPath: "/tmp"), mode: .new(sessionID: UUID()),
            providerEnvironment: variables, provider: .kimi)
        let env = kimi.environment(processEnvironment: [:])
        #expect(env["SIGIL_PROVIDER_KIMI_MODEL_NAME"] == "kimi-k3")
        #expect(env["SIGIL_PROVIDER_KIMI_MODEL_API_KEY"] == "sk-test")
        let command = kimi.hostCommand(processEnvironment: ["SHELL": "/bin/zsh"])
        #expect(!command.arguments.contains { $0.contains("sk-test") })

        let grok = GrokLaunchSpec(
            workingDirectory: URL(fileURLWithPath: "/tmp"), mode: .new(sessionID: UUID()),
            providerEnvironment: variables)
        #expect(grok.environment(processEnvironment: [:])["KIMI_MODEL_API_KEY"] == nil)
    }

    @Test func providerVariablesWinOverTheLoginShellsOwn() throws {
        // A user's .zshrc may export the same names; the tab must still get Sigil's.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "export KIMI_MODEL_API_KEY=from-zshrc\n".write(
            to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let cli = home.appendingPathComponent("kimi")
        try "#!/bin/sh\nprintf '%s|%s' \"$KIMI_MODEL_API_KEY\" \"${SIGIL_PROVIDER_KIMI_MODEL_API_KEY-unset}\"\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let spec = GrokLaunchSpec(
            executable: cli, workingDirectory: home, mode: .new(sessionID: UUID()),
            providerEnvironment: ["KIMI_MODEL_API_KEY": "sk-sigil", "bad name;": "x"], provider: .kimi)
        let base = ["HOME": home.path, "ZDOTDIR": home.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
        let command = spec.hostCommand(processEnvironment: base)
        #expect(!command.arguments[1].contains("bad name"))
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = spec.environment(processEnvironment: base)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == "sk-sigil|unset")
    }

    @Test func cursorUsesItsUnambiguousCLIName() {
        // Grok also installs an `agent` binary. Never use that ambiguous alias.
        #expect(CLIProvider.cursor.command == "cursor-agent")
    }
}
