import Testing

@testable import SigilApp

struct SidebarActivityDotTests {
    @Test func idleOpenChatShowsNoDotOnceRead() {
        #expect(
            !SidebarActivityDot.isVisible(
                activity: .idle,
                hasUnseenActivity: false,
                isActive: false
            )
        )
    }

    @Test func unreadBackgroundChatShowsADot() {
        #expect(
            SidebarActivityDot.isVisible(
                activity: .idle,
                hasUnseenActivity: true,
                isActive: false
            )
        )
    }

    @Test func selectedUnreadChatHidesTheDot() {
        #expect(
            !SidebarActivityDot.isVisible(
                activity: .idle,
                hasUnseenActivity: true,
                isActive: true
            )
        )
    }

    @Test func workingChatKeepsTheDotEvenWhenSelected() {
        #expect(
            SidebarActivityDot.isVisible(
                activity: .working,
                hasUnseenActivity: false,
                isActive: true
            )
        )
        #expect(
            SidebarActivityDot.isVisible(
                activity: .working,
                hasUnseenActivity: false,
                isActive: false
            )
        )
    }

    @Test func closedChatShowsNoDot() {
        #expect(
            !SidebarActivityDot.isVisible(
                activity: nil,
                hasUnseenActivity: false,
                isActive: false
            )
        )
    }
}
