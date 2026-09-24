import SwiftUI

enum AppInfo {
    static let displayName = "Sigil"
}

@main
struct SigilApp: App {
    @UIApplicationDelegateAdaptor(AlertsController.self) private var alerts
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = RemoteStore(isDemo: Self.isDemo)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.accent)
                // Sigil sits beside a terminal at night; the phone matches the Mac.
                .preferredColorScheme(.dark)
                .task { AlertsController.attach(store) }
                .onOpenURL { url in
                    // A widget or notification link only chooses a session.
                    guard url.scheme == "sigilremote", url.host == "session",
                        let tab = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                            .first(where: { $0.name == "tab" })?.value
                    else { return }
                    store.open(tabID: tab)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.enterForeground()
            case .background: store.enterBackground()
            default: break
            }
        }
    }

    /// Offline demo mode, so every screen can be screenshotted with no Mac.
    /// Compiled out of release builds.
    private static var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        false
        #endif
    }
}

struct RootView: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        Group {
            if store.hasPairing {
                SessionScreen()
            } else {
                PairView()
            }
        }
        .themeAnimation(.snappy, value: store.hasPairing)
    }
}
