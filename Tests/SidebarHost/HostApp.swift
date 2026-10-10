import SwiftUI

/// CI-only launch scene. SwiftUI's App.main owns normal AppKit startup and event processing.
/// The hosted test creates its own isolated models; this scene starts no provider or history work.
@main
struct SidebarFixtureHost: App {
    var body: some Scene {
        WindowGroup {
            Text("Sigil sidebar fixture host").frame(width: 320, height: 120)
        }
    }
}
