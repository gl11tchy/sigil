import AppKit
import Foundation
import SigilKit
import Testing

@testable import SigilApp

/// The workbench selects a new or restarted terminal before SwiftUI mounts
/// it, so focus has to wait for the terminal pane's window attachment. Each
/// test follows the fixture host's order: store the controller, select the
/// task, then attach the pane's container view to a window.
@Suite("WorkbenchFocus", .serialized)
@MainActor
struct WorkbenchFocusTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func initialLaunchFocusesTheSelectedTerminalOnceItAttaches() async throws {
        let store = WorkbenchStore(projects: [project], tasks: [task("a"), task("b")])
        let a = TerminalController()
        let b = TerminalController()
        store.terminals = ["a": a, "b": b]
        store.select("b")
        let window = makeWindow()

        try attach(a, as: "a", to: window, store: store)
        await flushMainAsync()
        #expect(window.firstResponder !== a.view, "an unselected terminal never takes focus")

        try attach(b, as: "b", to: window, store: store)
        await flushMainAsync()
        #expect(window.firstResponder === b.view)
    }

    @Test func aNewTaskTakesFocusWhenItsTerminalAttaches() async throws {
        let store = WorkbenchStore(projects: [project], tasks: [task("a")])
        let a = TerminalController()
        store.terminals = ["a": a]
        let window = makeWindow()
        try attach(a, as: "a", to: window, store: store)
        store.select("a")
        #expect(window.firstResponder === a.view)

        store.tasks.append(task("new"))
        let new = TerminalController()
        store.terminals["new"] = new
        store.select("new")
        #expect(window.firstResponder === a.view, "the new terminal is not in the window yet")

        try attach(new, as: "new", to: window, store: store)
        await flushMainAsync()
        #expect(window.firstResponder === new.view)
    }

    @Test func resumeFocusesTheTerminalItStarts() async throws {
        let store = WorkbenchStore(projects: [project], tasks: [task("a"), task("history", process: .notRunning)])
        let a = TerminalController()
        store.terminals = ["a": a]
        let window = makeWindow()
        try attach(a, as: "a", to: window, store: store)
        store.select("a")
        store.select("history")

        let resumed = TerminalController()
        store.update("history") { $0.process = .live(.unknown) }
        store.terminals["history"] = resumed
        store.select("history")
        try attach(resumed, as: "history", to: window, store: store)
        await flushMainAsync()
        #expect(window.firstResponder === resumed.view)
    }

    @Test func restartFocusesTheReplacementTerminalInTheSamePane() async throws {
        let store = WorkbenchStore(projects: [project], tasks: [task("a")])
        let old = TerminalController()
        store.terminals = ["a": old]
        let window = makeWindow()
        let pane = try attach(old, as: "a", to: window, store: store)
        store.select("a")
        window.makeFirstResponder(nil)

        // Restart swaps the controller; SwiftUI keeps the pane and installs the new view.
        let restarted = TerminalController()
        store.terminals["a"] = restarted
        store.select("a")
        pane.install(restarted.view)
        await flushMainAsync()
        #expect(window.firstResponder === restarted.view)
    }

    @Test func arrowKeysInTheRailNeverHandFocusToATerminal() async throws {
        let store = WorkbenchStore(projects: [project], tasks: [task("a"), task("b")])
        let a = TerminalController()
        let b = TerminalController()
        store.terminals = ["a": a, "b": b]
        store.select("a")
        store.moveSelection(by: 1)
        #expect(store.selectedTaskID == "b")
        let window = makeWindow()
        let rail = FocusableView()
        try #require(window.contentView).addSubview(rail)
        #expect(window.makeFirstResponder(rail))

        try attach(a, as: "a", to: window, store: store)
        try attach(b, as: "b", to: window, store: store)
        await flushMainAsync()
        #expect(window.firstResponder === rail)

        store.moveSelection(by: -1)
        await flushMainAsync()
        #expect(store.selectedTaskID == "a")
        #expect(window.firstResponder === rail)
    }

    @Test func selectingATaskWithoutATerminalHandsTheKeyboardToTheRail() async throws {
        let store = WorkbenchStore(projects: [project], tasks: [task("a"), task("history", process: .notRunning)])
        let a = TerminalController()
        store.terminals = ["a": a]
        let window = makeWindow()
        let rail = FocusableView()
        try #require(window.contentView).addSubview(rail)
        store.focusRail = { window.makeFirstResponder(rail) }
        try attach(a, as: "a", to: window, store: store)
        store.select("a")
        #expect(window.firstResponder === a.view)

        // The hidden terminal stays mounted; it must not keep the keyboard.
        store.select("history")
        #expect(window.firstResponder === rail)

        store.moveSelection(by: -1)
        await flushMainAsync()
        #expect(store.selectedTaskID == "a")
        #expect(window.firstResponder === rail, "arrow keys keep working from the rail")
    }

    @Test func withTheRailHiddenAHiddenTerminalStillLetsGoOfTheKeyboard() async throws {
        let store = WorkbenchStore(projects: [project], tasks: [task("a"), task("history", process: .notRunning)])
        let a = TerminalController()
        store.terminals = ["a": a]
        let window = makeWindow()
        try attach(a, as: "a", to: window, store: store)
        store.select("a")
        #expect(window.firstResponder === a.view)

        store.select("history")
        await flushMainAsync()
        #expect(window.firstResponder === window)
    }

    @Test func movingOnBeforeATerminalAttachesCancelsItsFocus() async throws {
        let store = WorkbenchStore(projects: [project], tasks: [task("a"), task("b")])
        let a = TerminalController()
        store.terminals = ["a": a]
        store.select("a")
        store.moveSelection(by: 1)
        let window = makeWindow()

        try attach(a, as: "a", to: window, store: store)
        await flushMainAsync()
        #expect(window.firstResponder !== a.view)
    }

    // MARK: - Helpers

    private let project = WorkbenchProject(path: "/tmp/sigil-focus-project")

    /// Tasks sort by creation time, so "a" comes before "b" in the rail.
    private func task(_ id: String, process: TaskProcess = .live(.working)) -> WorkbenchTask {
        let order: TimeInterval = ["a": 1, "b": 2, "history": 3, "new": 4][id] ?? 5
        return WorkbenchTask(
            id: id, projectID: project.id, title: id, provider: .grokBuild,
            workspace: WorkbenchWorkspace(path: project.path, kind: .projectFolder), process: process,
            conversation: .none, createdAt: Date(timeIntervalSince1970: order))
    }

    /// Mounts a terminal the way `WorkbenchView` does: in a terminal pane's
    /// container whose window attachment reports to the store.
    @discardableResult
    private func attach(
        _ controller: TerminalController, as id: String, to window: NSWindow, store: WorkbenchStore
    ) throws -> TerminalPane.ContainerView {
        let pane = TerminalPane.ContainerView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        pane.onWindowAttachment = { [weak store] in store?.terminalDidAttach(id) }
        pane.install(controller.view)
        try #require(window.contentView).addSubview(pane)
        return pane
    }

    /// Never ordered front, so nothing appears on screen.
    private func makeWindow() -> NSWindow {
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
