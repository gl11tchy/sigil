import AppKit
import Foundation
import Testing

@testable import SigilApp

/// The File menu runs the inbox and ended-session banner actions on the selected tab.
@Suite(.serialized)
@MainActor
struct SelectedTabCommandsTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func dismissTabMessageDropsTheSelectedTabsNextMessage() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        #expect(!model.canDismissSelectedTabMessage)

        tab.enqueueBridgePrompt("first")
        tab.enqueueBridgePrompt("second")
        #expect(model.canDismissSelectedTabMessage)

        model.dismissSelectedTabMessage()
        #expect(tab.bridgeInbox.map(\.prompt) == ["second"])
    }

    @Test func deliverTabMessageSendsItToTheSelectedTab() async throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nread line\n")
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        #expect(!model.canDeliverSelectedTabMessage)

        tab.enqueueBridgePrompt("question")
        #expect(!model.canDeliverSelectedTabMessage)
        try await fixture.completeTurn(tab)
        #expect(tab.activity == .idle)
        #expect(model.canDeliverSelectedTabMessage)

        model.deliverSelectedTabMessage()
        #expect(tab.bridgeInbox.isEmpty)
        #expect(tab.activity == .working)
    }

    @Test func deliverTabMessageKeepsTheMessageOnAnEndedTab() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        #expect(await waitUntil { !tab.isRunning })

        tab.enqueueBridgePrompt("question")
        #expect(!model.canDeliverSelectedTabMessage)

        model.deliverSelectedTabMessage()
        #expect(tab.bridgeInbox.count == 1)
    }

    @Test func restartSessionIsOnlyForAnEndedTab() async throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nread line\n")
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let original = try #require(model.newTab(in: try fixture.directory("project")))
        #expect(!model.canRestartSelectedTab)

        model.restartSelectedTab()
        #expect(model.tabs.map(\.id) == [original.id])

        original.controller.send(text: "\r")
        #expect(await waitUntil { model.canRestartSelectedTab })

        model.restartSelectedTab()
        let restarted = try #require(model.selectedTab)
        #expect(restarted.id != original.id)
        #expect(model.tabs.count == 1)
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
