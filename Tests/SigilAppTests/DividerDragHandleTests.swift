import AppKit
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
                NSApp.sendEvent(event)
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(fixture.defaults.double(forKey: "window.sidebarWidth") == before + 20)
        }
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
