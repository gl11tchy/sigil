#if DEBUG
    import AppKit
    import Foundation
    import Observation
    import SigilKit
    import SwiftUI

    /// Only the generated, renamed native fixture uses this factory and its measurements.
    @MainActor
    enum SidebarTitleFixture {
        static let now = Date(timeIntervalSince1970: 1_791_831_600)
        static let measurements = SidebarTitleFixtureMeasurements()
        static var requested: Bool {
            ProcessInfo.processInfo.environment["SIGIL_SIDEBAR_TITLE_FIXTURE"] == "1"
        }
        static func makeModel() -> AppModel {
            let environment = ProcessInfo.processInfo.environment
            let home = URL(fileURLWithPath: environment["HOME"] ?? "").standardizedFileURL
            precondition(home.lastPathComponent.hasPrefix("sigil-rea1247-"))
            precondition(home.path.hasPrefix("/tmp/") || home.path.hasPrefix("/private/tmp/"))
            precondition(environment["CFFIXED_USER_HOME"] == environment["HOME"])
            precondition(environment["XCTestConfigurationFilePath"] != nil)
            let defaults = UserDefaults.standard
            let settings = AppSettings(defaults: defaults)
            settings.isTabMessagingEnabled = false
            settings.showOtherAppSessions = true
            settings.showWorktreeSessions = true
            settings.defaultDirectory = home.appendingPathComponent("project").path
            settings.executablePath = home.appendingPathComponent("bin/grok").path
            settings.themeName =
                (environment["SIGIL_SIDEBAR_APPEARANCE"] == "light" ? TerminalTheme.sigilLight : .sigilDark).name
            let width = Double(environment["SIGIL_SIDEBAR_WIDTH"] ?? "272") ?? 272
            defaults.set(min(430, max(200, width)), forKey: "window.sidebarWidth")
            let count = 0
            let newer: [CLIProvider: String] = [.claudeCode: "2.1.296", .codex: "0.160.0", .grokBuild: "1.0.50"]
            var installations: [CLIProvider: ProviderInstallation] = [:]
            for provider in CLIProvider.allCases {
                guard let checked = provider.checkedVersion else {
                    installations[provider] = .init(executable: nil, version: nil, problem: "Not installed in fixture")
                    continue
                }
                let version = count == 3 || (count == 1 && provider == .codex) ? newer[provider] : checked
                installations[provider] = .init(
                    executable: home.appendingPathComponent("bin/\(provider.command)"), version: version, problem: nil)
            }
            let fixtureInstallations = installations
            let historyRoot = home.appendingPathComponent(".grok/sessions")
            let store = SessionStore(root: historyRoot, includesNativeHistory: true)
            let model = AppModel(
                settings: settings, store: store, trashConversation: { _ in }, presentError: { _ in },
                tabMessagingSocketURL: home.appendingPathComponent("fixture.sock"),
                panel: RightPanel(
                    defaults: defaults, notesStore: ConversationNotesStore(root: home.appendingPathComponent("notes"))),
                pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(),
                providerInstallations: fixtureInstallations,
                providerProbe: { provider, _ in
                    fixtureInstallations[provider]
                        ?? .init(executable: nil, version: nil, problem: "Fixture unavailable")
                })
            model.openRecents()
            return model
        }
    }

    @MainActor @Observable
    final class SidebarTitleFixtureMeasurements {
        var frames: [String: CGRect] = [:]
    }

    struct SidebarTitleFixtureMeasure: View {
        let key: String
        var body: some View {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { SidebarTitleFixture.measurements.frames[key] = frame }
                    .onChange(of: frame) { _, newFrame in
                        SidebarTitleFixture.measurements.frames[key] = newFrame
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    struct SidebarTitleFixtureControls: View {
        let model: AppModel
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Generated REA-1247 fixture")
                HStack {
                    Button("Light (fixture)") { appearance(.sigilLight) }
                    Button("Dark (fixture)") { appearance(.sigilDark) }
                }
                HStack {
                    ForEach([200, 272, 430], id: \.self) { width in
                        Button("\(width)pt (fixture)") {
                            UserDefaults.standard.set(Double(width), forKey: "window.sidebarWidth")
                        }
                    }
                }
                Button("Pin Wide (fixture)") {
                    if let session = model.store.sessions.first(where: { $0.summary.hasPrefix("WWWW") }) {
                        model.togglePin(session)
                    }
                }
                HStack {
                    Button("Search Wide (fixture)") { model.searchText = "WWWW" }
                    Button("Clear Search (fixture)") { model.searchText = "" }
                }
                Button("Working (fixture)") {
                    if let session = model.store.sessions.first(where: { $0.summary.hasPrefix("修复") }) {
                        model.open(session)
                        model.selectedTab?.noteTurnStarted()
                        model.openRecents()
                    }
                }
                Button("Clear Working (fixture)") { model.closeAllTabsAndWait() }
                Button("Record frames (fixture)") { record() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11))
            .frame(width: 280, alignment: .leading)
            .padding(8)
            .background(.regularMaterial)
            .padding(14)
        }
        private func appearance(_ theme: TerminalTheme) {
            model.settings.themeName = theme.name
            NSApp.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        }
        private func record() {
            let frames = SidebarTitleFixture.measurements.frames.mapValues { frame in
                ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            }
            let data = try! JSONSerialization.data(withJSONObject: frames, options: [.sortedKeys])
            let home = FileManager.default.homeDirectoryForCurrentUser
            try! data.write(to: home.appendingPathComponent("row-frames.json"), options: .atomic)
        }
    }
#endif
