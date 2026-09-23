import AppKit
import Foundation
import Testing

@testable import SigilApp

@Suite(.serialized)
@MainActor
struct AppShellTests {
    @Test func launchTurnsOffNativeWindowTabs() {
        let before = NSWindow.allowsAutomaticWindowTabbing
        defer { NSWindow.allowsAutomaticWindowTabbing = before }
        NSWindow.allowsAutomaticWindowTabbing = true

        AppDelegate.turnOffWindowTabbing()

        #expect(!NSWindow.allowsAutomaticWindowTabbing)
    }
}
