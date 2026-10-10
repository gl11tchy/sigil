import AppKit
import ApplicationServices
import SwiftUI
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct SidebarVersionNoticeTests {
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
        let notices = host(newer)
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
        #expect(abs(noticeViewport.minY - baselineViewport.minY) < 1)
        #expect(abs(noticeViewport.height - baselineViewport.height) < 1)
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
        for provider in [CLIProvider.claudeCode, .codex, .grokBuild] {
            #expect(
                identifiers.contains("sidebar-\(provider.rawValue)-version-notice"),
                "Exported accessibility tree: \(tree). \(diagnostic)")
        }
    }

    private func host(_ model: AppModel) -> (window: NSWindow, view: NSView) {
        host(
            NSHostingView(
                rootView: SidebarView(model: model).environment(\.palette, Palette(theme: .sigilDark))))
    }

    private func host(_ view: NSView) -> (window: NSWindow, view: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
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

    func writeListedSession(id: String, cwd: String) throws {
        let directory = GrokPaths.sessionDirectory(cwd: cwd, sessionID: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let summary: [String: Any] = [
            "info": ["id": id, "cwd": cwd], "session_summary": "Session",
            "created_at": "2026-08-01T00:00:00Z", "updated_at": "2026-08-01T00:00:00Z",
            "num_chat_messages": 4,
        ]
        try JSONSerialization.data(withJSONObject: summary).write(
            to: directory.appendingPathComponent("summary.json"), options: .atomic)
    }

    func cleanup() {
        if let oldGrokHome { setenv("GROK_HOME", oldGrokHome, 1) } else { unsetenv("GROK_HOME") }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
