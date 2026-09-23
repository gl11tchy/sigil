import AppKit
import Foundation
import Testing

@testable import SigilApp

@Suite(.serialized)
@MainActor
struct AppShellTests {
    @Test func launchTurnsOffNativeWindowTabs() {
        let before = NSWindow.allowsAutomaticWindowTabbing
        defer { NSWindow.allowsAutomaticWindowTabbing = before }
        NSWindow.allowsAutomaticWindowTabbing = true

        AppDelegate.turnOffWindowTabbing()

        #expect(!NSWindow.allowsAutomaticWindowTabbing)
    }

    @Test func errorAlertsShowTheirInstruction() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let captured = CapturedError()
        let model = fixture.model(presentError: { captured.error = $0 })

        #expect(model.newTab(in: fixture.root.appendingPathComponent("missing")) == nil)

        let alert = NSAlert(error: try #require(captured.error))
        #expect(alert.messageText == "Folder is unavailable")
        #expect(alert.informativeText == "Choose another folder.")
    }
}

private final class CapturedError {
    var error: Error?
}
