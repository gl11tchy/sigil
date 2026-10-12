import Foundation

/// Native conversation identity. A terminal UUID is deliberately not part of it.
public struct ProviderSessionReference: Codable, Hashable, Sendable {
    public let provider: CLIProvider
    public let sessionID: String
    public let cwd: String

    public init(provider: CLIProvider, sessionID: String, cwd: String) {
        self.provider = provider
        self.sessionID = sessionID
        self.cwd = cwd
    }

    /// Keep existing Grok preferences and notes keyed exactly as before.
    public var sidebarID: String { provider == .grokBuild ? sessionID : "\(provider.rawValue):\(sessionID)" }
}

/// The host sends these same definitions to both phone clients. These describe
/// implemented integration, not everything a provider CLI could theoretically do.
public struct ProviderCapabilities: Codable, Equatable, Sendable {
    public let history: Bool
    public let resume: Bool
    public let notes: Bool
    public let rename: Bool
    public let archive: Bool
    public let delete: Bool
    public let export: Bool
    public let bridge: Bool
    public let lifecycle: Bool
    public let structuredApproval: Bool

    public func forSession(hasIdentity: Bool, hasLifecycleJournal: Bool) -> ProviderCapabilities {
        ProviderCapabilities(
            history: history, resume: resume && hasIdentity, notes: notes && hasIdentity,
            rename: rename && hasIdentity, archive: archive && hasIdentity,
            delete: delete && hasIdentity, export: export && hasIdentity,
            bridge: bridge && hasIdentity, lifecycle: lifecycle && hasLifecycleJournal,
            structuredApproval: structuredApproval)
    }
}

/// Presentation facts for a newer CLI. This does not authorize a history format
/// or change any reader, lifecycle or identity validation.
public struct ProviderVersionNotice: Equatable, Identifiable, Sendable {
    public enum Impact: Equatable, Sendable {
        case bestEffort
        case unsupportedHistory
    }

    public let provider: CLIProvider
    public let installedVersion: String
    public let checkedVersion: String
    public let impact: Impact
    public var id: CLIProvider { provider }
    public var consequence: String {
        impact == .unsupportedHistory ? "History format is not supported." : "History and turn state are best effort."
    }
    public var text: String {
        "\(provider.name) \(installedVersion) is newer than Sigil checked (\(checkedVersion)). \(consequence)"
    }
}

extension CLIProvider {
    /// Reader/launch contracts checked locally; this is a reporting baseline,
    /// not a cap on compatible Codex minor releases.
    public var checkedVersion: String? {
        switch self {
        case .claudeCode: "2.1.283"
        case .codex: "0.157.1"
        case .grokBuild: "1.0.40"
        default: nil
        }
    }

    public func versionNotice(for installation: ProviderInstallation?) -> String? {
        versionNoticeDetails(for: installation)?.text
    }

    public func versionNoticeDetails(for installation: ProviderInstallation?) -> ProviderVersionNotice? {
        guard let installation, installation.isAvailable, let output = installation.version,
            let installed = CLIVersion.reported(in: output), let checkedVersion,
            let checked = CLIVersion(checkedVersion), installed > checked
        else { return nil }
        let unsupported =
            (self == .codex || self == .claudeCode) && installed.major != checked.major
        return ProviderVersionNotice(
            provider: self, installedVersion: installed.text, checkedVersion: checkedVersion,
            impact: unsupported ? .unsupportedHistory : .bestEffort)
    }

    public var capabilities: ProviderCapabilities {
        let history = self == .grokBuild || self == .claudeCode || self == .codex
        return ProviderCapabilities(
            history: history, resume: history, notes: history, rename: history, archive: history,
            delete: self == .grokBuild, export: self == .grokBuild, bridge: self == .grokBuild,
            lifecycle: self == .grokBuild || self == .codex, structuredApproval: false)
    }

    /// Native CLI contracts checked against Claude Code 2.1.283 and Codex 0.157.1.
    /// https://code.claude.com/docs/en/cli-reference
    /// https://developers.openai.com/codex/cli/features
    func sessionArguments(for mode: GrokLaunchSpec.Mode) -> [String] {
        switch (self, mode) {
        case (.claudeCode, .new(let id)): ["--session-id", id.uuidString.lowercased()]
        case (.claudeCode, .resume(let id)): ["--resume", id]
        case (.claudeCode, .continueLatest): ["--continue"]
        case (.codex, .resume(let id)): ["resume", id]
        case (.codex, .continueLatest): ["resume", "--last"]
        default: []
        }
    }
}
