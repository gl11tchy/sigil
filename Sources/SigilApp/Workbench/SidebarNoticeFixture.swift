#if DEBUG
    import AppKit
    import Foundation
    import Observation
    import SwiftUI
    import SigilKit

    /// An isolated native fixture for the production sidebar. It starts no real CLI,
    /// accesses no credentials and reads only the caller's generated temporary home.
    @MainActor
    enum SidebarNoticeFixture {
        static let controls = SidebarNoticeFixtureControlsState()
        private static var probe: SidebarNoticeFixtureProbe?
        static func change(_ mode: String, model: AppModel) async {
            probe?.setMode(mode)
            await model.refreshProviderInstallations(force: true)
        }

        static var requested: Bool {
            ProcessInfo.processInfo.environment["SIGIL_SIDEBAR_NOTICE_FIXTURE"] == "1"
        }

        static func makeModel() -> AppModel {
            let environment = ProcessInfo.processInfo.environment
            let home = URL(fileURLWithPath: environment["HOME"] ?? "").standardizedFileURL
            precondition(home.lastPathComponent.hasPrefix("sigil-rea1351-"))
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
            let count = Int(environment["SIGIL_SIDEBAR_NOTICE_COUNT"] ?? "3") ?? 3
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
            let box = SidebarNoticeFixtureProbe(home: home, installations: installations)
            probe = box
            let fixtureInstallations = installations
            let historyRoot = home.appendingPathComponent(
                environment["SIGIL_SIDEBAR_READ_ERROR"] == "1" ? "not-a-directory" : ".grok/sessions")
            let store = SessionStore(root: historyRoot, includesNativeHistory: true)
            let model = AppModel(
                settings: settings, store: store, trashConversation: { _ in }, presentError: { _ in },
                tabMessagingSocketURL: home.appendingPathComponent("fixture.sock"),
                panel: RightPanel(
                    defaults: defaults, notesStore: ConversationNotesStore(root: home.appendingPathComponent("notes"))),
                pairingStore: InMemoryRemotePairingStore(), kimiKeyStore: InMemoryKimiKeyStore(),
                providerInstallations: fixtureInstallations,
                providerProbe: { provider, _ in
                    box.installation(provider)
                })
            model.openRecents()
            return model
        }
    }
    @MainActor @Observable
    final class SidebarNoticeFixtureControlsState {
        var reduceMotion = false
    }

    private final class SidebarNoticeFixtureProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let home: URL
        private let initial: [CLIProvider: ProviderInstallation]
        private var mode: String?
        init(home: URL, installations: [CLIProvider: ProviderInstallation]) {
            self.home = home
            initial = installations
        }
        func setMode(_ mode: String) { lock.withLock { self.mode = mode } }
        func installation(_ provider: CLIProvider) -> ProviderInstallation {
            lock.withLock {
                guard let mode, let checked = provider.checkedVersion else {
                    return initial[provider]
                        ?? .init(executable: nil, version: nil, problem: "Not installed in fixture")
                }
                if mode == "unavailable" {
                    return .init(executable: nil, version: nil, problem: "Generated fixture CLI is unavailable")
                }
                var version = checked
                if mode == "three" || (mode == "one" && provider == .codex) {
                    version = [.claudeCode: "2.1.296", .codex: "0.160.0", .grokBuild: "1.0.50"][provider] ?? checked
                }
                if mode == "unsupported" && provider == .codex { version = "1.0.0" }
                return .init(
                    executable: home.appendingPathComponent("bin/\(provider.command)"), version: version, problem: nil)
            }
        }
    }

    struct SidebarNoticeFixtureControls: View {
        let model: AppModel
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Generated fixture controls").font(.system(size: 11))
                HStack {
                    ForEach(["zero", "one", "three"], id: \.self) { mode in
                        Button("\(mode) (fixture)") { Task { await SidebarNoticeFixture.change(mode, model: model) } }
                    }
                }
                HStack {
                    ForEach(["unavailable", "unsupported"], id: \.self) { mode in
                        Button("\(mode) (fixture)") { Task { await SidebarNoticeFixture.change(mode, model: model) } }
                    }
                }
                HStack {
                    Button("Light (fixture)") { appearance(.sigilLight) }
                    Button("Dark (fixture)") { appearance(.sigilDark) }
                }
                Toggle("Reduce Motion (fixture)", isOn: Bindable(SidebarNoticeFixture.controls).reduceMotion)
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
    }
#endif
