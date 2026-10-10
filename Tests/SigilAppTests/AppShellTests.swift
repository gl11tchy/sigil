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

    /// Builds before the close guard saved their window under this name. A
    /// launch that restores such a window finds no match for a new name and
    /// opens no window at all.
    @Test func theWindowKeepsTheNameEarlierBuildsSavedItUnder() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let launch = AppLaunch(
            environment: ["GROK_HOME": fixture.grokHome.path], makeModel: { fixture.model() })
        let window = SigilApp.mainWindow(launch: launch) {}

        #expect(
            String(reflecting: type(of: window))
                == "SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SigilApp.RootView, "
                + "SwiftUI._FlexFrameLayout>, SwiftUI._AppearanceActionModifier>"
        )
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

    @Test func hidingThePanelGivesFocusBackToTheTerminal() async throws {
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

        for hide in [{ model.togglePanel() }, { model.showPanel(.notes) }] {
            model.panel.mode = .notes
            model.panel.isVisible = true
            #expect(window.makeFirstResponder(notes))
            await flushMainAsync()
            model.needsTerminalFocus = false

            hide()
            await flushMainAsync()

            #expect(!model.panel.isVisible)
            #expect(model.needsTerminalFocus)
        }
    }

    @Test func hidingThePanelLeavesFocusInTheSidebar() async throws {
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
        model.panel.mode = .notes
        model.panel.isVisible = true
        #expect(window.makeFirstResponder(sidebarList))
        await flushMainAsync()
        model.needsTerminalFocus = false

        model.togglePanel()
        await flushMainAsync()

        #expect(!model.needsTerminalFocus)
    }

    @Test func showingOrRestartingThePanelShellFocusesIt() async throws {
        let home = try TemporaryShellHome()
        defer { home.restore() }
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let window = makeClosableWindow()
        model.panel.mode = .shell
        model.panel.isVisible = false

        model.togglePanel()
        let shell = try #require(model.panel.shell)
        try #require(window.contentView).addSubview(shell.view)
        await flushMainAsync()
        #expect(window.firstResponder === shell.view)

        window.makeFirstResponder(nil)
        model.restartPanelShell()
        let restarted = try #require(model.panel.shell)
        try #require(window.contentView).addSubview(restarted.view)
        await flushMainAsync()
        #expect(window.firstResponder === restarted.view)
    }

    @Test func aPanelShellThatAppearsLateStillTakesFocus() async throws {
        let home = try TemporaryShellHome()
        defer { home.restore() }
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let window = makeClosableWindow()
        model.panel.isVisible = false

        model.showPanel(.shell)
        await flushMainAsync()
        let shell = try #require(model.panel.shell)
        try #require(window.contentView).addSubview(shell.view)
        model.focusPanelShell()
        await flushMainAsync()

        #expect(window.firstResponder === shell.view)
    }

    @Test func aPanelShellOpenedUnderTheNewSessionSheetTakesFocusWhenItCloses() async throws {
        let home = try TemporaryShellHome()
        defer { home.restore() }
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        defer { model.closeAllTabsAndWait() }
        let window = makeClosableWindow()
        try #require(window.contentView).addSubview(tab.controller.view)
        defer { tab.controller.view.removeFromSuperview() }
        model.panel.isVisible = false
        model.isShowingNewSessionSheet = true

        model.showPanel(.shell)
        let shell = try #require(model.panel.shell)
        try #require(window.contentView).addSubview(shell.view)
        model.focusPanelShell()
        await flushMainAsync()
        #expect(window.firstResponder !== shell.view)

        model.isShowingNewSessionSheet = false
        model.newSessionSheetDidClose()
        await flushMainAsync()
        #expect(window.firstResponder === shell.view)
    }

    @Test func inlineEntryKeepsTerminalMountedAndReturnsKeyboardFocusOnCancel() async throws {
        let home = try TemporaryShellHome()
        defer { home.restore() }
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        defer { model.closeAllTabsAndWait() }
        // CI's test app may never become active. Stand in for the key window
        // that is required for AppModel to hand focus back to its terminal.
        let window = InlineEntryKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try #require(window.contentView).addSubview(tab.controller.view)
        defer { tab.controller.view.removeFromSuperview() }
        model.requestNewSession()
        window.makeFirstResponder(nil)
        model.focusSelectedTerminal()
        await flushMainAsync()
        #expect(window.firstResponder !== tab.controller.view)
        #expect(tab.controller.view.window === window)
        #expect(tab.controller.isRunning)
        model.cancelNewSession()
        await flushMainAsync()
        #expect(window.firstResponder === tab.controller.view)
    }

    @Test func switchingFromThePanelShellToNotesGivesFocusBackToTheTerminal() async throws {
        let home = try TemporaryShellHome()
        defer { home.restore() }
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        defer { model.closeAllTabsAndWait() }
        let window = makeClosableWindow()
        try #require(window.contentView).addSubview(tab.controller.view)
        defer { tab.controller.view.removeFromSuperview() }
        model.panel.isVisible = false
        model.showPanel(.shell)
        let shell = try #require(model.panel.shell)
        try #require(window.contentView).addSubview(shell.view)
        await flushMainAsync()
        #expect(window.firstResponder === shell.view)
        model.needsTerminalFocus = false

        model.showPanel(.notes)
        await flushMainAsync()

        #expect(model.panel.isVisible)
        #expect(model.needsTerminalFocus)
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

private final class InlineEntryKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Points HOME at an empty folder and SHELL at /bin/sh, so a panel shell
/// started by a test reads none of the user's startup files.
@MainActor
private final class TemporaryShellHome {
    let root: URL
    private let oldHome = ProcessInfo.processInfo.environment["HOME"]
    private let oldShell = ProcessInfo.processInfo.environment["SHELL"]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppShellTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("HOME", root.path, 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    func restore() {
        if let oldHome { setenv("HOME", oldHome, 1) } else { unsetenv("HOME") }
        if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
        try? FileManager.default.removeItem(at: root)
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
