import Foundation

/// How to start one plain login shell inside a panel terminal.
///
/// This is the scratch terminal: no `grok`, no session ID, no bridge. It exists so
/// the folder the agent is working in is one keystroke away from a normal prompt.
public struct ShellLaunchSpec: Sendable, Hashable {

    public struct HostCommand: Sendable, Equatable {
        public let executable: URL
        public let arguments: [String]
    }

    public var workingDirectory: URL

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    /// The user's login shell, started interactively. Falls back to `/bin/zsh`
    /// when `SHELL` names something that is not executable.
    public func hostCommand(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostCommand {
        let fallback = URL(fileURLWithPath: "/bin/zsh")
        let requested = URL(fileURLWithPath: processEnvironment["SHELL"] ?? fallback.path)
        let shell = FileManager.default.isExecutableFile(atPath: requested.path) ? requested : fallback
        // csh and tcsh accept -l only as the sole flag, and are interactive on a terminal.
        let cshFamily = ["csh", "tcsh"].contains(shell.lastPathComponent)
        return HostCommand(executable: shell, arguments: cshFamily ? ["-l"] : ["-il"])
    }

    /// The same terminal capabilities and PATH repair the session tabs get.
    public func environment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = processEnvironment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["GROK_WRAPPER"] = "Sigil.app"
        // A tab's bridge identity must never leak into a scratch shell.
        env.removeValue(forKey: BridgePaths.tabEnvironmentKey)
        env.removeValue(forKey: BridgePaths.socketEnvironmentKey)
        let grokBin = GrokPaths.home.appendingPathComponent("bin").path
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var seen = Set<String>()
        let preferred = [grokBin] + existing.split(separator: ":").map(String.init)
        let entries = preferred.filter { !$0.isEmpty && seen.insert($0).inserted }
        if !entries.isEmpty {
            env["PATH"] = entries.joined(separator: ":")
        }
        return env
    }
}
