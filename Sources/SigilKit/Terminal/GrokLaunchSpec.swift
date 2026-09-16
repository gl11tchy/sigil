import Foundation

/// How to start one `grok` process inside a terminal tab.
public struct GrokLaunchSpec: Sendable, Hashable {

    public struct HostCommand: Sendable, Equatable {
        public let executable: URL
        public let arguments: [String]
    }

    /// Whether the tab opens a fresh conversation or reattaches to an existing one.
    public enum Mode: Sendable, Hashable {
        /// A new conversation whose UUID the app chooses, so it can watch the session live.
        case new(sessionID: UUID)
        /// An existing conversation, reopened by ID.
        case resume(sessionID: String)
        /// The most recent conversation for the working directory.
        case continueLatest
    }

    public var executable: URL
    public var workingDirectory: URL
    public var mode: Mode
    public var model: String?
    public var reasoningEffort: String?
    /// Anything the user typed into the advanced field, already split into arguments.
    public var extraArguments: [String]
    /// The CLI theme this tab renders in, passed as `GROK_THEME`. It matches the
    /// window's own theme, so the program and its frame read as one surface.
    public var themeName: String?
    /// Extra `GROK_THEME_*` colour keys for `sigil-host`. Empty for named themes.
    public var themeVariables: [String: String]
    /// Identifies this tab to the `sigil-mcp` server grok launches. Both this and
    /// `bridgeSocketPath` must be set for tab messaging to reach the app.
    public var bridgeTabID: String?
    public var bridgeSocketPath: String?

    public init(
        executable: URL = GrokPaths.defaultExecutable,
        workingDirectory: URL,
        mode: Mode,
        model: String? = nil,
        reasoningEffort: String? = nil,
        extraArguments: [String] = [],
        themeName: String? = nil,
        themeVariables: [String: String] = [:],
        bridgeTabID: String? = nil,
        bridgeSocketPath: String? = nil
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.mode = mode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.extraArguments = extraArguments
        self.themeName = themeName
        self.themeVariables = themeVariables
        self.bridgeTabID = bridgeTabID
        self.bridgeSocketPath = bridgeSocketPath
    }

    /// The session directory this launch reads and writes, when the app knows it up front.
    /// `nil` for `.continueLatest`, whose ID is only known once the CLI picks one.
    public var sessionDirectory: URL? {
        switch mode {
        case .new(let sessionID):
            return GrokPaths.sessionDirectory(
                cwd: workingDirectory.path, sessionID: sessionID.uuidString.lowercased())
        case .resume(let sessionID):
            return GrokPaths.sessionDirectory(cwd: workingDirectory.path, sessionID: sessionID)
        case .continueLatest:
            return nil
        }
    }

    /// Command-line arguments for the CLI, in the order `grok` documents them.
    public func arguments() -> [String] {
        var args = ["--cwd", workingDirectory.path]
        switch mode {
        case .new(let sessionID):
            args += ["--session-id", sessionID.uuidString.lowercased()]
        case .resume(let sessionID):
            args += ["--resume", sessionID]
        case .continueLatest:
            args += ["--continue"]
        }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            args += ["--reasoning-effort", reasoningEffort]
        }
        args += extraArguments
        return args
    }

    /// Runs Grok through the user's login shell so a Finder launch receives the
    /// same PATH, credentials, and tool settings as a normal terminal.
    public func hostCommand(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostCommand {
        let fallback = URL(fileURLWithPath: "/bin/zsh")
        let requested = URL(fileURLWithPath: processEnvironment["SHELL"] ?? fallback.path)
        let shell = FileManager.default.isExecutableFile(atPath: requested.path) ? requested : fallback
        switch shell.lastPathComponent {
        case "zsh", "bash", "sh":
            return HostCommand(
                executable: shell,
                arguments: ["-lic", "exec \"$@\"", "sigil-grok", executable.path] + arguments()
            )
        case "fish":
            return HostCommand(
                executable: shell,
                arguments: ["-lic", "exec $argv", executable.path] + arguments()
            )
        default:
            return HostCommand(executable: executable, arguments: arguments())
        }
    }

    /// Environment for the child process: the user's login environment plus the
    /// terminal capabilities SwiftTerm actually provides.
    public func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["GROK_WRAPPER"] = "Sigil.app"
        if let themeName = themeName?.nilIfBlank {
            env["GROK_THEME"] = themeName
        } else {
            env.removeValue(forKey: "GROK_THEME")
        }
        for (key, value) in themeVariables where !value.isEmpty {
            env[key] = value
        }
        // The app bundle inherits a bare or duplicated PATH. Keep one copy of
        // each entry and put both the selected CLI directory and Grok bin first.
        let grokBin = GrokPaths.home.appendingPathComponent("bin").path
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var seen = Set<String>()
        let preferred =
            [executable.deletingLastPathComponent().path, grokBin]
            + existing.split(separator: ":").map(String.init)
        let entries = preferred.filter { !$0.isEmpty && seen.insert($0).inserted }
        if !entries.isEmpty {
            env["PATH"] = entries.joined(separator: ":")
        }
        if let tabID = bridgeTabID?.nilIfBlank,
            let socketPath = bridgeSocketPath?.nilIfBlank
        {
            env[BridgePaths.tabEnvironmentKey] = tabID
            env[BridgePaths.socketEnvironmentKey] = socketPath
        } else {
            env.removeValue(forKey: BridgePaths.tabEnvironmentKey)
            env.removeValue(forKey: BridgePaths.socketEnvironmentKey)
        }
        return env
    }
}
