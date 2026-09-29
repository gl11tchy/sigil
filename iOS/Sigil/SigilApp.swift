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
                // Native controls draw words in the tint, so it is the text accent.
                .tint(Theme.accentInk)
                // The chrome follows the Mac's terminal theme, as the Mac's own
                // appearance does; before a theme arrives, the system's.
                .preferredColorScheme(appearance)
                .task { AlertsController.attach(store) }
                .onOpenURL { url in
                    // A widget or notification link only chooses a session.
                    guard url.scheme == "sigilremote", url.host == "session",
                        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                        let tab = items.first(where: { $0.name == "tab" })?.value
                    else { return }
                    store.open(tabID: tab, macID: items.first(where: { $0.name == "mac" })?.value)
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

    private var appearance: ColorScheme? {
        ThemeMetrics.isDark(ground: store.appearanceGround).map { $0 ? .dark : .light }
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
        .overlay {
            // The launch screen's plain ground over an empty Mac, until the cached screen lands.
            if store.awaitingCache { Color(uiColor: .systemBackground).ignoresSafeArea() }
        }
        .themeAnimation(.snappy, value: store.hasPairing)
    }
}
