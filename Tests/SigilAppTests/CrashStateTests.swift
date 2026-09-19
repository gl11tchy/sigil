import AppKit
import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
struct CrashStateTests {

    @Test @MainActor
    func describesEveryTabActivity() {
        #expect(AppModel.describe(.starting) == "starting")
        #expect(AppModel.describe(.working) == "working")
        #expect(AppModel.describe(.idle) == "idle")
        #expect(AppModel.describe(.exited(code: 2)) == "exited 2")
        #expect(AppModel.describe(.exited(code: nil)) == "exited")
    }

    @Test @MainActor
    func crashStateSaysSoWhenNothingIsOpen() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }

        #expect(fixture.model().crashState() == "tabs open: 0")
    }

    @Test @MainActor
    func crashStateNamesTheOpenTabsAndMarksTheSelectedOne() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project-a")
        let id = "crash-state-session"
        try fixture.createSession(id: id, cwd: cwd)
        fixture.settings.openTabs = OpenTabsSnapshot(
            tabs: [.init(sessionID: id, cwd: cwd.path)],
            selectedSessionID: id,
            selectedCWD: cwd.path
        )

        let model = fixture.model()
        model.restoreOpenTabs()
        defer { model.closeAllTabsAndWait() }

        let state = model.crashState()
        #expect(state.hasPrefix("tabs open: 1"))
        #expect(state.contains("\n* "))
        #expect(state.contains(cwd.lastPathComponent))
        #expect(state.contains("terminal tail"))
    }
}
