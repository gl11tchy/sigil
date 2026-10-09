import AppKit
import SwiftUI
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct SidebarVersionNoticeTests {
    /// CI only: this hosts SwiftUI in a window, using generated history and fake installations.
    @Test func threeNoticesPreserveTheListViewportInANarrowShortSidebar() async throws {
        _ = NSApplication.shared
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        // These generated projects live under the temporary root and must survive the ephemeral-path filter.
        fixture.settings.showWorktreeSessions = true
        for index in 0..<8 {
            let folder = try fixture.directory("project-\(index)")
            try fixture.writeListedSession(id: "session-\(index)", cwd: folder.path)
        }
        await fixture.store.reload()
        try #require(fixture.store.sessions.count == 8)

        func model(versions: [CLIProvider: String]) -> AppModel {
            AppModel(
                settings: fixture.settings, store: fixture.store,
                trashConversation: { _ in }, presentError: { _ in },
                panel: RightPanel(
                    defaults: fixture.defaults, notesStore: ConversationNotesStore(root: fixture.notesRoot)),
                pairingStore: InMemoryRemotePairingStore(),
                providerInstallations: versions.mapValues {
                    .init(executable: fixture.executable, version: $0, problem: nil)
                })
        }
        let checked = model(versions: [:])
        checked.archive(try #require(fixture.store.sessions.first))
        let newer = model(versions: [.claudeCode: "2.2.0", .codex: "0.160.0", .grokBuild: "1.0.41"])
        let snapshot = newer.sidebarSnapshot()
        try #require(snapshot.destinations == .init(recentsCount: 7, archivedCount: 1))
        try #require(snapshot.projects.count == 7)
        let baseline = host(checked)
        defer { baseline.window.close() }
        let notices = host(newer)
        defer { notices.window.close() }
        await Task.yield()
        #expect(notices.view.frame.size == NSSize(width: 200, height: 460))
        let baselineScroll = try #require(scrollView(in: baseline.view))
        let noticeScroll = try #require(scrollView(in: notices.view))
        let baselineViewport = baseline.view.convert(baselineScroll.bounds, from: baselineScroll)
        let noticeViewport = notices.view.convert(noticeScroll.bounds, from: noticeScroll)
        #expect(abs(noticeViewport.minY - baselineViewport.minY) < 1)
        #expect(abs(noticeViewport.height - baselineViewport.height) < 1)
        try #require(noticeViewport.height >= 200)

        let document = try #require(noticeScroll.documentView)
        let maximumOffset = document.bounds.height - noticeScroll.contentView.bounds.height
        try #require(maximumOffset > 0)
        var identifiers: Set<String> = []
        let offsets =
            Array(stride(from: 0.0, through: maximumOffset, by: noticeViewport.height / 2))
            + [maximumOffset]
        for offset in offsets {
            noticeScroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            noticeScroll.reflectScrolledClipView(noticeScroll.contentView)
            await Task.yield()
            notices.view.layoutSubtreeIfNeeded()
            notices.window.displayIfNeeded()
            identifiers.formUnion(accessibilityIdentifiers(in: noticeScroll))
        }
        #expect(noticeScroll.contentView.bounds.minY > 0)
        for provider in [CLIProvider.claudeCode, .codex, .grokBuild] {
            #expect(identifiers.contains("sidebar-\(provider.rawValue)-version-notice"))
        }
    }

    private func host(_ model: AppModel) -> (window: NSWindow, view: NSView) {
        let view = NSHostingView(
            rootView: SidebarView(model: model).environment(\.palette, Palette(theme: .sigilDark)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (window, view)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = scrollView(in: child) { return scroll }
        }
        return nil
    }

    private func accessibilityIdentifiers(in element: any NSAccessibilityProtocol) -> Set<String> {
        var identifiers = Set(element.accessibilityIdentifier().map { [$0] } ?? [])
        for child in element.accessibilityChildren() ?? [] {
            if let accessible = child as? any NSAccessibilityProtocol {
                identifiers.formUnion(accessibilityIdentifiers(in: accessible))
            }
        }
        return identifiers
    }
}
