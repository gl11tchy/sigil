import Foundation
import Observation
import SigilKit

/// The tool the right panel is showing.
enum RightPanelMode: String, CaseIterable, Identifiable, Sendable {
    case shell
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shell: return "Terminal"
        case .notes: return "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .shell: return "terminal"
        case .notes: return "square.and.pencil"
        }
    }
}

/// State for the right-hand utility panel: a scratch shell and a per-conversation
/// notes pad.
///
/// The panel is deliberately independent of the tabs on the left. It follows the
/// current tab's working folder when it opens, and then stays where the user put it.
@MainActor
@Observable
final class RightPanel {
    private enum Key {
        static let isVisible = "panel.visible"
        static let mode = "panel.mode"
        static let width = "panel.width"
        /// Folder-keyed notes from before notes moved to per-conversation files.
        static let legacyNotes = "panel.notes"
    }

    /// Kept in step with the window so a resize cannot squeeze the terminal away.
    static let minWidth: Double = 280
    static let maxWidth: Double = 900

    private let defaults: UserDefaults
    let notesStore: ConversationNotesStore

    var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Key.isVisible) }
    }
    var mode: RightPanelMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    var width: Double {
        didSet { defaults.set(width, forKey: Key.width) }
    }

    /// The scratch shell, created on first use so a hidden panel costs nothing.
    private(set) var shell: TerminalController?
    private(set) var shellDirectory: URL?
    /// The current shell has exited. The panel offers a restart.
    private(set) var shellExited = false
    /// Replaced shells that are still stopping.
    @ObservationIgnored private var stoppingShells: [ObjectIdentifier: TerminalController] = [:]

    init(defaults: UserDefaults = .standard, notesStore: ConversationNotesStore? = nil) {
        self.defaults = defaults
        self.notesStore = notesStore ?? ConversationNotesStore()
        isVisible = defaults.bool(forKey: Key.isVisible)
        if let raw = defaults.string(forKey: Key.mode), let stored = RightPanelMode(rawValue: raw) {
            mode = stored
        } else {
            mode = .shell
        }
        let storedWidth = defaults.double(forKey: Key.width)
        width = storedWidth > 0 ? min(max(storedWidth, Self.minWidth), Self.maxWidth) : 380
    }

    // MARK: - Visibility

    /// Opens the panel on `mode`, or closes it when that tool is already showing.
    func toggle(_ requested: RightPanelMode? = nil) {
        if let requested, isVisible, requested != mode {
            mode = requested
            return
        }
        isVisible.toggle()
        if let requested { mode = requested }
    }

    // MARK: - Shell

    /// Creates and starts the scratch shell in `directory`. A shell that is already
    /// running is left alone, even if the selected tab has since moved folder.
    func startShellIfNeeded(in directory: URL, theme: TerminalTheme, fontSize: CGFloat) {
        if let shell, shell.isRunning { return }
        shell?.terminateAndWait()
        let controller = TerminalController(theme: theme, fontSize: fontSize)
        shell = controller
        shellDirectory = directory
        watchForExit(controller)
        controller.startShell(ShellLaunchSpec(workingDirectory: directory))
    }

    /// Kills the shell and starts a fresh one in `directory`. The old shell is
    /// stopped in the background: an interactive shell ignores SIGTERM, and
    /// waiting for the SIGKILL would freeze the window.
    func restartShell(in directory: URL, theme: TerminalTheme, fontSize: CGFloat) {
        if let old = shell, old.isRunning {
            // Freeing the controller kills its child at once, so hold it until
            // the stop finishes and a command still gets its SIGTERM cleanup.
            let id = ObjectIdentifier(old)
            stoppingShells[id] = old
            old.onTerminate = { [weak self] _ in self?.stoppingShells[id] = nil }
            old.terminate()
        }
        let controller = TerminalController(theme: theme, fontSize: fontSize)
        shell = controller
        shellDirectory = directory
        watchForExit(controller)
        controller.startShell(ShellLaunchSpec(workingDirectory: directory))
    }

    /// A replaced shell that stops later does not count.
    private func watchForExit(_ controller: TerminalController) {
        shellExited = false
        controller.onTerminate = { [weak self, weak controller] _ in
            guard let self, let controller, self.shell === controller else { return }
            self.shellExited = true
        }
    }

    /// True while a command the user started holds the panel shell.
    var shellHasForegroundJob: Bool { shell?.hasForegroundJob ?? false }

    func closeShellAndWait() {
        shell?.terminateAndWait()
        shell = nil
        shellDirectory = nil
    }

    // MARK: - Notes

    /// The pad for one conversation, keyed the way the app keys conversations:
    /// session ID plus working directory.
    func notes(forSessionID sessionID: String, cwd: String) -> String {
        notesStore.note(for: sessionID, cwd: cwd)
    }

    func setNotes(_ text: String, forSessionID sessionID: String, cwd: String) {
        notesStore.setNote(text, for: sessionID, cwd: cwd)
    }

    func deleteNotes(forSessionID sessionID: String, cwd: String) {
        notesStore.deleteNote(for: sessionID, cwd: cwd)
    }

    /// Removes the flat-layout note file the first notes build wrote. Call only
    /// when no other folder still has a conversation with this session ID.
    func deleteFlatNotes(forSessionID sessionID: String) {
        notesStore.deleteFlatNote(forSessionID: sessionID)
    }

    /// Persist any note text still inside the debounce window. Quit only.
    func flushNotes() {
        notesStore.flushNow()
    }

    /// Folder-keyed notes from the UserDefaults era. `AppModel` moves them onto
    /// the newest conversation in each folder once the store has loaded.
    var legacyFolderNotes: [String: String] {
        guard let data = defaults.data(forKey: Key.legacyNotes),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Writes back the folder notes that could not be migrated yet (their folder
    /// has no conversation), or removes the key when none remain.
    func setLegacyFolderNotes(_ remaining: [String: String]) {
        if remaining.isEmpty {
            defaults.removeObject(forKey: Key.legacyNotes)
        } else if let data = try? JSONEncoder().encode(remaining) {
            defaults.set(data, forKey: Key.legacyNotes)
        }
    }
}
