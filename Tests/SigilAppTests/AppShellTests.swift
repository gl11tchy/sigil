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

    @Test func keyboardFocusKnowsTheTerminalThePanelAndNowhere() {
        let window = makeClosableWindow()
        let session = NSView()
        let shell = NSView()
        let shellChild = NSView()
        shell.addSubview(shellChild)
        let notes = NSTextView()
        let search = NSTextView()
        search.isFieldEditor = true
        let swiftUIControl = NSResponder()
        func focus(_ responder: NSResponder?, sidebarHasFocus: Bool = false) -> KeyboardFocus {
            KeyboardFocus.classify(
                responder, in: window, sessionView: session, panelShellView: shell,
                sidebarHasFocus: sidebarHasFocus)
        }

        #expect(focus(session) == .sessionTerminal)
        #expect(focus(shellChild) == .panel)
        #expect(focus(notes) == .panel)
        #expect(focus(search) == .elsewhere)
        #expect(focus(search, sidebarHasFocus: true) == .sidebar)
        #expect(focus(swiftUIControl) == .elsewhere)
        #expect(focus(swiftUIControl, sidebarHasFocus: true) == .sidebar)
        #expect(focus(notes, sidebarHasFocus: true) == .panel)
        #expect(focus(nil) == .lost)
        #expect(focus(window) == .lost)
        #expect(focus(window.contentView) == .lost)
    }

    @Test func hidingAColumnRefocusesTheTerminalOnlyWhenFocusLeftWithIt() {
        #expect(KeyboardFocus.sidebar.needsTerminalAfterHiding(.sidebar))
        #expect(!KeyboardFocus.elsewhere.needsTerminalAfterHiding(.sidebar))
        #expect(KeyboardFocus.lost.needsTerminalAfterHiding(.sidebar))
        #expect(!KeyboardFocus.panel.needsTerminalAfterHiding(.sidebar))
        #expect(!KeyboardFocus.sessionTerminal.needsTerminalAfterHiding(.sidebar))
        #expect(KeyboardFocus.panel.needsTerminalAfterHiding(.panel))
        #expect(KeyboardFocus.lost.needsTerminalAfterHiding(.panel))
        #expect(!KeyboardFocus.elsewhere.needsTerminalAfterHiding(.panel))
        #expect(!KeyboardFocus.sidebar.needsTerminalAfterHiding(.panel))
        #expect(!KeyboardFocus.sessionTerminal.needsTerminalAfterHiding(.panel))
    }

    @Test func hidingTheFocusedSidebarGivesFocusBackToTheTerminal() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        defer { model.closeAllTabsAndWait() }
        let window = makeClosableWindow()
        let sidebarList = FocusableView()
        try #require(window.contentView).addSubview(sidebarList)
        try #require(window.contentView).addSubview(tab.controller.view)
        defer { tab.controller.view.removeFromSuperview() }
        #expect(window.makeFirstResponder(sidebarList))
        model.isSidebarFocused = true
        await flushMainAsync()
        model.needsTerminalFocus = false

        model.isSidebarVisible = false
        await flushMainAsync()

        #expect(model.needsTerminalFocus)
    }

    @Test func hidingTheSidebarLeavesFocusOnAControlOutsideIt() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        defer { model.closeAllTabsAndWait() }
        let window = makeClosableWindow()
        let panelDivider = FocusableView()
        try #require(window.contentView).addSubview(panelDivider)
        try #require(window.contentView).addSubview(tab.controller.view)
        defer { tab.controller.view.removeFromSuperview() }
        #expect(window.makeFirstResponder(panelDivider))
        await flushMainAsync()
        model.needsTerminalFocus = false

        model.isSidebarVisible = false
        await flushMainAsync()

        #expect(!model.needsTerminalFocus)
    }

    @Test func hidingTheSidebarWithItsDividerFocusedGivesFocusBackToTheTerminal() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        defer { model.closeAllTabsAndWait() }
        let window = makeClosableWindow()
        let sidebarDivider = FocusableView()
        try #require(window.contentView).addSubview(sidebarDivider)
        try #require(window.contentView).addSubview(tab.controller.view)
        defer { tab.controller.view.removeFromSuperview() }
        #expect(window.makeFirstResponder(sidebarDivider))
        model.isSidebarDividerFocused = true
        await flushMainAsync()
        model.needsTerminalFocus = false

        model.isSidebarVisible = false
        await flushMainAsync()

        #expect(model.needsTerminalFocus)
    }

    @Test func hidingTheSidebarLeavesFocusInTheNotes() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        defer { model.closeAllTabsAndWait() }
        let window = makeClosableWindow()
        let notes = NSTextView()
        try #require(window.contentView).addSubview(notes)
        try #require(window.contentView).addSubview(tab.controller.view)
        defer { tab.controller.view.removeFromSuperview() }
        #expect(window.makeFirstResponder(notes))
        await flushMainAsync()
        model.needsTerminalFocus = false

        model.isSidebarVisible = false
        await flushMainAsync()

        #expect(!model.needsTerminalFocus)
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

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private func flushMainAsync() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}

private final class Counter {
    var value = 0
}

private final class CapturedError {
    var error: Error?
}
