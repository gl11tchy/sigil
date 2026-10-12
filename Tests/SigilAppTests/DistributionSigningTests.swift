import AppKit
import Foundation
import Testing

@testable import SigilApp

struct DistributionSigningTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repo.appendingPathComponent(path))
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The hardened runtime denies these without asking, whatever Info.plist says.
    @Test(arguments: [
        ("NSAppleEventsUsageDescription", "com.apple.security.automation.apple-events"),
        ("NSCameraUsageDescription", "com.apple.security.device.camera"),
        ("NSMicrophoneUsageDescription", "com.apple.security.device.audio-input"),
        ("NSContactsUsageDescription", "com.apple.security.personal-information.addressbook"),
        ("NSCalendarsUsageDescription", "com.apple.security.personal-information.calendars"),
        ("NSLocationUsageDescription", "com.apple.security.personal-information.location"),
        ("NSPhotoLibraryUsageDescription", "com.apple.security.personal-information.photos-library"),
    ])
    func everyPurposeStringHasItsHardenedRuntimeEntitlement(usageKey: String, entitlement: String) throws {
        let info = try Self.plist("Resources/Info.plist")
        let entitlements = try Self.plist("Resources/Sigil.entitlements")
        #expect(info[usageKey] is String)
        #expect(entitlements[entitlement] as? Bool == true)
    }

    @Test func distributionBuildSignsTheAppWithTheEntitlements() throws {
        let script = try String(
            contentsOf: Self.repo.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8)
        let hardened = script.components(separatedBy: "--options runtime").dropFirst()
        #expect(hardened.filter { $0.hasPrefix(" --timestamp --entitlements \"$ENTITLEMENTS\"") }.count == 2)
    }

    @Test func bundleBuildWritesTheFullSourceIdentity() throws {
        let script = try String(
            contentsOf: Self.repo.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("build-identity.py\" source \"$ROOT\""))
        #expect(script.contains("plutil -insert SigilCommit -string \"$commit\""))
        let workflow = try String(
            contentsOf: Self.repo.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        #expect(workflow.contains("fetch-depth: 0"))
        #expect(workflow.contains("SIGIL_BUILD: ${{ github.run_number }}.${{ github.run_attempt }}"))
        #expect(workflow.contains("build-identity.py publish dist/Sigil.zip"))
    }

    @Test(arguments: [
        (String(repeating: "a", count: 40), "aaaaaaa"),
        (String(repeating: "b", count: 40) + "-dirty", "bbbbbbb-dirty"),
        ("unknown", "unknown"),
        ("not-a-commit", "unknown"),
    ])
    func aboutIdentityRetainsBuildAndSourceState(commit: String, short: String) {
        let identity = AppBuildIdentity(info: [
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "548.1", "SigilCommit": commit,
        ])
        #expect(identity.commit == commit)
        #expect(identity.shortCommit == short)
        #expect(identity.aboutPanelOptions[.applicationVersion] as? String == "1.0.0")
        #expect(identity.aboutPanelOptions[.version] as? String == "548.1, \(short)")
    }

    @Test func missingBundleIdentityIsUnknown() {
        let identity = AppBuildIdentity(info: [:])
        #expect(identity.version == "unknown")
        #expect(identity.build == "unknown")
        #expect(identity.shortCommit == "unknown")
    }

    @Test func aboutMenuKeepsUpdatesAndCloseCommands() throws {
        let source = try String(
            contentsOf: Self.repo.appendingPathComponent("Sources/SigilApp/SigilApp.swift"), encoding: .utf8)
        #expect(source.contains("CommandGroup(replacing: .appInfo)"))
        #expect(source.contains("Button(\"About Sigil\") { Self.showAboutPanel() }"))
        #expect(source.contains("CommandGroup(after: .appInfo)"))
        #expect(source.contains("Button(\"Check for Updates…\")"))
        #expect(source.contains("Button(\"Close Tab\") { launch.whenReady(Self.closeTabOrKeyWindow) }"))
    }

    @MainActor
    @Test func nativeAboutPanelShowsIdentityAndClosePreservesTabs() throws {
        _ = NSApplication.shared
        let fixture = try ModelFixture(script: "#!/bin/sh\nread line\n")
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: try fixture.directory("project")))
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        GrokCommands.showAboutPanel(
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
        panel.makeKeyAndOrderFront(nil)
        #expect(NSApp.keyWindow === panel)
        GrokCommands.closeTabOrKeyWindow(model)
        #expect(!panel.isVisible)
        #expect(model.tabs.map(\.id) == [tab.id])
    }
}
