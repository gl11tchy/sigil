import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@MainActor
struct TabStripTests {
    @Test func chipsTakeTheirTitleWidthAndNeverStretch() {
        #expect(TabStripSizing.fixedChipWidth == nil)

        let wide = TabStripSizing.widths(available: 800, ideals: [150, 150])
        #expect(wide == [150, 150])
        #expect(TabStripSizing.contentWidth(available: 800, ideals: [150, 150]) == 304)

        // A long title stops at the ceiling even when the bar has room.
        let long = TabStripSizing.widths(available: 800, ideals: [600])
        #expect(long == [TabStripSizing.maximumChipWidth])

        let tight = TabStripSizing.widths(available: 100, ideals: [80, 80])
        #expect(tight == [80, 80])
        #expect(TabStripSizing.contentWidth(available: 100, ideals: [80, 80]) > 100)

        #expect(TabStripSizing.widths(available: 200, ideals: []) == [])
    }

    @Test func longTitlesShrinkToFitBeforeTheStripScrolls() {
        // Two long titles split the strip instead of pushing the first one off screen.
        #expect(TabStripSizing.widths(available: 300, ideals: [300, 300]) == [148, 148])
        #expect(TabStripSizing.contentWidth(available: 300, ideals: [300, 300]) == 300)

        // A short title keeps its width; only the long one gives way.
        let mixed = TabStripSizing.widths(available: 220, ideals: [60, 400])
        #expect(mixed[0] == 60)
        #expect(abs(mixed[1] - 156) < 0.01)

        // Below the floor the strip scrolls rather than crushing titles.
        let crowded = TabStripSizing.widths(available: 200, ideals: [300, 300, 300])
        #expect(crowded == Array(repeating: TabStripSizing.minimumChipWidth, count: 3))
        #expect(TabStripSizing.contentWidth(available: 200, ideals: [300, 300, 300]) > 200)
    }

    @Test func tabStripShowsTheScrollPosition() {
        #expect(TabStripSizing.showsScrollIndicators)
    }

    @Test func selectedFolderStaysVisibleWithSeveralSessions() {
        #expect(
            SelectedSessionFolder.text(tabCount: 2, folder: "projects/sigil") == "projects/sigil")
        #expect(
            SelectedSessionFolder.text(tabCount: 1, folder: "projects/sigil") == "projects/sigil")
        #expect(SelectedSessionFolder.text(tabCount: 0, folder: "projects/sigil") == nil)
        #expect(SelectedSessionFolder.text(tabCount: 2, folder: nil) == nil)
        #expect(SelectedSessionFolder.text(tabCount: 2, folder: "") == nil)
    }

    @Test func selectedFolderUsesTheSameBreadcrumbAsTheSingleSessionLabel() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("projects/sigil")
        #expect(SelectedSessionFolder.breadcrumb(of: directory) == "projects/sigil")
        #expect(SelectedSessionFolder.breadcrumb(of: home) == "~")
    }

    @Test @MainActor func tabListRowsShowTitleFolderAndWorkingState() {
        let working = UUID()
        let idle = UUID()
        let entries = TabListRows.entries([
            (id: working, title: "Build", folder: "~/src/sigil", activity: .working),
            (id: idle, title: "Notes", folder: "~/notes", activity: .idle),
        ])

        #expect(entries.map(\.id) == [working, idle])
        #expect(entries[0].title == "Build")
        #expect(entries[0].folder == "~/src/sigil")
        #expect(entries[0].workingState == "Working")
        #expect(entries[0].label == "Build, ~/src/sigil, Working")
        #expect(entries[1].label == "Notes, ~/notes, Idle")
    }

    @Test @MainActor func tabListNamesEveryWorkingState() {
        #expect(TabListRows.workingState(for: .starting) == "Starting")
        #expect(TabListRows.workingState(for: .working) == "Working")
        #expect(TabListRows.workingState(for: .idle) == "Idle")
        #expect(TabListRows.workingState(for: .exited(code: 2)) == "Exited with code 2")
        #expect(TabListRows.workingState(for: .exited(code: nil)) == "Exited with code unknown")
    }

    @Test func choosingATabListEntrySelectsThatTab() {
        let first = UUID()
        let second = UUID()
        let entries = [
            TabListEntry(id: first, title: "Build", folder: "~/src/sigil", workingState: "Working"),
            TabListEntry(id: second, title: "Notes", folder: "~/notes", workingState: "Idle"),
        ]

        #expect(TabListRows.selectedID(afterChoosing: second, in: entries) == second)
        #expect(TabListRows.selectedID(afterChoosing: UUID(), in: entries) == nil)
    }

    @Test func keyboardMovesStayInsideTheTabList() {
        #expect(TabListRows.index(afterMovingBy: 1, from: 0, count: 3) == 1)
        #expect(TabListRows.index(afterMovingBy: -1, from: 0, count: 3) == 0)
        #expect(TabListRows.index(afterMovingBy: 1, from: 2, count: 3) == 2)
        #expect(TabListRows.index(afterMovingBy: 5, from: 0, count: 0) == 0)
    }

    @Test func keyboardHighlightFollowsTheOpenTabs() {
        let first = UUID()
        let second = UUID()
        let entries = [
            TabListEntry(id: first, title: "Build", folder: "~/src/sigil", workingState: "Idle"),
            TabListEntry(id: second, title: "Notes", folder: "~/notes", workingState: "Working"),
        ]

        #expect(
            TabListRows.highlightedID(current: second, selected: first, entries: entries) == second)
        #expect(
            TabListRows.highlightedID(current: UUID(), selected: first, entries: entries) == first)
        #expect(TabListRows.highlightedID(current: nil, selected: nil, entries: entries) == first)
        #expect(TabListRows.highlightedID(current: first, selected: first, entries: []) == nil)
    }

    @Test func tabListFolderIsTheAbbreviatedPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("projects/sigil")
        #expect(TabListRows.folder(of: directory) == "~/projects/sigil")
        #expect(TabListRows.folder(of: home) == "~")
    }

    @Test @MainActor func tabChipSaysTheColorAlongWithTheWorkingState() {
        #expect(
            TabChipAccess.value(
                isSelected: true, hasUnseenActivity: false, activity: .idle, color: nil)
                == "selected, idle")
        #expect(
            TabChipAccess.value(
                isSelected: false, hasUnseenActivity: true, activity: .working, color: .mint)
                == "background, unread, working, mint")
        #expect(
            TabChipAccess.value(
                isSelected: false, hasUnseenActivity: false, activity: .exited(code: 2), color: nil)
                == "background, failed")
    }

    @Test func tabListIsShownWhenMoreThanOneSessionIsOpen() {
        #expect(!TabListRows.isShown(tabCount: 0))
        #expect(!TabListRows.isShown(tabCount: 1))
        #expect(TabListRows.isShown(tabCount: 2))
    }
}
