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

/// State for the right-hand utility panel: a scratch shell and a per-folder notes pad.
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
        static let notes = "panel.notes"
    }

    /// Kept in step with the window so a resize cannot squeeze the terminal away.
    static let minWidth: Double = 280
    static let maxWidth: Double = 900

    private let defaults: UserDefaults

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

    /// Notes text, keyed by folder path.
    private var notesByPath: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isVisible = defaults.bool(forKey: Key.isVisible)
        if let raw = defaults.string(forKey: Key.mode), let stored = RightPanelMode(rawValue: raw) {
            mode = stored
        } else {
            mode = .shell
        }
        let storedWidth = defaults.double(forKey: Key.width)
        width = storedWidth > 0 ? min(max(storedWidth, Self.minWidth), Self.maxWidth) : 380
        if let data = defaults.data(forKey: Key.notes),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            notesByPath = decoded
        } else {
            notesByPath = [:]
        }
    }

    // MARK: - Visibility

    /// Opens the panel on `mode`, or closes it when that tool is already showing.
    func toggle(_ requested: RightPanelMode? = nil, in directory: URL) {
        if let requested, isVisible, requested != mode {
            mode = requested
            prepare(in: directory)
            return
        }
        isVisible.toggle()
        if let requested { mode = requested }
        if isVisible { prepare(in: directory) }
    }

    /// Starts whatever the visible tool needs and has not got yet.
    func prepare(in _: URL) {}

    // MARK: - Shell

    /// Creates and starts the scratch shell in `directory`. A shell that is already
    /// running is left alone, even if the selected tab has since moved folder.
    func startShellIfNeeded(in directory: URL, theme: TerminalTheme = .grokNight, fontSize: CGFloat = 13) {
        if let shell, shell.isRunning { return }
        shell?.terminateAndWait()
        let controller = TerminalController(theme: theme, fontSize: fontSize)
        shell = controller
        shellDirectory = directory
        controller.startShell(ShellLaunchSpec(workingDirectory: directory))
    }

    /// Kills the shell and starts a fresh one in `directory`.
    func restartShell(in directory: URL, theme: TerminalTheme = .grokNight, fontSize: CGFloat = 13) {
        shell?.terminateAndWait()
        shell = TerminalController(theme: theme, fontSize: fontSize)
        shellDirectory = directory
        shell?.startShell(ShellLaunchSpec(workingDirectory: directory))
    }

    func closeShellAndWait() {
        shell?.terminateAndWait()
        shell = nil
        shellDirectory = nil
    }

    // MARK: - Notes

    func notes(for directory: URL) -> String {
        notesByPath[directory.path] ?? ""
    }

    func setNotes(_ text: String, for directory: URL) {
        if text.isEmpty {
            notesByPath.removeValue(forKey: directory.path)
        } else {
            notesByPath[directory.path] = text
        }
        if let data = try? JSONEncoder().encode(notesByPath) {
            defaults.set(data, forKey: Key.notes)
        }
    }
}
