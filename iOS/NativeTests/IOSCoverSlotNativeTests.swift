import SwiftUI
import UIKit

/// What the session screen's content shows, set by the test.
@MainActor
final class NativeScreen: ObservableObject {
    @Published var tabs = false
    @Published var output = false
    @Published var cover: CGRect?
}

/// The session screen's frame, as `SessionScreen` builds it: the content changes
/// branch as tabs and output land, and the composer sits in the bottom inset.
private struct NativeSessionScreen: View {
    @ObservedObject var screen: NativeScreen

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CoverSlot {
                        if screen.tabs { Color.gray.frame(height: 102) }
                    } changed: {
                        screen.cover = $0
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !screen.tabs {
            ContentUnavailableView("Reconnecting", systemImage: "terminal")
        } else if !screen.output {
            ContentUnavailableView("Ready when you are.", systemImage: "text.cursor")
        } else {
            OutputView(
                styled: StyledText(text: "row\n", spans: []), palette: [], foreground: "", background: "",
                revision: 1, highlight: "", onNearTop: {}, atBottom: .constant(true), scrollToEnd: 0,
                coverTop: screen.cover?.minY
            )
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

extension IOSOutputNativeTests {
    /// Tabs that land after the screen is up: from the cache, from live state or
    /// from another Mac. SwiftUI builds the composer again as the content changes
    /// and drops the first copy a moment later; the cover must stay the composer's.
    static func aDroppedComposerKeepsTheCover() async throws {
        let scene = try Expect.notNil(
            UIApplication.shared.connectedScenes.first as? UIWindowScene, "the app has a scene")
        let previous = scene.keyWindow
        let screen = NativeScreen()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NativeSessionScreen(screen: screen))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        // Long enough for a dropped copy to go: it went about 10ms after the new one came.
        func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

        try await settle()
        try Expect.true(screen.cover == nil, "no tabs, no composer, no cover")
        for (label, steps) in [
            ("cache: tabs and output at once", [(true, true)]),
            ("live: tabs first, output a moment later", [(true, false), (true, true)]),
        ] {
            screen.tabs = false
            screen.output = false
            try await settle()
            try Expect.true(screen.cover == nil, "\(label): the composer goes with the tabs")
            for (tabs, output) in steps {
                screen.tabs = tabs
                screen.output = output
                try await settle()
                let cover = try Expect.notNil(screen.cover, "\(label): the composer covers the output")
                try Expect.equal(cover.height, 102, "\(label): the cover is the composer's")
            }
        }
    }
}
