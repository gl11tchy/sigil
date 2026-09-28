import Foundation
import Observation
import SigilKit
import SwiftUI

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let fontSize = "terminal.fontSize"
        static let themeName = "terminal.theme"
        static let executablePath = "grok.executablePath"
        static let executablePathChosen = "grok.executablePath.chosen"
        static let showEmptySessions = "sidebar.showEmptySessions"
        static let showWorktreeSessions = "sidebar.showWorktreeSessions"
        static let showSubagentSessions = "sidebar.showSubagentSessions"
        static let focusedProjectPath = "sidebar.focusedProjectPath"
        static let pinnedConversations = "sidebar.pinnedConversations"
        static let pinnedProjects = "sidebar.pinnedProjects"
        static let addedProjects = "sidebar.addedProjects"
        static let archivedConversations = "sidebar.archivedConversations"
        static let conversationNames = "sidebar.conversationNames"
        static let isTabMessagingEnabled = "bridge.enabled"
        static let defaultDirectory = "session.defaultDirectory"
        static let openTabs = "session.openTabs"
        static let model = "session.model"
        static let effort = "session.effort"
        static let optionAsMeta = "terminal.optionAsMetaKey"
        static let defaultProvider = "session.defaultProvider"
        static let startsInWorktree = "session.startsInWorktree"
        static let kimiSignIn = "kimi.signIn"
        static let kimiModel = "kimi.apiKeyModel"
    }

    private let defaults: UserDefaults

    static func normalizedFontSize(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(32, max(8, value)) : 13
    }

    static func normalizedExecutablePath(_ text: String) -> String {
        (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    var fontSize: CGFloat {
        didSet {
            let normalized = Self.normalizedFontSize(fontSize)
            if normalized != fontSize { fontSize = normalized }
            defaults.set(Double(fontSize), forKey: Key.fontSize)
        }
    }
    var themeName: String {
        didSet { defaults.set(themeName, forKey: Key.themeName) }
    }
    var executablePath: String {
        didSet {
            defaults.set(executablePath, forKey: Key.executablePath)
            defaults.set(true, forKey: Key.executablePathChosen)
        }
    }
    /// Sessions the CLI created but never got a real conversation are hidden by default;
    /// hook-triggered one-shot runs otherwise drown the sidebar.
    var showEmptySessions: Bool {
        didSet { defaults.set(showEmptySessions, forKey: Key.showEmptySessions) }
    }
    /// Agent worktrees are hidden by default; implementer checkouts otherwise
    /// drown the project list.
    var showWorktreeSessions: Bool {
        didSet { defaults.set(showWorktreeSessions, forKey: Key.showWorktreeSessions) }
    }
    /// Subagent and workflow children are hidden by default; they otherwise
    /// drown the parent chat in the sidebar. They still run in the background.
    var showSubagentSessions: Bool {
        didSet { defaults.set(showSubagentSessions, forKey: Key.showSubagentSessions) }
    }
    /// Empty means the Projects list, not a drilled-in folder.
    var focusedProjectPath: String {
        didSet { defaults.set(focusedProjectPath, forKey: Key.focusedProjectPath) }
    }
    /// Pin order is newest-pinned first. Identity is session id + working directory.
    var pinnedConversations: [OpenTabsSnapshot.Entry] {
        didSet {
            if let data = try? JSONEncoder().encode(pinnedConversations) {
                defaults.set(data, forKey: Key.pinnedConversations)
            }
        }
    }
    /// Pin order is newest-pinned first. Identity is the working folder path.
    var pinnedProjects: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(pinnedProjects) {
                defaults.set(data, forKey: Key.pinnedProjects)
            }
        }
    }
    /// Folders shown in Projects before they have a Grok chat, newest first.
    var addedProjects: [AddedProject] {
        didSet {
            if let data = try? JSONEncoder().encode(addedProjects) {
                defaults.set(data, forKey: Key.addedProjects)
            }
        }
    }
    /// Archive order is newest-archived first. Same identity as pins.
    var archivedConversations: [OpenTabsSnapshot.Entry] {
        didSet {
            if let data = try? JSONEncoder().encode(archivedConversations) {
                defaults.set(data, forKey: Key.archivedConversations)
            }
        }
    }
    /// User-chosen conversation names. Identity is session id + working directory.
    var conversationNames: [ConversationName] {
        didSet {
            if let data = try? JSONEncoder().encode(conversationNames) {
                defaults.set(data, forKey: Key.conversationNames)
            }
        }
    }
    var isTabMessagingEnabled: Bool {
        didSet { defaults.set(isTabMessagingEnabled, forKey: Key.isTabMessagingEnabled) }
    }
    var defaultDirectory: String {
        didSet { defaults.set(defaultDirectory, forKey: Key.defaultDirectory) }
    }
    var openTabs: OpenTabsSnapshot {
        get {
            guard let data = defaults.data(forKey: Key.openTabs),
                let decoded = OpenTabsSnapshot.decode(data)
            else {
                return OpenTabsSnapshot(tabs: [], selectedSessionID: nil)
            }
            return decoded
        }
        set {
            if let data = newValue.encode() {
                defaults.set(data, forKey: Key.openTabs)
            }
        }
    }
    /// Empty means "let the CLI use its own default".
    var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }
    var effort: String {
        didSet { defaults.set(effort, forKey: Key.effort) }
    }
    /// Off by default, as in Terminal.app, so Option types the layout's characters.
    var optionAsMetaKey: Bool {
        didSet { defaults.set(optionAsMetaKey, forKey: Key.optionAsMeta) }
    }

    /// The CLI the New Session sheet selects first.
    var defaultProvider: CLIProvider {
        didSet { defaults.set(defaultProvider.rawValue, forKey: Key.defaultProvider) }
    }
    /// On by default: a new chat in a git repository gets its own worktree.
    var startsInWorktree: Bool {
        didSet { defaults.set(startsInWorktree, forKey: Key.startsInWorktree) }
    }
    /// The Kimi account by default; the API key itself lives in the Keychain.
    var kimiSignIn: KimiSignIn {
        didSet { defaults.set(kimiSignIn.rawValue, forKey: Key.kimiSignIn) }
    }
    /// The model an API-key sign-in runs, since Kimi Code needs one named.
    var kimiModel: String {
        didSet { defaults.set(kimiModel, forKey: Key.kimiModel) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontSize =
            defaults.object(forKey: Key.fontSize) == nil
            ? 13
            : Self.normalizedFontSize(CGFloat(defaults.double(forKey: Key.fontSize)))
        themeName = defaults.string(forKey: Key.themeName) ?? TerminalTheme.sigilDark.name
        // A stored path is the user's choice and stays — except when it is the
        // installer's own binary and the themed build is now there. That path
        // was never chosen; it is what the default resolved to before the
        // themed build existed, and keeping it would leave the window themed
        // and the program inside it not. A path set in Settings always stays.
        let stored = defaults.string(forKey: Key.executablePath)
        if let stored,
            stored != GrokPaths.installerExecutable.path
                || defaults.bool(forKey: Key.executablePathChosen)
        {
            executablePath = stored
        } else {
            executablePath = GrokPaths.defaultExecutable.path
        }
        showEmptySessions = defaults.bool(forKey: Key.showEmptySessions)
        showWorktreeSessions = defaults.bool(forKey: Key.showWorktreeSessions)
        showSubagentSessions = defaults.bool(forKey: Key.showSubagentSessions)
        optionAsMetaKey = defaults.bool(forKey: Key.optionAsMeta)
        focusedProjectPath = defaults.string(forKey: Key.focusedProjectPath) ?? ""
        if let data = defaults.data(forKey: Key.pinnedConversations),
            let decoded = try? JSONDecoder().decode([OpenTabsSnapshot.Entry].self, from: data)
        {
            pinnedConversations = decoded
        } else {
            pinnedConversations = []
        }
        if let data = defaults.data(forKey: Key.pinnedProjects),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        {
            pinnedProjects = decoded
        } else {
            pinnedProjects = []
        }
        if let data = defaults.data(forKey: Key.addedProjects),
            let decoded = try? JSONDecoder().decode([AddedProject].self, from: data)
        {
            addedProjects = decoded
        } else {
            addedProjects = []
        }
        if let data = defaults.data(forKey: Key.archivedConversations),
            let decoded = try? JSONDecoder().decode([OpenTabsSnapshot.Entry].self, from: data)
        {
            archivedConversations = decoded
        } else {
            archivedConversations = []
        }
        if let data = defaults.data(forKey: Key.conversationNames),
            let decoded = try? JSONDecoder().decode([ConversationName].self, from: data)
        {
            conversationNames = decoded
        } else {
            conversationNames = []
        }
        isTabMessagingEnabled = defaults.bool(forKey: Key.isTabMessagingEnabled)
        defaultDirectory =
            defaults.string(forKey: Key.defaultDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        model = defaults.string(forKey: Key.model) ?? ""
        let storedEffort = defaults.string(forKey: Key.effort) ?? ""
        effort = Self.effortOptions.contains(storedEffort) ? storedEffort : ""
        defaultProvider =
            defaults.string(forKey: Key.defaultProvider).flatMap(CLIProvider.init(rawValue:))
            ?? .grokBuild
        startsInWorktree = defaults.object(forKey: Key.startsInWorktree) as? Bool ?? true
        kimiSignIn =
            defaults.string(forKey: Key.kimiSignIn).flatMap(KimiSignIn.init(rawValue:)) ?? .kimiAccount
        kimiModel = defaults.string(forKey: Key.kimiModel) ?? KimiCode.defaultModel
    }

    /// Re-reads the pin, archive and name lists, which another running copy
    /// of the app may have changed since launch. Call it before a change, so
    /// the write keeps that copy's edits instead of replacing them.
    func reloadSharedLists() {
        func stored<Value: Decodable>(_ key: String) -> [Value] {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Value].self, from: $0) } ?? []
        }
        let pins: [OpenTabsSnapshot.Entry] = stored(Key.pinnedConversations)
        if pins != pinnedConversations { pinnedConversations = pins }
        let projects: [String] = stored(Key.pinnedProjects)
        if projects != pinnedProjects { pinnedProjects = projects }
        let added: [AddedProject] = stored(Key.addedProjects)
        if added != addedProjects { addedProjects = added }
        let archives: [OpenTabsSnapshot.Entry] = stored(Key.archivedConversations)
        if archives != archivedConversations { archivedConversations = archives }
        let names: [ConversationName] = stored(Key.conversationNames)
        if names != conversationNames { conversationNames = names }
    }

    var theme: TerminalTheme {
        TerminalTheme.all.first { $0.name == themeName } ?? .sigilDark
    }

    /// `theme` as saved, for the window a launch shows before the model exists.
    static func storedTheme(defaults: UserDefaults = .standard) -> TerminalTheme {
        let name = defaults.string(forKey: Key.themeName) ?? TerminalTheme.sigilDark.name
        return TerminalTheme.all.first { $0.name == name } ?? .sigilDark
    }

    var executableURL: URL {
        URL(fileURLWithPath: Self.normalizedExecutablePath(executablePath))
    }

    var executableExists: Bool {
        Self.isExecutableFile(at: executableURL)
    }

    static func isExecutableFile(at url: URL) -> Bool {
        let resolved = URL(fileURLWithPath: GrokPaths.canonicalPath(url.path))
        guard FileManager.default.isExecutableFile(atPath: resolved.path),
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        else { return false }
        return values.isRegularFile == true
    }

    static let effortOptions = ["", "low", "medium", "high", "xhigh"]

    nonisolated static func effortLabel(_ value: String) -> String {
        switch value {
        case "": "CLI default"
        case "none": "None"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh", "extra-high": "Extra high"
        case "max": "Max"
        case "ultra": "Ultra"
        default: value
        }
    }
}
