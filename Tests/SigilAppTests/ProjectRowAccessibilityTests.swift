import Testing

@testable import SigilApp

struct ProjectRowAccessibilityTests {
    @Test func idleUnpinnedFolderReadsItsCount() {
        #expect(
            ProjectRowAccessibility.value(
                countLabel: "3 chats", isActive: false, isWorking: false, isPinned: false)
                == "3 chats")
    }

    /// The row combines its children, so the dot's "Working" and the hidden pin
    /// glyph must be spoken in the value.
    @Test func workingPinnedFolderSaysSo() {
        #expect(
            ProjectRowAccessibility.value(
                countLabel: "3 chats", isActive: true, isWorking: true, isPinned: true)
                == "3 chats, one open, working, pinned")
    }
}
