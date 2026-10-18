import AppKit
import ApplicationServices
import Darwin
import SwiftTerm
import SwiftUI
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct SidebarVersionNoticeTests {
    @Test func searchArrowsKeepTheFieldFocusedAndMoveTheHighlight() async throws {
        try #require(NSApplication.shared.isRunning)
        let fixture = try SidebarFixture()
        defer { fixture.cleanup() }
        let model = try await searchModel(fixture)
        defer { model.closeAllTabsAndWait() }
        let probe = HoverProbe()
        let hosted = host(
            NSHostingView(
                rootView: SidebarView(model: model, observeHover: { probe.glide = $0 })
                    .environment(\.palette, Palette(theme: .sigilDark))),
            size: .init(width: 272, height: 600), interactive: true)
        defer { hosted.window.close() }
        model.focusSidebarSearch()
        model.searchText = "auth"
        let rows = model.sidebarSnapshot().rowIDs
        try #require(rows.count == 3)
        try await waitForSearchState("Search must have a real editor and top-row highlight") {
            hosted.window.firstResponder is NSTextView && model.sidebarCommandContext.keyboardRowID == rows[0]
        }
        let editor = try #require(hosted.window.firstResponder as? NSTextView)
        try #require(editor.string == "auth")
        let down = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hosted.window.windowNumber, context: nil, characters: "\u{F701}",
                charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        try #require(down.window === hosted.window)
        print(
            """
            REA-1258 before Down: appActive=\(NSApp.isActive), keyWindow=\(hosted.window.isKeyWindow), \
            editor=\(type(of: editor)), query=\(editor.string), dispatch=owned NSWindow.sendEvent
            """)
        // Deliver to this generated window's responder chain even when the CI
        // host is inactive. No event is posted to the desktop or another window.
        hosted.window.sendEvent(down)
        try await waitForSearchState("Down must reach the real sidebar key handler") {
            model.sidebarCommandContext.listFocused || model.sidebarCommandContext.keyboardRowID == rows[1]
        }
        print(
            """
            REA-1258 Down: query=\(model.searchText), fieldKept=\(hosted.window.firstResponder === editor), \
            listFocused=\(model.sidebarCommandContext.listFocused), row=\(model.sidebarCommandContext.keyboardRowID ?? "nil")
            """)
        #expect(hosted.window.firstResponder === editor)
        #expect(!model.sidebarCommandContext.listFocused)
        #expect(model.sidebarCommandContext.keyboardRowID == rows[1])
        for (keyCode, characters, expected, repeating) in [
            (UInt16(126), "\u{F700}", rows[0], false),
            (UInt16(126), "\u{F700}", rows[0], true),
            (UInt16(125), "\u{F701}", rows[1], false),
            (UInt16(125), "\u{F701}", rows[2], true),
            (UInt16(125), "\u{F701}", rows[2], true),
        ] {
            try sendSearchKey(to: hosted.window, keyCode: keyCode, characters: characters, repeating: repeating)
            try await Task.sleep(for: .milliseconds(30))
            #expect(model.sidebarCommandContext.keyboardRowID == expected)
            #expect(hosted.window.firstResponder === editor)
            #expect(!model.sidebarCommandContext.listFocused)
        }
    }

    @Test func searchFieldHighlightIsVisibleInDarkAndLight() async throws {
        try #require(NSApplication.shared.isRunning)
        for theme in [TerminalTheme.sigilDark, .sigilLight] {
            let fixture = try SidebarFixture()
            defer { fixture.cleanup() }
            let model = try await searchModel(fixture)
            defer { model.closeAllTabsAndWait() }
            let probe = HoverProbe()
            let hosted = host(
                NSHostingView(
                    rootView: SidebarView(model: model, observeHover: { probe.glide = $0 })
                        .environment(\.palette, Palette(theme: theme))
                        .environment(\.colorScheme, theme.isDark ? .dark : .light)),
                size: .init(width: 272, height: 600), interactive: true)
            defer { hosted.window.close() }
            model.focusSidebarSearch()
            model.searchText = "auth"
            let first = try #require(model.sidebarSnapshot().rowIDs.first)
            try await waitForSearchState("Search must own focus and the first result") {
                hosted.window.firstResponder is NSTextView && model.sidebarCommandContext.keyboardRowID == first
            }
            let editor = try #require(hosted.window.firstResponder as? NSTextView)
            try #require(editor.string == "auth")
            // Remove incidental pointer hover through the view's actual callback.
            // Keyboard fill must then remain visible while the editor keeps focus.
            if let target = probe.glide?.target { probe.glide?.hover(target, false) }
            try await Task.sleep(for: .milliseconds(100))
            print(
                """
                REA-1258 search fill: appearance=\(theme.name), row=\(first), \
                fill=\(probe.glide?.target ?? "nil"), listFocused=\(model.sidebarCommandContext.listFocused)
                """)
            #expect(!model.sidebarCommandContext.listFocused)
            #expect(hosted.window.firstResponder === editor)
            #expect(probe.glide?.target == first)
        }
    }

    @Test func typingReranksTheHighlightAndReturnOpensTheCurrentResult() async throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanup() }
        let model = try await searchModel(fixture)
        defer { model.closeAllTabsAndWait() }
        let search = try await hostSearch(model)
        defer { search.window.close() }
        for expected in search.rows.dropFirst() {
            try sendSearchKey(to: search.window, keyCode: 125, characters: "\u{F701}")
            try await waitForSearchState("Down must advance before typing") {
                model.sidebarCommandContext.keyboardRowID == expected
            }
        }
        #expect(search.window.firstResponder === search.editor)
        search.editor.setSelectedRange(NSRange(location: search.editor.string.utf16.count, length: 0))
        try sendSearchKey(to: search.window, keyCode: 1, characters: "s")
        try await waitForSearchState("Typing must continue in search and rerank") {
            model.searchText == "auths" && model.sidebarSnapshot().rowIDs.count == 2
                && model.sidebarCommandContext.keyboardRowID == model.sidebarSnapshot().rowIDs.first
        }
        #expect(search.window.firstResponder === search.editor)
        #expect(!model.sidebarCommandContext.listFocused)
        let current = try #require(model.sidebarSnapshot().rowIDs.first)
        #expect(
            current != search.rows.last,
            "The prior row remains visible but reranking must select the new top row")
        let session = try #require(model.sidebarSessions.first { model.sessionKey($0) == current })
        try sendSearchKey(to: search.window, keyCode: 36, characters: "\r")
        try await waitForSearchState("Return must open the highlighted reranked session") {
            model.selectedTab?.sessionID == session.id
        }
        #expect(model.tabs.count == 1)
    }

    @Test func searchTabTraversalAndModifiedArrowsPreserveTheirRoles() async throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanup() }
        let model = try await searchModel(fixture)
        defer { model.closeAllTabsAndWait() }
        let search = try await hostSearch(model)
        defer { search.window.close() }
        try sendSearchKey(to: search.window, keyCode: 125, characters: "\u{F701}")
        try await waitForSearchState("Choose the second result before Tab") {
            model.sidebarCommandContext.keyboardRowID == search.rows[1]
        }
        try sendSearchKey(to: search.window, keyCode: 48, characters: "\t")
        try await waitForSearchState("Plain Tab must enter the list") { model.sidebarCommandContext.listFocused }
        #expect(model.sidebarCommandContext.keyboardRowID == search.rows[1])
        #expect(search.window.firstResponder !== search.editor)

        model.focusSidebarSearch()
        try await waitForSearchState("Return to the owned search editor") {
            search.window.firstResponder === search.editor && !model.sidebarCommandContext.listFocused
        }
        search.editor.setSelectedRange(NSRange(location: 0, length: 0))
        try sendSearchKey(to: search.window, keyCode: 125, characters: "\u{F701}", modifiers: .shift)
        try await Task.sleep(for: .milliseconds(30))
        #expect(search.editor.selectedRange().length > 0)
        #expect(search.window.firstResponder === search.editor)
        #expect(model.sidebarCommandContext.keyboardRowID == search.rows[1])
        try sendSearchKey(to: search.window, keyCode: 48, characters: "\t", modifiers: .shift)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!model.sidebarCommandContext.listFocused, "Shift-Tab must not become forward list traversal")

        model.searchText = ""
        model.focusSidebarSearch()
        try await waitForSearchState("Empty search must own its editor") {
            search.window.firstResponder === search.editor && search.editor.string.isEmpty
        }
        try sendSearchKey(to: search.window, keyCode: 126, characters: "\u{F700}")
        try await Task.sleep(for: .milliseconds(30))
        #expect(search.window.firstResponder === search.editor)
        #expect(!model.sidebarCommandContext.listFocused)
        try sendSearchKey(to: search.window, keyCode: 125, characters: "\u{F701}")
        try await waitForSearchState("Empty-query Down must retain existing list traversal") {
            model.sidebarCommandContext.listFocused
        }
    }

    @Test func searchWithNoResultsCannotNavigateOrActivateAStaleRow() async throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanup() }
        let model = try await searchModel(fixture)
        defer { model.closeAllTabsAndWait() }
        let search = try await hostSearch(model)
        defer { search.window.close() }
        try sendSearchKey(to: search.window, keyCode: 125, characters: "\u{F701}")
        try await waitForSearchState("Select a real row before removing the results") {
            model.sidebarCommandContext.keyboardRowID == search.rows[1]
        }
        model.searchText = "no-generated-session-matches-this"
        try await waitForSearchState("No results must clear the old highlight") {
            model.sidebarSnapshot().rowIDs.isEmpty && model.sidebarCommandContext.keyboardRowID == nil
        }
        for (keyCode, characters) in [(UInt16(125), "\u{F701}"), (UInt16(126), "\u{F700}")] {
            try sendSearchKey(to: search.window, keyCode: keyCode, characters: characters)
            try await Task.sleep(for: .milliseconds(30))
            #expect(search.window.firstResponder === search.editor)
            #expect(!model.sidebarCommandContext.listFocused)
            #expect(model.sidebarCommandContext.keyboardRowID == nil)
        }
        try sendSearchKey(to: search.window, keyCode: 36, characters: "\r")
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.tabs.isEmpty)
        #expect(model.selectedTab == nil)
        #expect(model.sidebarCommandContext.keyboardRowID == nil)
    }

    private func hostSearch(_ model: AppModel) async throws -> (window: NSWindow, editor: NSTextView, rows: [String]) {
        try #require(NSApplication.shared.isRunning)
        let probe = HoverProbe()
        let hosted = host(
            NSHostingView(
                rootView: SidebarView(model: model, observeHover: { probe.glide = $0 })
                    .environment(\.palette, Palette(theme: .sigilDark))),
            size: .init(width: 272, height: 600), interactive: true)
        do {
            model.focusSidebarSearch()
            model.searchText = "auth"
            let rows = model.sidebarSnapshot().rowIDs
            try #require(rows.count == 3)
            try await waitForSearchState("Search must own a real field editor and the first result") {
                hosted.window.firstResponder is NSTextView && model.sidebarCommandContext.keyboardRowID == rows[0]
                    && model.isSidebarFocused && !model.sidebarCommandContext.listFocused
            }
            let editor = try #require(hosted.window.firstResponder as? NSTextView)
            try #require(editor.string == "auth")
            if let target = probe.glide?.target { probe.glide?.hover(target, false) }
            try await waitForSearchState("The search focus must render before delivering the first key") {
                probe.glide?.target == rows[0] && hosted.window.firstResponder === editor
                    && model.isSidebarFocused && !model.sidebarCommandContext.listFocused
            }
            hosted.view.layoutSubtreeIfNeeded()
            print(
                """
                REA-1258 ready: searchFocused=true, query=\(editor.string), \
                row=\(rows[0]), fill=\(probe.glide?.target ?? "nil")
                """)
            return (hosted.window, editor, rows)
        } catch {
            hosted.window.close()
            throw error
        }
    }

    private func sendSearchKey(
        to window: NSWindow, keyCode: UInt16, characters: String,
        modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false
    ) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeating, keyCode: keyCode))
        try #require(event.window === window)
        let editor = window.firstResponder as? NSTextView
        print(
            """
            REA-1258 key: code=\(keyCode), modifiers=\(modifiers.rawValue), \
            query=\(editor?.string ?? "nil"), marked=\(editor?.hasMarkedText() ?? false)
            """)
        window.sendEvent(event)
    }

    private func searchModel(_ fixture: SidebarFixture) async throws -> AppModel {
        fixture.settings.showWorktreeSessions = true
        let folder = try fixture.directory("search-project")
        for (index, title) in ["Auths", "Auth two", "Auths notes"].enumerated() {
            try fixture.writeListedSession(id: "search-\(index)", cwd: folder.path, summary: title)
        }
        await fixture.store.reload()
        let model = fixture.model()
        model.openRecents()
        return model
    }

    private func waitForSearchState(_ description: String, _ ready: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard ready() else {
            throw NSError(domain: "Sigil.SearchHostFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
        }
    }

    @Test func thousandSessionTwentyRowHoverSweep() async throws {
        try #require(NSApplication.shared.isRunning)
        let fixture = try SidebarFixture()
        defer { fixture.cleanup() }
        fixture.settings.showWorktreeSessions = true
        let folder = try fixture.directory("hover-project")
        for index in 0..<1_000 {
            try fixture.writeListedSession(id: "hover-\(index)", cwd: folder.path)
        }
        await fixture.store.reload()
        try #require(fixture.store.sessions.count == 1_000)
        let model = AppModel(
            settings: fixture.settings, store: fixture.store,
            trashConversation: { _ in }, presentError: { _ in },
            panel: RightPanel(defaults: fixture.defaults, notesStore: ConversationNotesStore(root: fixture.notesRoot)),
            pairingStore: InMemoryRemotePairingStore(), providerInstallations: [:])
        defer { model.closeAllTabsAndWait() }
        model.openRecents()
        let rows = Array(model.sidebarSnapshot().rowIDs.prefix(20))
        try #require(rows.count == 20)
        let probe = HoverProbe()
        let hosted = host(
            NSHostingView(
                rootView:
                    SidebarView(model: model, observeHover: { probe.glide = $0 })
                    .environment(\.palette, Palette(theme: .sigilDark))))
        defer { hosted.window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let initialBuilds = model.sidebarSnapshotBuildCount
        let start = ContinuousClock.now
        for row in rows {
            try #require(probe.glide != nil)
            probe.glide?.hover(row, true)
            let deadline = ContinuousClock.now + .seconds(1)
            while probe.glide?.target != row, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(probe.glide?.target == row, "Each real hover callback must render its highlight")
            hosted.view.layoutSubtreeIfNeeded()
        }
        let elapsed = start.duration(to: .now)
        let builds = model.sidebarSnapshotBuildCount - initialBuilds
        print(
            "REA-1255 hover fixture: sessions=1000 rows=20 elapsed=\(elapsed) snapshotBuilds=\(builds); DEBUG, reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), actual onHover callback, 200x460 app-host window; excludes seeding/initial layout"
        )
        #expect(builds < 20, "The hover sweep must reuse snapshots within the freshness window")
    }

    /// CI only: this hosts SwiftUI in a window, using generated history and fake installations.
    @Test func threeNoticesPreserveTheListViewportInANarrowShortSidebar() async throws {
        try #require(NSApplication.shared.isRunning, "The fixture requires the SwiftUI app-host event loop")
        let fixture = try SidebarFixture()
        defer { fixture.cleanup() }
        // These generated projects live under the temporary root and must survive the ephemeral-path filter.
        fixture.settings.showWorktreeSessions = true
        for index in 0..<8 {
            let folder = try fixture.directory("project-\(index)")
            try fixture.writeListedSession(id: "session-\(index)", cwd: folder.path)
        }
        await fixture.store.reload()
        try #require(fixture.store.sessions.count == 8)
        let incompleteFolder = GrokPaths.sessionDirectory(
            cwd: try fixture.directory("pending-project").path, sessionID: "pending")
        try FileManager.default.createDirectory(at: incompleteFolder, withIntermediateDirectories: true)
        await fixture.store.reload()
        try #require(fixture.store.loadError == nil && fixture.store.historyNotice != nil)

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
        // Ordinary controls distinguish SwiftUI export from this sidebar's content and the walker itself.
        var controlAccessibilityEnabled: Bool?
        let control = host(
            NSHostingView(
                rootView: AccessibilityControl { controlAccessibilityEnabled = $0 }))
        defer { control.window.close() }
        let nativeButton = NSButton(title: "Native diagnostic button", target: nil, action: nil)
        let nativeCell = try #require(nativeButton.cell as? NSButtonCell)
        nativeCell.setAccessibilityIdentifier("diagnostic-native-button")
        let nativeControl = host(nativeButton)
        defer { nativeControl.window.close() }
        let baseline = host(checked)
        defer { baseline.window.close() }
        let notices = host(newer, interactive: true)
        defer { notices.window.close() }
        // Request the generated host's AX hierarchy before reading SwiftUI's public getters.
        // Query only this generated host, off its main event loop; no trust or environment override.
        let ownedRequest = await Task.detached {
            let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let timeout = AXUIElementSetMessagingTimeout(application, 2)
            guard timeout == .success else { return timeout.rawValue }
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows).rawValue
        }.value
        try #require(ownedRequest == AXError.success.rawValue, "The hosted app must serve its own AX request")
        // Let SwiftUI build its exported accessibility tree after the window becomes visible.
        let deadline = ContinuousClock.now + .seconds(2)
        while notices.view.accessibilityChildren()?.isEmpty != false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(notices.view.frame.size == NSSize(width: 200, height: 460))
        let baselineScroll = try #require(scrollView(in: baseline.view))
        let noticeScroll = try #require(scrollView(in: notices.view))
        let baselineViewport = baseline.view.convert(baselineScroll.bounds, from: baselineScroll)
        let noticeViewport = notices.view.convert(noticeScroll.bounds, from: noticeScroll)
        #expect(notices.view.isFlipped == baseline.view.isFlipped)
        let baselineTop = baseline.view.isFlipped ? baselineViewport.minY : baselineViewport.maxY
        let noticeTop = notices.view.isFlipped ? noticeViewport.minY : noticeViewport.maxY
        #expect(abs(noticeTop - baselineTop) < 1)
        print(
            "REA-1351 viewport: flipped=\(notices.view.isFlipped), baseline=\(baselineViewport), notices=\(noticeViewport)"
        )
        #expect(
            abs(baselineViewport.height - noticeViewport.height - 34) < 1,
            "All nonblocking versions share one 26-point control and eight points of bottom spacing")
        try #require(noticeViewport.height >= 200)

        let document = try #require(noticeScroll.documentView)
        let maximumOffset = document.bounds.height - noticeScroll.contentView.bounds.height
        try #require(maximumOffset > 0)
        var identifiers: Set<String> = []
        var tree: [String] = []
        let offsets =
            Array(stride(from: 0.0, through: maximumOffset, by: noticeViewport.height / 2))
            + [maximumOffset]
        for offset in offsets {
            noticeScroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            noticeScroll.reflectScrolledClipView(noticeScroll.contentView)
            try await Task.sleep(for: .milliseconds(20))
            notices.view.layoutSubtreeIfNeeded()
            notices.window.displayIfNeeded()
            // SwiftUI owns the accessible hierarchy; the native NSScrollView is only its rendering backend.
            var visited: Set<ObjectIdentifier> = []
            identifiers.formUnion(
                accessibilityIdentifiers(in: notices.window, visited: &visited, tree: &tree))
        }
        #expect(noticeScroll.contentView.bounds.minY > 0)
        var controlVisited: Set<ObjectIdentifier> = []
        var controlTree: [String] = []
        let controlIdentifiers = accessibilityIdentifiers(
            in: control.window, visited: &controlVisited, tree: &controlTree)
        var nativeVisited: Set<ObjectIdentifier> = []
        var nativeTree: [String] = []
        let nativeIdentifiers = accessibilityIdentifiers(
            in: nativeControl.window, visited: &nativeVisited, tree: &nativeTree)
        let hostState = """
            ownedAXRequest=\(ownedRequest), running=\(NSApp.isRunning), active=\(NSApp.isActive), hidden=\(NSApp.isHidden), \
            activationPolicy=\(NSApp.activationPolicy().rawValue), voiceOver=\(NSWorkspace.shared.isVoiceOverEnabled), \
            plainSwiftUIAccessibilityEnabled=\(controlAccessibilityEnabled.map(String.init) ?? "unobserved"), \
            noticeWindowVisible=\(notices.window.isVisible), noticeWindowKey=\(notices.window.isKeyWindow), \
            noticeChildren=\(notices.view.accessibilityChildren()?.count ?? 0), \
            noticeNavigationChildren=\(notices.view.accessibilityChildrenInNavigationOrder()?.count ?? 0)
            """
        let diagnostic = """
            Host: \(hostState)
            Ordinary SwiftUI control tree: \(controlTree)
            Native control tree: \(nativeTree)
            """
        print("REA-1214 accessibility diagnostic: \(diagnostic)")
        #expect(nativeIdentifiers.contains("diagnostic-native-button"), "\(diagnostic)")
        for identifier in ["diagnostic-swiftui-text", "diagnostic-swiftui-button"] {
            #expect(controlIdentifiers.contains(identifier), "\(diagnostic)")
        }
        #expect(identifiers.contains("sidebar-compatibility-disclosure"), "\(tree). \(diagnostic)")
        let providers: [CLIProvider] = [.claudeCode, .codex, .grokBuild]
        for provider in providers {
            #expect(
                !identifiers.contains("sidebar-\(provider.rawValue)-version-notice"),
                "Nonblocking paragraphs must be absent from the collapsed history list")
        }
        trace("collapsed checks complete; opening compatibility details")
        let offsetBeforeDetails = noticeScroll.contentView.bounds.origin
        let destinationsBeforeDetails = newer.sidebarSnapshot().destinations
        try #require(
            pressOwnedAccessibility("sidebar-compatibility-disclosure", in: notices.window) == AXError.success.rawValue)
        try await Task.sleep(for: .milliseconds(100))
        trace("compatibility AX press complete; reading details")
        let details = ownedAccessibilityValues()
        for provider in providers {
            let expected = try #require(provider.versionNotice(for: newer.providerInstallations[provider]))
            #expect(
                details["sidebar-\(provider.rawValue)-version-notice"] == expected,
                "The native popover must export each complete installed/checked version and limitation")
        }
        #expect(noticeScroll.contentView.bounds.origin == offsetBeforeDetails)
        #expect(newer.sidebarSnapshot().destinations == destinationsBeforeDetails)
        #expect(noticeScroll.contentView.bounds.height == noticeViewport.height)
        trace("version/scroll checks complete; closing details")
        try #require(
            pressOwnedAccessibility("sidebar-compatibility-close", in: notices.window) == AXError.success.rawValue)
        try await Task.sleep(for: .milliseconds(100))
        trace("close AX press complete; reading closed state")
        let closedDetails = ownedAccessibilityValues()
        #expect(!closedDetails.keys.contains("sidebar-compatibility-close"))
        #expect(closedDetails["sidebar-compatibility-disclosure"]?.contains("Details hidden.") == true)
        #expect(noticeScroll.contentView.bounds.origin == offsetBeforeDetails)
        // A single newer provider consumes the same bounded footprint; zero consumes none.
        trace("closed state checks complete; hosting one-version sidebar")
        let one = model(versions: [.codex: "0.160.0"])
        let single = host(one)
        defer { single.window.close() }
        try await Task.sleep(for: .milliseconds(50))
        let singleScroll = try #require(scrollView(in: single.view))
        #expect(abs(singleScroll.contentView.bounds.height - noticeViewport.height) < 1)
        var baselineVisited: Set<ObjectIdentifier> = []
        var baselineTree: [String] = []
        let baselineIdentifiers = accessibilityIdentifiers(
            in: baseline.window, visited: &baselineVisited, tree: &baselineTree)
        #expect(!baselineIdentifiers.contains("sidebar-compatibility-disclosure"))
        // A targeted request works both before first appearance and on an existing Settings window.
        trace("one/zero checks complete; hosting default Appearance settings")
        let preferences = host(
            NSHostingView(rootView: SettingsView(model: newer)), size: .init(width: 540, height: 660))
        defer { preferences.window.close() }
        try await Task.sleep(for: .milliseconds(50))
        trace("Appearance settings hosted; reading initial pane")
        #expect(!(ownedAccessibilityValues()).keys.contains("settings-general"))
        trace("requesting General on existing Settings window")
        newer.requestGeneralSettings()
        try await Task.sleep(for: .milliseconds(100))
        trace("reading routed General pane")
        #expect((ownedAccessibilityValues()).keys.contains("settings-general"))
        #expect(newer.generalSettingsRequest == nil, "A targeted route is consumed, not replayed on ordinary opens")
        trace("requesting General on existing Settings window")
        newer.requestGeneralSettings()
        try await Task.sleep(for: .milliseconds(50))
        #expect(newer.generalSettingsRequest == nil)
        trace("reading routed General pane")
        #expect((ownedAccessibilityValues()).keys.contains("settings-general"))
        trace("existing/repeated route checks complete; hosting first-open request")
        let firstOpen = model(versions: [:])
        firstOpen.requestGeneralSettings()
        let routed = host(
            NSHostingView(rootView: SettingsView(model: firstOpen)), size: .init(width: 540, height: 660))
        defer { routed.window.close() }
        try await Task.sleep(for: .milliseconds(50))
        trace("first-open settings hosted; checking consumption and exported pane")
        #expect(firstOpen.generalSettingsRequest == nil)
        var routedVisited: Set<ObjectIdentifier> = []
        var routedTree: [String] = []
        #expect(
            accessibilityIdentifiers(in: routed.window, visited: &routedVisited, tree: &routedTree)
                .contains("settings-general"))
        trace("all routing checks complete; retained history notice check")
        #expect(
            identifiers.contains("sidebar-history-compatibility-notice"),
            "Exported compatibility notice: \(tree). \(diagnostic)")
    }

    @Test(
        .enabled(
            if: CGPreflightPostEventAccess(),
            "REA-1350 owner manual verification: native pointer input skipped because event-posting permission is unavailable"
        ))
    func theRenderedSeamReceivesRealMouseEventsAtBothEdges() async throws {
        try #require(NSApplication.shared.isRunning, "Rendered input requires the SwiftUI app-host loop")
        let fixture = try SidebarFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(272.0, forKey: "window.sidebarWidth")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.animationBehavior = .none
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
            var events: [NSEvent] = []
            for (type, delta) in [
                (NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, 20.0), (.leftMouseUp, 20.0),
            ] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: NSPoint(x: x + delta, y: 250), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: Self.nextEventNumber(), clickCount: 1, pressure: 1))
                events.append(event)
            }
            try await dispatch(events)
            #expect(fixture.defaults.double(forKey: "window.sidebarWidth") == before + 20)
        }
    }

    @Test(
        .enabled(
            if: CGPreflightPostEventAccess(),
            "REA-1350 owner manual verification: native pointer input skipped because event-posting permission is unavailable"
        ))
    func clickingACappedRenderedSeamPreservesThePreferenceAndFocusesIt() async throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(430.0, forKey: "window.sidebarWidth")
        let model = fixture.model()
        model.panel.isVisible = true
        defer { model.closeAllTabsAndWait() }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.animationBehavior = .none
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
        var events: [NSEvent] = []
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 218.5, y: 250), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: Self.nextEventNumber(), clickCount: 1, pressure: 1))
            events.append(event)
        }
        try await dispatch(events)
        #expect(fixture.defaults.double(forKey: "window.sidebarWidth") == 430)
        #expect(model.isSidebarDividerFocused)
    }

    @Test(
        .enabled(
            if: CGPreflightPostEventAccess(),
            "REA-1350 owner manual verification: native pointer input skipped because event-posting permission is unavailable"
        ))
    func terminalSelectionKeepsTheWindowStationary() async throws {
        let fixture = try SidebarFixture()
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
        let tab = try #require(model.selectedTab)
        let terminal = try #require(tab.controller.view as? LocalProcessTerminalView)
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

    @Test(
        .enabled(
            if: CGPreflightPostEventAccess(),
            "REA-1350 owner manual verification: native pointer input skipped because event-posting permission is unavailable"
        ))
    func notesEditorSelectionKeepsTheWindowStationary() async throws {
        let fixture = try SidebarFixture()
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
        var events: [NSEvent] = []
        // SwiftTerm anchors selection at the first drag event, then extends it
        // on subsequent movement. Supply a real path instead of one end-point jump.
        let middle = NSPoint(x: start.x + (end.x - start.x) / 2, y: start.y + (end.y - start.y) / 2)
        let firstMovement = NSPoint(x: start.x + (end.x - start.x) / 4, y: start.y + (end.y - start.y) / 4)
        for (type, point) in [
            (NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, firstMovement),
            (.leftMouseDragged, middle), (.leftMouseDragged, end), (.leftMouseUp, end),
        ] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: Self.nextEventNumber(), clickCount: 1, pressure: 1))
            events.append(event)
        }
        // NSTextView may enter a nested tracking loop on mouse-down. Deliver the
        // complete gesture independently so mouse-up does not await this main-actor task.
        try await dispatch(events)
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
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: AnyView(WindowContent(model: model).defaultAppStorage(defaults)))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static var eventNumber = 10_000
    private static func nextEventNumber() -> Int {
        eventNumber += 1
        return eventNumber
    }

    @MainActor
    private final class InputReceipt {
        var events: [Int64: NSEvent] = [:]
    }

    private struct PointerInput: Sendable {
        let kind: UInt32
        let x: Double
        let y: Double
        let token: Int64
    }

    private func dispatch(_ events: [NSEvent]) async throws {
        try #require(NSApplication.shared.isRunning)
        let window = try #require(events.first?.window)
        try #require(window.isVisible)
        try #require(NSScreen.screens.count == 1, "The CI pointer fixture requires one owned display")
        try #require(CGPreflightPostEventAccess(), "CI native input requires existing event-posting permission")
        // Activate once before the complete gesture; never reactivate during a drag.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let activationDeadline = ContinuousClock.now + .seconds(2)
        while !NSApp.isActive || !window.isKeyWindow, ContinuousClock.now < activationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(NSApp.isActive && window.isKeyWindow && NSApp.keyWindow === window)
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let pid = getpid()
        let windowID = CGWindowID(window.windowNumber)
        let inputs = events.map { event in
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let kind: CGEventType =
                switch event.type {
                case .leftMouseDown: .leftMouseDown
                case .leftMouseDragged: .leftMouseDragged
                default: .leftMouseUp
                }
            return PointerInput(
                kind: kind.rawValue, x: point.x, y: screenHeight - point.y, token: Int64(event.eventNumber))
        }
        let receipt = InputReceipt()
        let monitor = try #require(
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { observed in
                MainActor.assumeIsolated {
                    if let cg = observed.cgEvent {
                        let token = cg.getIntegerValueField(.eventSourceUserData)
                        if inputs.contains(where: { $0.token == token }), observed.window === window {
                            receipt.events[token] = observed
                        }
                    }
                }
                return observed
            })
        defer { NSEvent.removeMonitor(monitor) }
        // Native NSTextView tracking can block the main event loop. Deliver the
        // bounded sequence independently, checking WindowServer ownership before every event.
        let delivery = Task.detached {
            for input in inputs {
                let point = CGPoint(x: input.x, y: input.y)
                guard Self.ownedPointerTarget(point, pid: pid, windowID: windowID) else { return false }
                if input.kind == CGEventType.leftMouseDown.rawValue {
                    guard
                        let move = CGEvent(
                            mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                            mouseButton: .left)
                    else { return false }
                    move.flags = []
                    move.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard let type = CGEventType(rawValue: input.kind),
                    let cg = CGEvent(
                        mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                else { return false }
                cg.flags = []
                cg.setIntegerValueField(.mouseEventClickState, value: 1)
                cg.setIntegerValueField(.eventSourceUserData, value: input.token)
                cg.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(80))
            }
            return true
        }
        try #require(await delivery.value, "Every pointer target must remain the owned CI window")
        let deadline = ContinuousClock.now + .seconds(2)
        while receipt.events.count != events.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        for (event, input) in zip(events, inputs) {
            let observed = try #require(
                receipt.events[input.token], "The app-host loop must receive every native input")
            #expect(observed.window === window)
            #expect(observed.type == event.type)
            let cg = try #require(observed.cgEvent)
            #expect(cg.getIntegerValueField(.eventSourceUserData) == input.token)
            #expect(cg.location == CGPoint(x: input.x, y: input.y))
            #expect(observed.modifierFlags.isEmpty)
        }
    }

    nonisolated private static func ownedPointerTarget(_ point: CGPoint, pid: pid_t, windowID: CGWindowID) -> Bool {
        guard
            let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        for record in records {
            guard (record[kCGWindowLayer as String] as? Int) == 0,
                let raw = record[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.contains(point)
            else { continue }
            return (record[kCGWindowOwnerPID as String] as? Int) == Int(pid)
                && (record[kCGWindowNumber as String] as? UInt32) == windowID
        }
        return false
    }

    private func trace(_ stage: String) {
        FileHandle.standardError.write(Data("REA-1351 hosted stage: \(stage)\n".utf8))
    }

    /// In-process accessibility uses AppKit's main-actor getters and press method.
    /// Self-AXUIElement tree lookup trapped in CI before reaching the actual action.
    /// The root is the owned fixture window; no posted input or permission override.
    private func pressOwnedAccessibility(_ identifier: String, in window: NSWindow) -> Int32 {
        var visited: Set<ObjectIdentifier> = []
        var matches: [NSObject] = []
        var roots: [NSWindow] = []
        func collect(_ root: NSWindow) {
            guard !roots.contains(where: { $0 === root }), roots.count < 16 else { return }
            roots.append(root)
            for child in root.childWindows ?? [] where child.isVisible { collect(child) }
        }
        collect(window)
        trace("owned parent/child accessibility roots: \(roots.map { String(describing: type(of: $0)) })")
        for root in roots {
            visitAccessibility(root, visited: &visited) { element in
                if accessibilityValue(in: element, selector: #selector(NSAccessibilityProtocol.accessibilityIdentifier))
                    as? String
                    == identifier, let object = element as? NSObject
                {
                    matches.append(object)
                }
            }
        }
        trace("AppKit accessibility matches for \(identifier): \(matches.count)")
        guard matches.count == 1 else { return AXError.noValue.rawValue }
        let object = matches[0]
        let action = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
        guard object.responds(to: action), let implementation = object.method(for: action) else {
            return AXError.actionUnsupported.rawValue
        }
        // SwiftUI's exported nodes support the public Objective-C method without
        // necessarily declaring the full NSAccessibilityProtocol. Preserve its BOOL
        // result with the declared C ABI rather than treating it as an object return.
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let press = unsafeBitCast(implementation, to: Press.self)
        let accepted = press(object, action)
        trace("AppKit accessibility press returned \(accepted)")
        return accepted ? AXError.success.rawValue : AXError.failure.rawValue
    }

    private func ownedAccessibilityValues() -> [String: String] {
        var values: [String: String] = [:]
        var visited: Set<ObjectIdentifier> = []
        for window in NSApp.windows where window.isVisible {
            visitAccessibility(window, visited: &visited) { element in
                guard
                    let identifier = accessibilityValue(
                        in: element, selector: #selector(NSAccessibilityProtocol.accessibilityIdentifier)) as? String
                else { return }
                values[identifier] =
                    accessibilityValue(
                        in: element, selector: #selector(NSAccessibilityProtocol.accessibilityValue)) as? String ?? ""
            }
        }
        return values
    }

    private func visitAccessibility(
        _ element: any NSObjectProtocol, visited: inout Set<ObjectIdentifier>,
        inspect: (any NSObjectProtocol) -> Void
    ) {
        guard visited.count < 1_024, visited.insert(ObjectIdentifier(element)).inserted else { return }
        inspect(element)
        let children =
            accessibilityValue(
                in: element, selector: #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any] ?? []
        for child in NSAccessibility.unignoredChildren(from: children) {
            if let child = child as? any NSObjectProtocol {
                visitAccessibility(child, visited: &visited, inspect: inspect)
            }
        }
    }

    private func host(_ model: AppModel, interactive: Bool = false) -> (window: NSWindow, view: NSView) {
        host(
            NSHostingView(
                rootView: SidebarView(model: model).environment(\.palette, Palette(theme: .sigilDark))),
            interactive: interactive)
    }

    private func host(_ view: NSView, size: NSSize = .init(width: 200, height: 460), interactive: Bool = false) -> (
        window: NSWindow, view: NSView
    ) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: interactive ? [.titled] : [.borderless], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = view
        if interactive {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderFront(nil)
        }
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

    private func accessibilityIdentifiers(
        in element: any NSObjectProtocol,
        visited: inout Set<ObjectIdentifier>,
        tree: inout [String]
    ) -> Set<String> {
        guard visited.count < 512 else {
            if !tree.contains("Accessibility tree exceeded the 512-object fixture bound") {
                tree.append("Accessibility tree exceeded the 512-object fixture bound")
            }
            return []
        }
        guard visited.insert(ObjectIdentifier(element)).inserted else { return [] }
        // AppKit accessibility supports these getters without formal NSAccessibilityProtocol conformance.
        let role =
            accessibilityValue(in: element, selector: #selector(NSAccessibilityProtocol.accessibilityRole))
            as? String
        let identifier =
            accessibilityValue(
                in: element, selector: #selector(NSAccessibilityProtocol.accessibilityIdentifier)) as? String
        let description =
            "\(type(of: element)): role=\(role ?? "nil"), id=\(identifier ?? "nil")"
        if !tree.contains(description) { tree.append(description) }
        var identifiers = Set(identifier.map { [$0] } ?? [])
        let children =
            accessibilityValue(
                in: element, selector: #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any] ?? []
        for child in NSAccessibility.unignoredChildren(from: children) {
            if let accessible = child as? any NSObjectProtocol {
                identifiers.formUnion(
                    accessibilityIdentifiers(
                        in: accessible, visited: &visited, tree: &tree))
            }
        }
        return identifiers
    }

    private func accessibilityValue(in element: any NSObjectProtocol, selector: Selector) -> Any? {
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }
}

@MainActor
private final class HoverProbe {
    var glide: SidebarGlide?
}

private struct AccessibilityControl: View {
    // Observe the real environment; do not enable assistive technology or override the value.
    // https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityenabled
    @Environment(\.accessibilityEnabled) private var accessibilityEnabled
    let observe: (Bool) -> Void

    var body: some View {
        VStack {
            Text("SwiftUI diagnostic text").accessibilityIdentifier("diagnostic-swiftui-text")
            Button("SwiftUI diagnostic button") {}.accessibilityIdentifier("diagnostic-swiftui-button")
        }
        .onAppear { observe(accessibilityEnabled) }
        .onChange(of: accessibilityEnabled) { _, enabled in observe(enabled) }
    }
}

/// This single hosted test needs only generated Grok rows and a fake executable.
@MainActor
private final class SidebarFixture {
    let root: URL
    let executable: URL
    let defaults: UserDefaults
    let settings: AppSettings
    let store: SessionStore
    let notesRoot: URL
    private let defaultsName = "SigilSidebarHostTests.\(UUID().uuidString)"
    private let oldGrokHome: String?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let grokHome = root.appendingPathComponent("grok-home")
        oldGrokHome = ProcessInfo.processInfo.environment["GROK_HOME"]
        setenv("GROK_HOME", grokHome.path, 1)
        executable = root.appendingPathComponent("fake-grok")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defaults = UserDefaults(suiteName: defaultsName)!
        settings = AppSettings(defaults: defaults)
        settings.showOtherAppSessions = true
        settings.executablePath = executable.path
        store = SessionStore(root: grokHome.appendingPathComponent("sessions"))
        notesRoot = root.appendingPathComponent("notes")
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func writeListedSession(id: String, cwd: String, summary title: String = "Session") throws {
        let directory = GrokPaths.sessionDirectory(cwd: cwd, sessionID: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let summary: [String: Any] = [
            "info": ["id": id, "cwd": cwd], "session_summary": title,
            "created_at": "2026-08-01T00:00:00Z", "updated_at": "2026-08-01T00:00:00Z",
            "num_chat_messages": 4,
        ]
        try JSONSerialization.data(withJSONObject: summary).write(
            to: directory.appendingPathComponent("summary.json"), options: .atomic)
    }

    func model() -> AppModel {
        settings.isTabMessagingEnabled = false
        settings.defaultDirectory = root.path
        return AppModel(
            settings: settings, store: store,
            trashConversation: { _ in }, presentError: { _ in },
            panel: RightPanel(defaults: defaults, notesStore: ConversationNotesStore(root: notesRoot)),
            pairingStore: InMemoryRemotePairingStore(),
            providerInstallations: [
                .grokBuild: ProviderInstallation(executable: executable, version: nil, problem: nil)
            ])
    }

    func cleanup() {
        if let oldGrokHome { setenv("GROK_HOME", oldGrokHome, 1) } else { unsetenv("GROK_HOME") }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
