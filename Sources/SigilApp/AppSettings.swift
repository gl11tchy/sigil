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
        static let showOtherAppSessions = "sidebar.showOtherAppSessions"
        static let sigilConversations = "session.sigilConversations"
        static let sigilConversationsSeeded = "session.sigilConversationsSeeded"
        static let sigilConversationsSeeded2 = "session.sigilConversationsSeeded2"
        static let sigilConversationPrefix = "session.sigilConversation."
        static let focusedProjectPath = "sidebar.focusedProjectPath"
        static let pinnedConversations = "sidebar.pinnedConversations"
        static let pinnedProjects = "sidebar.pinnedProjects"
        static let addedProjects = "sidebar.addedProjects"
        static let archivedConversations = "sidebar.archivedConversations"
        static let conversationNames = "sidebar.conversationNames"
        static let tabColors = "tabs.colors"
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
    @ObservationIgnored private let persistSigilOwnership: (UserDefaults, [String: Any]) -> Bool
    @ObservationIgnored private var sigilPersistencePending = false

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
    private(set) var grokExecutableSelection: GrokExecutableSelection {
        didSet {
            switch grokExecutableSelection {
            case .installed:
                defaults.removeObject(forKey: Key.executablePath)
                defaults.set(false, forKey: Key.executablePathChosen)
            case .custom(let path):
                defaults.set(path, forKey: Key.executablePath)
                defaults.set(true, forKey: Key.executablePathChosen)
            }
        }
    }

    var usesInstalledGrok: Bool { grokExecutableSelection == .installed }

    /// For automatic selection this is the installer fallback, not a discovery
    /// result. AppModel uses the current checked host path for Grok operations.
    var executablePath: String {
        get {
            if case .custom(let path) = grokExecutableSelection { return path }
            return GrokPaths.defaultExecutable.path
        }
        set { grokExecutableSelection = .custom(newValue) }
    }

    func useInstalledGrok() { grokExecutableSelection = .installed }
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
    /// The sidebar lists chats started or given ownership data in Sigil.
    /// Unclaimed chats in the shared CLI history stay hidden unless turned on.
    var showOtherAppSessions: Bool {
        didSet { defaults.set(showOtherAppSessions, forKey: Key.showOtherAppSessions) }
    }
    /// Sidebar ids of chats Sigil started or the user pinned, named, archived or colored.
    private(set) var sigilConversations: [String] {
        didSet { sigilConversationIDs = Set(sigilConversations) }
    }
    /// `sigilConversations` as a set, so a sidebar pass is one lookup per chat.
    @ObservationIgnored private(set) var sigilConversationIDs: Set<String> = []
    /// True once chats started before `sigilConversations` existed were added.
    var sigilConversationsSeeded: Bool {
        didSet { defaults.set(sigilConversationsSeeded, forKey: Key.sigilConversationsSeeded) }
    }
    /// The ownership union was persisted successfully. Later arrivals still reconcile.
    private(set) var sigilConversationsSeeded2: Bool
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
    /// User-chosen tab colors. Identity is session id + working directory.
    var tabColors: [TabColorRecord] {
        didSet {
            if let data = try? JSONEncoder().encode(tabColors) {
                defaults.set(data, forKey: Key.tabColors)
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

    /// The CLI focused first in New Session and its optional configuration sheet.
    var defaultProvider: CLIProvider {
        didSet {
            guard !isChoosingInitialProvider else { return }
            hasExplicitDefaultProvider = true
            finishInitialProviderSelection()
            defaults.set(defaultProvider.rawValue, forKey: Key.defaultProvider)
        }
    }
    private(set) var hasExplicitDefaultProvider: Bool
    private var hasFinishedInitialProviderSelection = false
    private var isChoosingInitialProvider = false
    var needsInitialProviderSelection: Bool {
        !hasExplicitDefaultProvider && !hasFinishedInitialProviderSelection
    }

    /// Interaction freezes the initial choice even if an inventory is pending.
    /// Only an explicit saved default is persisted across app launches.
    func finishInitialProviderSelection() {
        hasFinishedInitialProviderSelection = true
    }

    func chooseInitialInstalledProvider(_ installations: [CLIProvider: ProviderInstallation]) {
        guard needsInitialProviderSelection else { return }
        // Decide once from a completed inventory, never from probe arrival order.
        finishInitialProviderSelection()
        guard let provider = CLIProvider.allCases.first(where: { installations[$0]?.isAvailable == true }) else {
            return
        }
        isChoosingInitialProvider = true
        defaultProvider = provider
        isChoosingInitialProvider = false
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

    init(
        defaults: UserDefaults = .standard,
        persistSigilOwnership: ((UserDefaults, [String: Any]) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.persistSigilOwnership =
            persistSigilOwnership ?? { defaults, values in
                for (key, value) in values { defaults.set(value, forKey: key) }
                // Only ownership commits need a checked persistence barrier; ordinary
                // preferences keep UserDefaults' normal asynchronous persistence.
                return defaults.synchronize()
            }
        fontSize =
            defaults.object(forKey: Key.fontSize) == nil
            ? 13
            : Self.normalizedFontSize(CGFloat(defaults.double(forKey: Key.fontSize)))
        themeName = defaults.string(forKey: Key.themeName) ?? TerminalTheme.sigilDark.name
        grokExecutableSelection = .restoring(
            storedPath: defaults.string(forKey: Key.executablePath),
            wasChosen: defaults.bool(forKey: Key.executablePathChosen),
            installer: GrokPaths.installerExecutable, themed: GrokPaths.themedExecutable)
        showEmptySessions = defaults.bool(forKey: Key.showEmptySessions)
        showWorktreeSessions = defaults.bool(forKey: Key.showWorktreeSessions)
        showSubagentSessions = defaults.bool(forKey: Key.showSubagentSessions)
        showOtherAppSessions = defaults.bool(forKey: Key.showOtherAppSessions)
        let started =
            defaults.data(forKey: Key.sigilConversations)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        sigilConversations = started
        sigilConversationIDs = Set(started)
        sigilConversationsSeeded = defaults.bool(forKey: Key.sigilConversationsSeeded)
        sigilConversationsSeeded2 = defaults.bool(forKey: Key.sigilConversationsSeeded2)
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
        if let data = defaults.data(forKey: Key.tabColors),
            let decoded = TabColors.decode(data)
        {
            tabColors = decoded
        } else {
            tabColors = []
        }
        isTabMessagingEnabled = defaults.bool(forKey: Key.isTabMessagingEnabled)
        defaultDirectory =
            defaults.string(forKey: Key.defaultDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        model = defaults.string(forKey: Key.model) ?? ""
        let storedEffort = defaults.string(forKey: Key.effort) ?? ""
        effort = Self.effortOptions.contains(storedEffort) ? storedEffort : ""
        let storedProvider = defaults.string(forKey: Key.defaultProvider).flatMap(CLIProvider.init(rawValue:))
        hasExplicitDefaultProvider = storedProvider != nil
        defaultProvider = storedProvider ?? .grokBuild
        startsInWorktree = defaults.object(forKey: Key.startsInWorktree) as? Bool ?? true
        kimiSignIn =
            defaults.string(forKey: Key.kimiSignIn).flatMap(KimiSignIn.init(rawValue:)) ?? .kimiAccount
        kimiModel = defaults.string(forKey: Key.kimiModel) ?? KimiCode.defaultModel
        seedSigilConversationOwnership()
    }

    /// Re-reads the pin, archive, name and color lists, which another running
    /// copy of the app may have changed since launch. Call it before a change,
    /// so the write keeps that copy's edits instead of replacing them.
    func reloadSharedLists() {
        // Capture opaque ownership IDs before display decoders skip unknown values.
        seedSigilConversationOwnership()
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
        // An unknown color is skipped. Garbage leaves the list already in memory.
        if let data = defaults.data(forKey: Key.tabColors),
            let colors = TabColors.decode(data),
            colors != tabColors
        {
            tabColors = colors
        }
    }

    func isSigilConversation(_ sidebarID: String) -> Bool {
        sigilConversationIDs.contains(sidebarID)
    }

    /// Independent, never-pruned addition records preserve simultaneous writes
    /// without making bulk actions write one preference per conversation.
    @discardableResult
    func recordSigilConversations(_ sidebarIDs: [String], confirmPersistence: Bool = false) -> Bool {
        var merged = sigilConversations
        var seen = Set(merged)
        func append(_ ids: [String]) {
            for id in ids where seen.insert(id).inserted { merged.append(id) }
        }
        let (recorded, recordsReadable) = storedSigilConversationRecords()
        let savedData = defaults.data(forKey: Key.sigilConversations)
        let saved: [String]
        if defaults.object(forKey: Key.sigilConversations) == nil {
            saved = []
        } else if let savedData, let decoded = try? JSONDecoder().decode([String].self, from: savedData) {
            saved = decoded
        } else {
            // Malformed preferences are not permission to overwrite unseen IDs.
            append(recorded + sidebarIDs)
            if merged != sigilConversations { sigilConversations = merged }
            sigilPersistencePending = true
            return false
        }
        append(saved + recorded + sidebarIDs)
        if merged != sigilConversations { sigilConversations = merged }
        guard recordsReadable, let data = try? JSONEncoder().encode(merged) else {
            sigilPersistencePending = true
            return false
        }
        var writes: [String: Any] = [:]
        let registered = Set(recorded)
        let additions = merged.filter { !registered.contains($0) }
        if !additions.isEmpty {
            // This UUID identifies an immutable preference record, never a chat.
            let key = Key.sigilConversationPrefix + UUID().uuidString
            guard defaults.object(forKey: key) == nil, let added = try? JSONEncoder().encode(additions) else {
                sigilPersistencePending = true
                return false
            }
            writes[key] = added
        }
        if savedData == nil || Set(saved) != seen { writes[Key.sigilConversations] = data }
        guard !writes.isEmpty || sigilPersistencePending || confirmPersistence else { return true }
        let persisted = persistSigilOwnership(defaults, writes)
        let persistedRecords = storedSigilConversationRecords()
        guard persisted, persistedRecords.readable,
            let readback = defaults.data(forKey: Key.sigilConversations)
                .flatMap({ try? JSONDecoder().decode([String].self, from: $0) }),
            seen.isSubset(of: Set(readback)),
            seen.isSubset(of: Set(persistedRecords.ids))
        else {
            sigilPersistencePending = true
            return false
        }
        sigilPersistencePending = false
        return true
    }

    private func storedSigilConversationRecords() -> (ids: [String], readable: Bool) {
        let records = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(Key.sigilConversationPrefix) }
        var ids: [String] = []
        var readable = true
        for (_, value) in records.sorted(by: { $0.key < $1.key }) {
            if let data = value as? Data, let added = try? JSONDecoder().decode([String].self, from: data) {
                ids += added
            } else {
                readable = false
            }
        }
        return (ids, readable)
    }

    /// Keep both legacy sources readable during the task-ledger migration.
    /// An incomplete source stays pending; its IDs are never a replacement ledger.
    var taskLedgerMigrationSource: (ids: [String], readable: Bool) {
        let records = storedSigilConversationRecords()
        let object = defaults.object(forKey: Key.sigilConversations)
        let decoded = defaults.data(forKey: Key.sigilConversations).flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        }
        return (
            Array(Set(sigilConversations + records.ids + (decoded ?? []))).sorted(),
            records.readable && (object == nil || decoded != nil)
        )
    }

    /// Ownership preferences already contain sidebar IDs, including provider
    /// prefixes. No history lookup, cwd match, provider validation or notes scan.
    /// Reconciliation after completion recovers failed actions and other copies.
    @discardableResult
    func seedSigilConversationOwnership() -> Bool {
        struct OwnedRow: Decodable { let sessionID: String }
        var ids =
            pinnedConversations.map(\.sessionID) + archivedConversations.map(\.sessionID)
            + conversationNames.map(\.sessionID) + tabColors.map(\.sessionID)
        var readable = true
        for key in [Key.pinnedConversations, Key.archivedConversations, Key.conversationNames, Key.tabColors] {
            guard defaults.object(forKey: key) != nil else { continue }
            if let data = defaults.data(forKey: key), let rows = try? JSONDecoder().decode([OwnedRow].self, from: data)
            {
                ids += rows.map(\.sessionID)
            } else {
                readable = false
            }
        }
        let persisted = recordSigilConversations(ids, confirmPersistence: !sigilConversationsSeeded2)
        guard readable, persisted else { return false }
        if !defaults.bool(forKey: Key.sigilConversationsSeeded2) {
            guard persistSigilOwnership(defaults, [Key.sigilConversationsSeeded2: true]),
                defaults.bool(forKey: Key.sigilConversationsSeeded2)
            else {
                defaults.set(false, forKey: Key.sigilConversationsSeeded2)
                return false
            }
        }
        sigilConversationsSeeded2 = true
        return true
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
