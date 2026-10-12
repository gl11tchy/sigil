import AppKit
import SwiftTerm
import SwiftUI
import Testing

@testable import SigilApp

/// CI only: real NSEvents and NSWindow coordinate conversion exercise the native seam.
@Suite(.serialized)
@MainActor
struct DividerDragHandleTests {
    @Test func theRenderedSeamReceivesRealMouseEventsAtBothEdges() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(272.0, forKey: "window.sidebarWidth")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(
            rootView: WindowContent(model: model)
                .frame(width: 900, height: 500)
                .defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        for offset in [-4.0, 0.0, 4.0] {
            let before = fixture.defaults.double(forKey: "window.sidebarWidth")
            let x = before + 0.5 + offset
            for (type, delta) in [
                (NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, 20.0), (.leftMouseUp, 20.0),
            ] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: NSPoint(x: x + delta, y: 250), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                try dispatch(event)
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(fixture.defaults.double(forKey: "window.sidebarWidth") == before + 20)
        }
    }

    @Test func clickingACappedRenderedSeamPreservesThePreferenceAndFocusesIt() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(430.0, forKey: "window.sidebarWidth")
        let model = fixture.model()
        model.panel.isVisible = true
        defer { model.closeAllTabsAndWait() }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(
            rootView: WindowContent(model: model)
                .frame(width: 900, height: 500)
                .defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 218.5, y: 250), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            try dispatch(event)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.defaults.double(forKey: "window.sidebarWidth") == 430)
        #expect(model.isSidebarDividerFocused)
    }

    @Test func terminalSelectionKeepsTheWindowStationary() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("terminal-drag")
        try fixture.writeListedSession(id: "terminal-drag", cwd: folder.path)
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.open(try #require(fixture.store.sessions.first))
        let hosted = HostedWindow(model: model, defaults: fixture.defaults)
        defer { hosted.window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosted.host.layoutSubtreeIfNeeded()
        let terminal = try #require(try #require(model.selectedTab).controller.view as? LocalProcessTerminalView)
        try #require(terminal.window === hosted.window)
        try #require(terminal.bounds.width > 200 && terminal.bounds.height > 40)
        terminal.feed(text: "\u{1b}[2J\u{1b}[HGenerated terminal selection sentinel\r\n")
        let origin = hosted.window.frame.origin
        let start = terminal.convert(NSPoint(x: 8, y: terminal.bounds.height - 10), to: nil)
        let end = terminal.convert(NSPoint(x: 160, y: terminal.bounds.height - 10), to: nil)
        try await drag(in: hosted.window, from: start, to: end)
        let selected = terminal.selection.getSelectedText()
        #expect(!selected.isEmpty)
        #expect("Generated terminal selection sentinel".contains(selected))
        #expect(hosted.window.frame.origin == origin)
    }

    @Test func notesEditorSelectionKeepsTheWindowStationary() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("editor-drag")
        try fixture.writeListedSession(id: "editor-drag", cwd: folder.path)
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(fixture.store.sessions.first)
        model.open(session)
        let text = "Generated editor selection sentinel ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        model.panel.setNotes(text, forSessionID: session.id, cwd: session.cwd)
        model.showPanel(.notes)
        let hosted = HostedWindow(model: model, defaults: fixture.defaults)
        defer { hosted.window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosted.host.layoutSubtreeIfNeeded()
        let editor = try #require(textEditor(in: hosted.host, containing: text))
        let first = editor.firstRect(forCharacterRange: NSRange(location: 4, length: 1), actualRange: nil)
        let last = editor.firstRect(forCharacterRange: NSRange(location: 20, length: 1), actualRange: nil)
        try #require(!first.isEmpty && !last.isEmpty)
        let origin = hosted.window.frame.origin
        try await drag(
            in: hosted.window,
            from: hosted.window.convertPoint(fromScreen: NSPoint(x: first.midX, y: first.midY)),
            to: hosted.window.convertPoint(fromScreen: NSPoint(x: last.midX, y: last.midY)))
        #expect(editor.selectedRange().length > 0)
        #expect(hosted.window.frame.origin == origin)
    }

    private func drag(in window: NSWindow, from start: NSPoint, to end: NSPoint) async throws {
        for (type, point) in [
            (NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end),
        ] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            try dispatch(event)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func textEditor(in view: NSView, containing text: String) -> NSTextView? {
        if let editor = view as? NSTextView, editor.string == text { return editor }
        for child in view.subviews {
            if let editor = textEditor(in: child, containing: text) { return editor }
        }
        return nil
    }

    @MainActor
    private struct HostedWindow {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        init(model: AppModel, defaults: UserDefaults) {
            window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 1200, height: 600),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: AnyView(WindowContent(model: model).defaultAppStorage(defaults)))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// currentEvent is the last event retrieved from the application queue.
    /// Calling sendEvent directly skips that step and leaves the gesture with a stale event.
    private func dispatch(_ event: NSEvent) throws {
        NSApp.postEvent(event, atStart: true)
        let queued = try #require(
            NSApp.nextEvent(
                matching: NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue),
                until: .distantPast, inMode: .default, dequeue: true))
        try #require(queued === event)
        try #require(NSApp.currentEvent === event)
        NSApp.sendEvent(queued)
    }

    @Test func captureStartsOnMouseDownAndLeavesTheWindowPolicyIntact() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.down(400)
        #expect(fixture.view.capture.isActive)
        #expect(fixture.state.starts == 1)
        #expect(fixture.window.isMovable)
        #expect(fixture.window.isMovableByWindowBackground)
        fixture.up(400)
        #expect(!fixture.view.capture.isActive)
    }

    @Test func aNoMotionClickDoesNotReplaceTheStoredWidthWithTheRenderedCap() {
        let fixture = Fixture(width: 218, limits: 200...218)
        defer { fixture.window.close() }
        var savedWidth = 430.0
        var capture = DividerDragHandle.Capture()
        let down = capture.update(
            with: fixture.event(.leftMouseDown, 400), in: fixture.window,
            width: 218, limits: 200...218, direction: .right)
        #expect(capture.isActive, "Mouse-down still starts the capture used to request focus")
        if let down { savedWidth = down }
        let stationary = capture.update(
            with: fixture.event(.leftMouseDragged, 400), in: fixture.window,
            width: 218, limits: 200...218, direction: .right)
        if let stationary { savedWidth = stationary }
        capture.end()
        #expect(down == nil)
        #expect(stationary == nil)
        #expect(savedWidth == 430)
    }

    @Test func movingTheWindowDoesNotChangeScreenTranslation() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.down(400)
        fixture.drag(420)
        #expect(fixture.state.width == 292)
        fixture.window.setFrameOrigin(NSPoint(x: 150, y: 100))
        fixture.drag(440)
        #expect(fixture.state.width == 312)
        fixture.drag(410)
        #expect(fixture.state.width == 282)
    }

    @Test func reversalRespondsImmediatelyAfterOvershootingBothLimits() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.down(400)
        fixture.drag(800)
        #expect(fixture.state.width == 430)
        fixture.drag(790)
        #expect(fixture.state.width == 420)
        fixture.drag(100)
        #expect(fixture.state.width == 200)
        fixture.drag(110)
        #expect(fixture.state.width == 210)
    }

    @Test func mouseUpEndsCaptureAndTheNextDragUsesTheCurrentWidth() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.down(400)
        fixture.drag(430)
        fixture.up(430)
        fixture.drag(500)
        #expect(fixture.state.width == 302)
        fixture.down(500)
        fixture.drag(480)
        #expect(fixture.state.width == 282)
        #expect(fixture.state.starts == 2)
    }

    @Test func thePanelGrowsWhenThePointerMovesLeft() {
        let fixture = Fixture(width: 380, limits: 280...900, direction: .left)
        defer { fixture.window.close() }
        fixture.down(400)
        fixture.drag(420)
        #expect(fixture.state.width == 360)
        fixture.drag(380)
        #expect(fixture.state.width == 400)
    }

    @Test func aNarrowWindowCapDoesNotLeaveAnOvershootDeadZone() {
        let columns = WindowColumns(width: 900, sidebarWidth: 430, panelWidth: 380)
        let fixture = Fixture(width: 210, limits: 200...columns.sidebar)
        defer { fixture.window.close() }
        fixture.down(400)
        fixture.drag(600)
        #expect(fixture.state.width == 218)
        fixture.drag(595)
        #expect(fixture.state.width == 213)
    }

    @Test func cancelingCaptureDoesNotLeaveAStaleDrag() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.down(400)
        fixture.drag(420)
        fixture.view.capture.end()
        fixture.drag(500)
        #expect(fixture.state.width == 292)
        fixture.down(500)
        fixture.drag(510)
        #expect(fixture.state.width == 302)
    }

    @Test func aLayoutUpdateAdoptsTheDisplayedWidthDuringCapture() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.down(400)
        fixture.drag(450)
        fixture.state.width = 218
        fixture.view.limits = 200...218
        fixture.view.adoptDisplayedWidth()
        fixture.drag(440)
        #expect(fixture.state.width == 208)
    }

    private final class State {
        var width: Double
        var starts = 0
        init(width: Double) { self.width = width }
    }

    @MainActor
    private final class Probe {
        let state: State
        let window: NSWindow
        var limits: ClosedRange<Double>
        let direction: DividerDragHandle.Direction
        var capture = DividerDragHandle.Capture()

        init(state: State, window: NSWindow, limits: ClosedRange<Double>, direction: DividerDragHandle.Direction) {
            self.state = state
            self.window = window
            self.limits = limits
            self.direction = direction
        }

        func mouseDown(with event: NSEvent) {
            capture.end()
            state.starts += 1
            apply(event)
        }

        func mouseDragged(with event: NSEvent) {
            if capture.isActive { apply(event) }
        }

        func mouseUp(with event: NSEvent) { capture.end() }
        func adoptDisplayedWidth() { capture.adopt(state.width, limits: limits) }

        private func apply(_ event: NSEvent) {
            if let next = capture.update(
                with: event, in: window, width: state.width, limits: limits, direction: direction)
            {
                state.width = next
            }
        }
    }

    @MainActor
    private struct Fixture {
        let state: State
        let window: NSWindow
        let view: Probe

        init(
            width: Double = 272, limits: ClosedRange<Double> = 200...430,
            direction: DividerDragHandle.Direction = .right
        ) {
            state = State(width: width)
            window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            view = Probe(state: state, window: window, limits: limits, direction: direction)
        }

        func down(_ x: Double) { view.mouseDown(with: event(.leftMouseDown, x)) }
        func drag(_ x: Double) { view.mouseDragged(with: event(.leftMouseDragged, x)) }
        func up(_ x: Double) { view.mouseUp(with: event(.leftMouseUp, x)) }

        func event(_ type: NSEvent.EventType, _ x: Double) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: window.convertPoint(fromScreen: NSPoint(x: x, y: 400)),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
        }
    }
}
