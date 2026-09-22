import AppKit
import SigilKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var settingsError: String?
    @State private var pathDraft: ExecutablePathDraft
    @State private var listedModels = GrokModelCatalog.fallback
    @FocusState private var isExecutablePathFocused: Bool

    init(model: AppModel) {
        self.model = model
        _pathDraft = State(initialValue: ExecutablePathDraft(text: model.settings.executablePath))
    }

    var body: some View {
        TabView {
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
            general.tabItem { Label("General", systemImage: "gearshape") }
            RemoteControlView(model: model).tabItem { Label("Remote", systemImage: "iphone") }
        }
        .tint(Palette(theme: model.settings.theme).accent)
        .environment(\.palette, Palette(theme: model.settings.theme))
        .frame(width: 460)
        .scenePadding()
    }

    private var appearance: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ForEach(ThemeGrid.rows(TerminalTheme.all)) { row in
                        HStack(spacing: 8) {
                            ForEach(row.themes) { theme in
                                ThemeCard(
                                    theme: theme,
                                    isSelected: model.settings.theme.name == theme.name
                                ) {
                                    model.settings.themeName = theme.name
                                    model.applyTheme()
                                }
                            }
                            if row.themes.count < ThemeGrid.columns {
                                ForEach(0..<(ThemeGrid.columns - row.themes.count), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Theme")
            }

            LabeledContent("Font size") {
                HStack {
                    Slider(
                        value: Bindable(model.settings).fontSize,
                        in: 8...32,
                        step: 1
                    )
                    Text("\(Int(model.settings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
            .onChange(of: model.settings.fontSize) { _, _ in model.applyAppearance() }
            Text("Font size updates immediately. Changing the theme restarts the Grok tab so the TUI matches.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        Form {
            LabeledContent("Grok CLI") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("Path", text: $pathDraft.text)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .focused($isExecutablePathFocused)
                            // Commit on Return or focus loss only — never on each keystroke.
                            .onSubmit { applyExecutablePath() }
                            .onChange(of: isExecutablePathFocused) { _, focused in
                                if !focused { applyExecutablePath() }
                            }
                        Button("Choose…") { pickExecutable() }
                    }
                    Label(
                        draftExecutableExists ? "Found" : "Not found",
                        systemImage: draftExecutableExists
                            ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(draftExecutableExists ? .green : .red)
                }
            }

            Picker("Default model", selection: Bindable(model.settings).model) {
                Text("CLI default").tag("")
                ForEach(
                    GrokModelCatalog.choices(listed: listedModels, saved: model.settings.model),
                    id: \.self
                ) { name in
                    Text(name).monospaced().tag(name)
                }
            }

            Picker("Default effort", selection: Bindable(model.settings).effort) {
                ForEach(AppSettings.effortOptions, id: \.self) { option in
                    Text(AppSettings.effortLabel(option)).tag(option)
                }
            }

            Toggle(
                "Show one-message sessions in the sidebar",
                isOn: Bindable(model.settings).showEmptySessions
            )

            Toggle(
                "Show worktree sessions in the sidebar",
                isOn: Bindable(model.settings).showWorktreeSessions
            )

            Toggle(
                "Show subagent sessions in the sidebar",
                isOn: Bindable(model.settings).showSubagentSessions
            )

            Section {
                Toggle(
                    "Let tabs message each other",
                    isOn: tabMessagingIsOn
                )
                .disabled(
                    (BridgeRegistration.bundledMCPBinary == nil
                        && !model.settings.isTabMessagingEnabled)
                        || model.isTabMessagingChangeInProgress
                )
            } footer: {
                if let error = model.tabMessagingError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if BridgeRegistration.bundledMCPBinary != nil {
                    Text("Applies to tabs opened after this change.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let found = await GrokModelCatalog.load(executable: model.settings.executableURL)
            if !found.isEmpty { listedModels = found }
        }
        .alert(
            "Could not update Settings",
            isPresented: Binding(
                get: { settingsError != nil },
                set: { if !$0 { settingsError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(settingsError ?? "")
        }
    }

    private var tabMessagingIsOn: Binding<Bool> {
        Binding(
            get: { model.settings.isTabMessagingEnabled },
            set: { applyTabMessaging(enabled: $0) }
        )
    }

    private func applyTabMessaging(enabled: Bool) {
        guard enabled != model.settings.isTabMessagingEnabled else { return }
        Task {
            do {
                try await model.setTabMessaging(enabled: enabled)
            } catch {
                settingsError = error.localizedDescription
            }
        }
    }

    private var draftExecutableExists: Bool {
        AppSettings.isExecutableFile(
            at: URL(fileURLWithPath: AppSettings.normalizedExecutablePath(pathDraft.text)))
    }

    private func applyExecutablePath() {
        switch pathDraft.commit(stored: model.settings.executablePath) {
        case .rejected:
            settingsError = "Choose an executable file."
        case .unchanged:
            break
        case .applied(let path):
            model.settings.executablePath = path
            Task { await model.executableConfigurationChanged() }
        }
    }

    private func pickExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: pathDraft.text)
            .deletingLastPathComponent()
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            pathDraft.text = url.path
            applyExecutablePath()
        }
    }
}

/// Theme swatches in a fixed column count so Form can measure the stack.
enum ThemeGrid {
    static let columns = 4

    struct Row: Identifiable {
        let id: Int
        let themes: [TerminalTheme]
    }

    static func rows(_ themes: [TerminalTheme]) -> [Row] {
        stride(from: 0, to: themes.count, by: columns).enumerated().map { index, start in
            Row(id: index, themes: Array(themes[start..<min(start + columns, themes.count)]))
        }
    }
}

/// One theme as a selectable swatch: its ground, its accent dot, its name.
/// Appearance is a visual choice, so the picker shows the thing itself.
private struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var colors: Palette { Palette(theme: theme) }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(colors.ground)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        Circle()
                            .fill(colors.accent)
                            .frame(width: 6, height: 6)
                            .padding(5)
                    }
                    .overlay(alignment: .topTrailing) {
                        // Three text steps, so the ramp reads at a glance.
                        VStack(alignment: .trailing, spacing: 2) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(colors.text)
                                .frame(width: 22, height: 3)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(colors.textDim)
                                .frame(width: 14, height: 3)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(colors.textFaint)
                                .frame(width: 18, height: 3)
                        }
                        .padding(5)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(
                                isSelected ? palette.text : palette.hairline,
                                lineWidth: 1
                            )
                    )
                    .scaleEffect(isHovering && !isSelected && !reduceMotion ? 1.03 : 1)
                Text(theme.name)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? palette.text : palette.textDim)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help("Use the \(theme.name) terminal theme")
    }
}

/// Local Grok CLI path text. Call `commit` from Return or focus loss only.
struct ExecutablePathDraft: Equatable {
    var text: String

    enum Outcome: Equatable {
        case applied(String)
        case unchanged
        case rejected
    }

    @MainActor
    func commit(stored: String) -> Outcome {
        let path = AppSettings.normalizedExecutablePath(text)
        guard AppSettings.isExecutableFile(at: URL(fileURLWithPath: path)) else {
            return .rejected
        }
        guard path != stored else { return .unchanged }
        return .applied(path)
    }
}
