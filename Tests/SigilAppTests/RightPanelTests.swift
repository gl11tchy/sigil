import AppKit
import Foundation
import SigilKit
import SwiftTerm
import Testing

@testable import SigilApp

@Suite(.serialized)
struct RightPanelTests {

    @MainActor
    private func makePanel() -> (RightPanel, URL) {
        let name = "RightPanelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let notesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
        return (RightPanel(defaults: defaults, notesStore: ConversationNotesStore(root: notesRoot)), notesRoot)
    }

    @Test @MainActor
    func pickingTheShowingToolClosesThePanel() {
        let (panel, notesRoot) = makePanel()
        defer { try? FileManager.default.removeItem(at: notesRoot) }
        panel.toggle(.notes)
        #expect(panel.isVisible)
        #expect(panel.mode == .notes)

        panel.toggle(.shell)
        #expect(panel.isVisible)
        #expect(panel.mode == .shell)

        panel.toggle(.shell)
        #expect(!panel.isVisible)
    }

    @Test func panelModesAreShellAndNotes() {
        #expect(RightPanelMode.allCases.map(\.rawValue) == ["shell", "notes"])
    }

    @Test @MainActor
    func aStoredBrowserModeOpensTheShell() {
        let name = "RightPanelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set("web", forKey: "panel.mode")
        #expect(RightPanel(defaults: defaults).mode == .shell)
    }

    @Test @MainActor
    func notesAreKeptPerConversation() throws {
        let (panel, notesRoot) = makePanel()
        defer { try? FileManager.default.removeItem(at: notesRoot) }
        panel.setNotes("ports: 3000", forSessionID: "session-a", cwd: "/tmp/project-a")
        panel.notesStore.flushNow()
        #expect(panel.notes(forSessionID: "session-a", cwd: "/tmp/project-a") == "ports: 3000")
        #expect(panel.notes(forSessionID: "session-b", cwd: "/tmp/project-a") == "")
        #expect(panel.notes(forSessionID: "session-a", cwd: "/tmp/project-b") == "")

        panel.setNotes("", forSessionID: "session-a", cwd: "/tmp/project-a")
        panel.notesStore.flushNow()
        #expect(panel.notes(forSessionID: "session-a", cwd: "/tmp/project-a") == "")
    }

    @Test @MainActor
    func legacyFolderNotesSurfaceForMigration() throws {
        let (panel, notesRoot) = makePanel()
        defer { try? FileManager.default.removeItem(at: notesRoot) }
        let legacy = ["/tmp/project-a": "ports: 3000"]
        panel.setLegacyFolderNotes(legacy)
        #expect(panel.legacyFolderNotes == legacy)
        panel.setLegacyFolderNotes([:])
        #expect(panel.legacyFolderNotes.isEmpty)
    }

    @Test func windowColumnsDivideTheWidthWithoutOverflowing() {
        for width in [760.0, 882.0, 1000.0, 1280.0, 1440.0] {
            let both = WindowColumns(width: width, sidebarWidth: 272, panelWidth: 380)
            #expect(both.sidebar.isFinite && both.sidebar >= 0)
            #expect(both.panel.isFinite && both.panel >= 0)
            #expect(both.sidebar + both.panel + 2 <= width + 0.001)
            if width >= WindowColumns.minimumWidth(sidebarVisible: true, panelVisible: true) {
                #expect(width - both.sidebar - both.panel - 2 >= 400)
            }
            let sidebarOnly = WindowColumns(width: width, sidebarWidth: 272, panelWidth: nil)
            #expect(sidebarOnly.panel == 0)
            #expect(sidebarOnly.sidebar + 1 <= width + 0.001)
            let panelOnly = WindowColumns(width: width, sidebarWidth: nil, panelWidth: 380)
            #expect(panelOnly.sidebar == 0)
            #expect(panelOnly.panel + 1 <= width + 0.001)
            let bare = WindowColumns(width: width, sidebarWidth: nil, panelWidth: nil)
            #expect(bare.sidebar == 0 && bare.panel == 0)
        }

        let minimum = WindowColumns(
            width: WindowColumns.minimumWidth(sidebarVisible: true, panelVisible: true),
            sidebarWidth: 272,
            panelWidth: 380
        )
        #expect(minimum.sidebar >= 200)
        #expect(minimum.panel >= 280)

        let wide = WindowColumns(width: 1440, sidebarWidth: 272, panelWidth: 380)
        #expect(wide.sidebar == 272)
        #expect(wide.panel == 380)

        let degenerate = WindowColumns(
            width: .nan, sidebarWidth: .infinity, panelWidth: -50)
        #expect(degenerate.sidebar.isFinite && degenerate.panel.isFinite)
        #expect(degenerate.sidebar >= 0 && degenerate.panel >= 0)
    }

    @Test @MainActor
    func containerInstallSwapsTerminalsWithoutDuplicateConstraints() {
        let container = TerminalPane.ContainerView()
        let first = NSView()
        let second = NSView()
        container.install(first)
        #expect(first.superview === container)
        #expect(container.hostedTerminal === first)
        #expect(container.constraints.filter(\.isActive).count == 4)
        container.install(second)
        #expect(first.superview == nil)
        #expect(second.superview === container)
        #expect(container.hostedTerminal === second)
        #expect(container.constraints.filter(\.isActive).count == 4)
        container.install(second)
        #expect(container.constraints.filter(\.isActive).count == 4)
    }

    @Test @MainActor
    func panelShellStartsWithTheSelectedThemeAndFont() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldHome = ProcessInfo.processInfo.environment["HOME"]
        let oldShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("HOME", root.path, 1)
        setenv("SHELL", "/bin/sh", 1)
        defer {
            if let oldHome { setenv("HOME", oldHome, 1) } else { unsetenv("HOME") }
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
            try? FileManager.default.removeItem(at: root)
        }

        let defaults = UserDefaults(suiteName: "RightPanelTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.executablePath = "/bin/sh"
        settings.defaultDirectory = root.path
        settings.themeName = TerminalTheme.grokDay.name
        settings.fontSize = 19
        let panel = RightPanel(defaults: defaults)
        let model = AppModel(
            settings: settings,
            store: SessionStore(root: root.appendingPathComponent("sessions")),
            presentError: { _ in },
            panel: panel
        )

        model.showPanel(.shell)

        let shell = try #require(panel.shell)
        defer { shell.terminateAndWait() }
        let view = try #require(shell.view as? TerminalView)
        #expect(view.font.pointSize == 19)
        let background = TerminalTheme.grokDay.background
        let expected = NSColor(
            srgbRed: CGFloat(background.red) / 65535,
            green: CGFloat(background.green) / 65535,
            blue: CGFloat(background.blue) / 65535,
            alpha: 1
        )
        #expect(view.nativeBackgroundColor == expected)
    }

    @Test @MainActor
    func aShellThatExitsIsMarkedEndedUntilItRestarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldHome = ProcessInfo.processInfo.environment["HOME"]
        let oldShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("HOME", root.path, 1)
        setenv("SHELL", "/bin/sh", 1)
        defer {
            if let oldHome { setenv("HOME", oldHome, 1) } else { unsetenv("HOME") }
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
            try? FileManager.default.removeItem(at: root)
        }
        let (panel, notesRoot) = makePanel()
        defer { try? FileManager.default.removeItem(at: notesRoot) }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        panel.startShellIfNeeded(in: root, theme: .grokNight, fontSize: 13)
        #expect(!panel.shellExited)
        try #require(panel.shell).send(text: "exit\r")
        try await waitFor { panel.shellExited }
        #expect(panel.shellExited)

        panel.restartShell(in: root, theme: .grokNight, fontSize: 13)
        #expect(!panel.shellExited)

        // The replaced shell stops later. That must not mark the new one ended.
        let replaced = try #require(panel.shell)
        let replacedPID = try #require((replaced.view as? LocalProcessTerminalView)?.process.shellPid)
        panel.restartShell(in: root, theme: .grokNight, fontSize: 13)
        let current = try #require(panel.shell)
        defer { current.terminateAndWait() }
        try await waitFor { kill(replacedPID, 0) != 0 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!replaced.isRunning)
        #expect(!panel.shellExited)
    }

    @Test @MainActor
    func aStoredWidthIsClampedToTheAllowedRange() {
        let name = "RightPanelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(5000.0, forKey: "panel.width")
        #expect(RightPanel(defaults: defaults).width == RightPanel.maxWidth)
        defaults.set(10.0, forKey: "panel.width")
        #expect(RightPanel(defaults: defaults).width == RightPanel.minWidth)
    }
}
