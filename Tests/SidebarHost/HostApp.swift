import SwiftUI

/// CI-only launch scene. SwiftUI's App.main owns normal AppKit startup and event processing.
/// The hosted test creates its own isolated models; this scene starts no provider or history work.
@main
struct SidebarFixtureHost: App {
    var body: some Scene {
        WindowGroup {
            Text("Sigil sidebar fixture host").frame(width: 320, height: 120)
        }
        // Production SidebarView reads the native openSettings environment. Match
        // the app's scene contract without constructing a default model or reading history.
        Settings {
            Text("Sigil sidebar fixture settings").frame(width: 320, height: 120)
        }
    }
}
