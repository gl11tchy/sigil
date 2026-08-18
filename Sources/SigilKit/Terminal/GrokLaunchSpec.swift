import Foundation

/// How to start one `grok` process inside a terminal tab.
public struct GrokLaunchSpec: Sendable, Hashable {

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

    public init(
        executable: URL = GrokPaths.defaultExecutable,
        workingDirectory: URL,
        mode: Mode,
        model: String? = nil,
        reasoningEffort: String? = nil,
        extraArguments: [String] = []
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.mode = mode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.extraArguments = extraArguments
    }

    /// The session directory this launch reads and writes, when the app knows it up front.
    /// `nil` for `.continueLatest`, whose ID is only known once the CLI picks one.
    public var sessionDirectory: URL? {
        switch mode {
        case let .new(sessionID):
            return GrokPaths.sessionDirectory(
                cwd: workingDirectory.path, sessionID: sessionID.uuidString.lowercased())
        case let .resume(sessionID):
            return GrokPaths.sessionDirectory(cwd: workingDirectory.path, sessionID: sessionID)
        case .continueLatest:
            return nil
        }
    }

    /// Command-line arguments for the CLI, in the order `grok` documents them.
    public func arguments() -> [String] {
        var args = ["--cwd", workingDirectory.path]
        switch mode {
        case let .new(sessionID):
            args += ["--session-id", sessionID.uuidString.lowercased()]
        case let .resume(sessionID):
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

    /// Environment for the child process: the user's login environment plus the
    /// terminal capabilities SwiftTerm actually provides.
    public func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["GROK_WRAPPER"] = "Sigil.app"
        // The app bundle inherits a bare PATH; put the CLI's own bin dir on it.
        let grokBin = GrokPaths.home.appendingPathComponent("bin").path
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !existing.split(separator: ":").contains(Substring(grokBin)) {
            env["PATH"] = "\(grokBin):\(existing)"
        }
        return env
    }
}
