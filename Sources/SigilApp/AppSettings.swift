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
        static let showEmptySessions = "sidebar.showEmptySessions"
        static let sidebarMode = "sidebar.mode"
        static let focusedProjectPath = "sidebar.focusedProjectPath"
        static let pinnedConversations = "sidebar.pinnedConversations"
        static let isTabMessagingEnabled = "bridge.enabled"
        static let defaultDirectory = "session.defaultDirectory"
        static let openTabs = "session.openTabs"
        static let model = "session.model"
        static let effort = "session.effort"
    }

    private let defaults: UserDefaults

    var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: Key.fontSize) }
    }
    var themeName: String {
        didSet { defaults.set(themeName, forKey: Key.themeName) }
    }
    var executablePath: String {
        didSet { defaults.set(executablePath, forKey: Key.executablePath) }
    }
    /// Sessions the CLI created but never got a real conversation are hidden by default;
    /// hook-triggered one-shot runs otherwise drown the sidebar.
    var showEmptySessions: Bool {
        didSet { defaults.set(showEmptySessions, forKey: Key.showEmptySessions) }
    }
    var sidebarMode: SidebarMode {
        didSet { defaults.set(sidebarMode.rawValue, forKey: Key.sidebarMode) }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedSize = defaults.double(forKey: Key.fontSize)
        fontSize = storedSize > 0 ? CGFloat(storedSize) : 13
        themeName = defaults.string(forKey: Key.themeName) ?? TerminalTheme.grokNight.name
        executablePath =
            defaults.string(forKey: Key.executablePath) ?? GrokPaths.defaultExecutable.path
        showEmptySessions = defaults.bool(forKey: Key.showEmptySessions)
        if let raw = defaults.string(forKey: Key.sidebarMode),
            let mode = SidebarMode(rawValue: raw)
        {
            sidebarMode = mode
        } else {
            sidebarMode = .recents
        }
        focusedProjectPath = defaults.string(forKey: Key.focusedProjectPath) ?? ""
        if let data = defaults.data(forKey: Key.pinnedConversations),
            let decoded = try? JSONDecoder().decode([OpenTabsSnapshot.Entry].self, from: data)
        {
            pinnedConversations = decoded
        } else {
            pinnedConversations = []
        }
        isTabMessagingEnabled = defaults.bool(forKey: Key.isTabMessagingEnabled)
        defaultDirectory =
            defaults.string(forKey: Key.defaultDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        model = defaults.string(forKey: Key.model) ?? ""
        effort = defaults.string(forKey: Key.effort) ?? ""
    }

    var theme: TerminalTheme {
        TerminalTheme.all.first { $0.name == themeName } ?? .grokNight
    }

    var executableURL: URL { URL(fileURLWithPath: executablePath) }

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
    /// Suggestion names for the free-text model field. Empty is not offered.
    static let modelOptions = ["", "grok-4.6", "grok-4.5"]
}
