import AppKit
import SigilKit
import Testing

@testable import SigilApp

/// CI-only: the real SwiftUI app host supplies AppKit activation and event processing.
@Suite(.serialized)
@MainActor
struct AboutBuildIdentityHostTests {
    @Test func nativeAboutPanelShowsIdentityAndClosePreservesTabs() async throws {
        try #require(NSApp.isRunning, "About requires the real app-host event loop")
        let fixture = try AboutFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: fixture.root))
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        AppWindowCommands.showAboutPanel(
            identity: AppBuildIdentity(info: [
                "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "548.1",
                "SigilCommit": String(repeating: "a", count: 40),
            ]))
        let panel = try #require(NSApp.windows.first { !previous.contains(ObjectIdentifier($0)) && $0.isVisible })
        defer { panel.orderOut(nil) }
        func strings(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
            return own + view.subviews.flatMap(strings)
        }
        let text = strings(try #require(panel.contentView)).joined(separator: " ")
        #expect(text.contains("1.0.0"))
        #expect(text.contains("548.1"))
        #expect(text.contains("aaaaaaa"))
        // Match the existing interactive app-host driver: the passive
        // activation request leaves Xcode's test runner in front on macOS26.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while !NSApp.isActive || !panel.isKeyWindow || NSApp.keyWindow !== panel,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(
            NSApp.isActive && panel.isKeyWindow && NSApp.keyWindow === panel,
            "About key-window precondition: active=\(NSApp.isActive), canBecomeKey=\(panel.canBecomeKey)")
        AppWindowCommands.closeTabOrKeyWindow(model)
        #expect(!panel.isVisible)
        #expect(model.tabs.map(\.id) == [tab.id])
        print(
            "REA-1230 About app-host: running=\(NSApp.isRunning), version/build/commit displayed, key About closed, tab preserved"
        )
    }
}

@MainActor
private final class AboutFixture {
    let root: URL
    private let defaultsName = "SigilAboutHostTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let settings: AppSettings
    private let store: SessionStore
    private let executable: URL
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
        settings.executablePath = executable.path
        settings.defaultDirectory = root.path
        settings.isTabMessagingEnabled = false
        store = SessionStore(root: grokHome.appendingPathComponent("sessions"))
    }

    func model() -> AppModel {
        AppModel(
            settings: settings, store: store, trashConversation: { _ in }, presentError: { _ in },
            panel: RightPanel(
                defaults: defaults, notesStore: ConversationNotesStore(root: root.appendingPathComponent("notes"))),
            pairingStore: InMemoryRemotePairingStore(),
            providerInstallations: [
                .grokBuild: ProviderInstallation(executable: executable, version: "1.0.40", problem: nil)
            ])
    }

    func cleanup() {
        if let oldGrokHome { setenv("GROK_HOME", oldGrokHome, 1) } else { unsetenv("GROK_HOME") }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
