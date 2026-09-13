import AppKit
import Foundation
import SigilKit
import SwiftTerm
import Testing
import WebKit

@testable import SigilApp

@Suite(.serialized)
struct RightPanelTests {

    @MainActor
    private func makePanel() -> RightPanel {
        let name = "RightPanelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return RightPanel(defaults: defaults)
    }

    @Test @MainActor
    func aBarePortMeansTheLocalDevServer() {
        #expect(RightPanel.resolve("3000")?.absoluteString == "http://localhost:3000")
        #expect(RightPanel.resolve(":8080")?.absoluteString == "http://localhost:8080")
    }

    @Test @MainActor
    func anAddressWithoutASchemeGetsOne() {
        #expect(RightPanel.resolve("example.com")?.absoluteString == "http://example.com")
        #expect(RightPanel.resolve("https://example.com")?.absoluteString == "https://example.com")
        #expect(RightPanel.resolve("   ") == nil)
        #expect(RightPanel.resolve("") == nil)
        #expect(RightPanel.resolve("99999") == nil)
    }

    @Test @MainActor
    func resolveRejectsBadPortsSchemesCredentialsAndWhitespace() {
        for bad in [
            ":0", ":65536", ":99999", "0", "65536", "99999",
            "javascript://example", "javascript:alert(1)", "ftp://example",
            "http://user:pass@example.com", "http://exa mple.com", "with space", "  ",
        ] {
            #expect(RightPanel.resolve(bad) == nil, "should reject \(bad)")
        }
    }

    @Test @MainActor
    func resolveAcceptsPortsHostsAndFilePaths() {
        #expect(RightPanel.resolve("3000")?.absoluteString == "http://localhost:3000")
        #expect(RightPanel.resolve(":8080")?.absoluteString == "http://localhost:8080")
        #expect(RightPanel.resolve("localhost:5173")?.absoluteString == "http://localhost:5173")
        #expect(
            RightPanel.resolve("https://example.com/path")?.absoluteString
                == "https://example.com/path")
        #expect(
            RightPanel.resolve("file:///tmp/fixture.html")?.absoluteString
                == "file:///tmp/fixture.html")
    }

    @Test @MainActor
    func pickingTheShowingToolClosesThePanel() {
        let panel = makePanel()
        let directory = FileManager.default.homeDirectoryForCurrentUser
        panel.toggle(.notes, in: directory)
        #expect(panel.isVisible)
        #expect(panel.mode == .notes)

        panel.toggle(.web, in: directory)
        #expect(panel.isVisible)
        #expect(panel.mode == .web)

        panel.toggle(.web, in: directory)
        #expect(!panel.isVisible)
    }

    @Test @MainActor
    func notesAreKeptPerFolder() {
        let panel = makePanel()
        let a = URL(fileURLWithPath: "/tmp/project-a")
        let b = URL(fileURLWithPath: "/tmp/project-b")
        panel.setNotes("ports: 3000", for: a)
        #expect(panel.notes(for: a) == "ports: 3000")
        #expect(panel.notes(for: b) == "")
        panel.setNotes("", for: a)
        #expect(panel.notes(for: a) == "")
    }

    @Test @MainActor
    func reloadingChangesTheTokenWithoutChangingTheAddress() {
        let panel = makePanel()
        panel.navigate(to: "3000")
        let url = panel.requestedURL
        let token = panel.reloadToken
        panel.reload()
        #expect(panel.requestedURL == url)
        #expect(panel.reloadToken == token + 1)
    }

    @Test @MainActor
    func homeCanBeMovedToTheCurrentAddress() {
        let panel = makePanel()
        panel.navigate(to: "localhost:5173")
        panel.setHomeToCurrentAddress()
        #expect(panel.homeURL == "http://localhost:5173")
        panel.navigate(to: "example.com")
        panel.goHome()
        #expect(panel.requestedURL?.absoluteString == "http://localhost:5173")
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
    func invalidAddressKeepsTheCurrentPageAndShowsAnError() {
        let panel = makePanel()
        panel.navigate(to: "3000")
        let url = panel.requestedURL
        panel.navigate(to: ":99999")
        #expect(panel.requestedURL == url)
        #expect(panel.addressError != nil)
        panel.navigate(to: "example.com")
        #expect(panel.addressError == nil)
        #expect(panel.requestedURL?.absoluteString == "http://example.com")
    }

    @Test @MainActor
    func browserViewSurvivesSwitchingTools() {
        let panel = makePanel()
        panel.navigate(to: "3000")
        let first = panel.browserView()
        panel.mode = .notes
        panel.mode = .web
        #expect(panel.browserView() === first)
    }

    @Test @MainActor
    func browserKeepsItsOwnPageCanvas() {
        let panel = makePanel()
        #expect(panel.browserView().value(forKey: "drawsBackground") as? Bool == true)
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
