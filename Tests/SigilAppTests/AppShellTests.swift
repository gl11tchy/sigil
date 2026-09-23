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

    @Test func theCloseButtonAsksToQuitWhileASessionIsWorking() throws {
        let window = makeClosableWindow()
        let quits = Counter()
        let closes = Counter()
        let guardView = WindowCloseGuard.GuardView()
        guardView.shouldConfirm = { true }
        guardView.quit = { quits.value += 1 }
        try #require(window.contentView).addSubview(guardView)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in closes.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        try #require(window.standardWindowButton(.closeButton)).performClick(nil)

        #expect(quits.value == 1)
        #expect(closes.value == 0)
    }

    @Test func theCloseButtonClosesAtOnceWhenNothingIsWorking() throws {
        let window = makeClosableWindow()
        let quits = Counter()
        let closes = Counter()
        let guardView = WindowCloseGuard.GuardView()
        guardView.shouldConfirm = { false }
        guardView.quit = { quits.value += 1 }
        try #require(window.contentView).addSubview(guardView)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in closes.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        try #require(window.standardWindowButton(.closeButton)).performClick(nil)

        #expect(quits.value == 0)
        #expect(closes.value == 1)
    }

    private func makeClosableWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}

private final class Counter {
    var value = 0
}

private final class CapturedError {
    var error: Error?
}
