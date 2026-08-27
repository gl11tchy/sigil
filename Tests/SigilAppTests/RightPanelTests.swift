import Foundation
import Testing

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
        #expect(RightPanel.resolve("99999")?.absoluteString == "http://99999")
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
