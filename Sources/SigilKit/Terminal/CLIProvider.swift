import Foundation

public enum CLIProvider: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case devin
    case cursor
    case grokBuild

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .devin: "Devin"
        case .cursor: "Cursor"
        case .grokBuild: "Grok Build"
        }
    }

    public var command: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .devin: "devin"
        // `agent` is also installed by Grok. Use Cursor's distinct entry point.
        case .cursor: "cursor-agent"
        case .grokBuild: "grok"
        }
    }

    /// GUI launches can inherit only the system PATH. Keep the login shell's
    /// choices first, then include the providers' standard installation folders.
    static var fallbackPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.bun/bin", "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        .joined(separator: ":")
    }
}
