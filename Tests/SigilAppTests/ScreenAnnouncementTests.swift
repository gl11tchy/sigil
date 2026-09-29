import Foundation
import Testing

@testable import SigilApp

struct ScreenAnnouncementTests {
    private let tabID = UUID()

    private func snapshot(
        tabID: UUID?,
        activity: TerminalTab.Activity = .idle,
        inboxCount: Int = 0
    ) -> ScreenAnnouncement.Snapshot {
        ScreenAnnouncement.Snapshot(
            tabID: tabID,
            title: "sigil",
            activity: activity,
            inboxCount: inboxCount
        )
    }

    @Test func newMessageOnTheSelectedTabIsSpoken() {
        let text = ScreenAnnouncement.change(
            from: snapshot(tabID: tabID),
            to: snapshot(tabID: tabID, inboxCount: 1)
        )
        #expect(text == "Incoming tab message. Deliver or Dismiss.")
    }

    @Test func deliveringOrDismissingAMessageSaysNothing() {
        let text = ScreenAnnouncement.change(
            from: snapshot(tabID: tabID, inboxCount: 2),
            to: snapshot(tabID: tabID, inboxCount: 1)
        )
        #expect(text == nil)
    }

    @Test func finishedTurnOnTheSelectedTabIsSpoken() {
        let text = ScreenAnnouncement.change(
            from: snapshot(tabID: tabID, activity: .working),
            to: snapshot(tabID: tabID, activity: .idle)
        )
        #expect(text == "sigil: turn finished")
    }

    @Test func sessionThatEndsMidTurnIsSpoken() {
        let text = ScreenAnnouncement.change(
            from: snapshot(tabID: tabID, activity: .working),
            to: snapshot(tabID: tabID, activity: .exited(code: 0))
        )
        #expect(text == "sigil: session ended")
    }

    @Test func sessionThatEndsWhileIdleSaysNothing() {
        let text = ScreenAnnouncement.change(
            from: snapshot(tabID: tabID, activity: .idle),
            to: snapshot(tabID: tabID, activity: .exited(code: 0))
        )
        #expect(text == nil)
    }

    @Test func startingTurnSaysNothing() {
        let text = ScreenAnnouncement.change(
            from: snapshot(tabID: tabID, activity: .idle),
            to: snapshot(tabID: tabID, activity: .working)
        )
        #expect(text == nil)
    }

    @Test func switchingToATabWithAWaitingMessageSaysNothing() {
        let text = ScreenAnnouncement.change(
            from: snapshot(tabID: UUID(), activity: .working),
            to: snapshot(tabID: tabID, activity: .idle, inboxCount: 1)
        )
        #expect(text == nil)
    }

    @Test func findCountIsSpokenForAQuery() {
        #expect(ScreenAnnouncement.findMatches(query: "x", count: 0) == "No matches")
        #expect(ScreenAnnouncement.findMatches(query: "x", count: 1) == "1 match")
        #expect(ScreenAnnouncement.findMatches(query: "x", count: 12) == "12 matches")
    }

    @Test func emptyFindQuerySaysNothing() {
        #expect(ScreenAnnouncement.findMatches(query: "", count: 0) == nil)
    }
}
