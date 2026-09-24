import AppKit
import SigilKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var settingsError: String?
    @State private var pathDraft: ExecutablePathDraft
    @State private var listedModels = GrokModelCatalog.fallback
    @State private var tabMessagingSwitch = TabMessagingSwitch()
    @FocusState private var isExecutablePathFocused: Bool

    init(model: AppModel) {
        self.model = model
        _pathDraft = State(initialValue: ExecutablePathDraft(text: model.settings.executablePath))
    }

    private var palette: Palette { Palette(theme: model.settings.theme) }

    var body: some View {
        TabView {
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
            general.tabItem { Label("General", systemImage: "gearshape") }
            RemoteControlView(model: model).tabItem { Label("Remote", systemImage: "iphone") }
        }
        .tint(palette.accent)
        .environment(\.palette, palette)
        .frame(width: 540)
    }

    private var appearance: some View {
        SettingsPage(minHeight: 620) {
            SettingsSection(
                title: "Theme",
                footer:
                    "Sigil Dark and Sigil Light match the window. Changing the theme restarts idle Grok tabs so the TUI matches."
            ) {
                VStack(spacing: 10) {
                    ForEach(ThemeGrid.rows(TerminalTheme.all)) { row in
                        HStack(spacing: 10) {
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
                .padding(12)
            }

            SettingsSection(title: "Terminal") {
                SettingsRow(label: "Font size") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Bindable(model.settings).fontSize,
                            in: 8...32,
                            step: 1
                        )
                        .frame(width: 180)
                        Text("\(Int(model.settings.fontSize)) pt")
                            .mono(12)
                            .foregroundStyle(palette.ink2)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .onChange(of: model.settings.fontSize) { _, _ in model.applyAppearance() }
        }
    }

    private var general: some View {
        SettingsPage(minHeight: 620) {
            SettingsSection(
                title: "New sessions",
                footer:
                    "In a git repository, a new session gets its own worktree and branch. Turn this off to work in the project folder."
            ) {
                SettingsRow(label: "Default CLI") {
                    Picker("Default CLI", selection: Bindable(model.settings).defaultProvider) {
                        ForEach(CLIProvider.allCases) { provider in
                            Text(provider.name).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsDivider()
                SettingsToggle(
                    "Start in a new worktree",
                    isOn: Bindable(model.settings).startsInWorktree
                )
            }

            SettingsSection(title: "Grok CLI") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        FieldFrame(isFocused: isExecutablePathFocused, height: 28) {
                            TextField("", text: $pathDraft.text, prompt: Text("Path").foregroundStyle(palette.ink2))
                                .textFieldStyle(.plain)
                                .mono(12)
                                .foregroundStyle(palette.ink)
                                .focused($isExecutablePathFocused)
                                // Commit on Return or focus loss only — never on each keystroke.
                                .onSubmit { applyExecutablePath() }
                                .onChange(of: isExecutablePathFocused) { _, focused in
                                    if !focused { applyExecutablePath() }
                                }
                                .accessibilityLabel("Grok CLI path")
                        }
                        Button("Choose…") { pickExecutable() }
                            .buttonStyle(SigilButtonStyle(kind: .secondary, height: 28))
                    }
                    HStack(spacing: 6) {
                        Image(
                            systemName: draftExecutableExists
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 11))
                        Text(draftExecutableExists ? "Found" : "Not found")
                            .ui(12, .medium)
                    }
                    .foregroundStyle(draftExecutableExists ? palette.greenInk : palette.redInk)
                }
                .padding(12)
                SettingsDivider()
                SettingsRow(label: "Default model") {
                    Picker("Default model", selection: modelSelection) {
                        Text("CLI default").tag("")
                        ForEach(
                            GrokModelCatalog.choices(
                                listed: listedModels, saved: model.settings.model),
                            id: \.self
                        ) { name in
                            Text(name).monospaced().tag(name)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsDivider()
                SettingsRow(label: "Default effort") {
                    Picker("Default effort", selection: Bindable(model.settings).effort) {
                        ForEach(AppSettings.effortOptions, id: \.self) { option in
                            Text(AppSettings.effortLabel(option)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection(title: "Sidebar") {
                SettingsToggle(
                    "Show one-message sessions",
                    isOn: Bindable(model.settings).showEmptySessions
                )
                SettingsDivider()
                SettingsToggle(
                    "Show worktree sessions",
                    isOn: Bindable(model.settings).showWorktreeSessions
                )
                SettingsDivider()
                SettingsToggle(
                    "Show subagent sessions",
                    isOn: Bindable(model.settings).showSubagentSessions
                )
            }

            SettingsSection(title: "Keyboard") {
                SettingsToggle("Use Option as Meta key", isOn: Bindable(model.settings).optionAsMetaKey)
                    .onChange(of: model.settings.optionAsMetaKey) { _, _ in model.applyOptionAsMetaKey() }
            }

            SettingsSection(title: "Tabs", footer: tabMessagingFooter) {
                SettingsRow(label: "Let tabs message each other") {
                    HStack(spacing: 8) {
                        if model.isTabMessagingChangeInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Toggle("Let tabs message each other", isOn: tabMessagingIsOn)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
                .disabled(
                    (BridgeRegistration.bundledMCPBinary == nil
                        && !model.settings.isTabMessagingEnabled)
                        || model.isTabMessagingChangeInProgress
                )
            }
            if let error = model.tabMessagingError {
                Text(error)
                    .ui(12)
                    .foregroundStyle(palette.redInk)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { normalizeStoredModel() }
        .task(id: model.settings.executablePath) {
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

    private var tabMessagingFooter: String? {
        guard model.tabMessagingError == nil, BridgeRegistration.bundledMCPBinary != nil else {
            return nil
        }
        return "Applies to tabs opened after this change."
    }

    private var tabMessagingIsOn: Binding<Bool> {
        Binding(
            get: { tabMessagingSwitch.isOn(saved: model.settings.isTabMessagingEnabled) },
            set: { applyTabMessaging(enabled: $0) }
        )
    }

    private func applyTabMessaging(enabled: Bool) {
        guard tabMessagingSwitch.request(enabled, saved: model.settings.isTabMessagingEnabled) else {
            return
        }
        Task {
            do {
                try await model.setTabMessaging(enabled: enabled)
            } catch {
                settingsError = error.localizedDescription
            }
            tabMessagingSwitch.finish()
        }
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { GrokModelCatalog.normalized(model.settings.model) },
            set: { model.settings.model = $0 }
        )
    }

    private func normalizeStoredModel() {
        let clean = GrokModelCatalog.normalized(model.settings.model)
        if model.settings.model != clean { model.settings.model = clean }
    }

    private var draftExecutableExists: Bool {
        AppSettings.isExecutableFile(
            at: URL(fileURLWithPath: AppSettings.normalizedExecutablePath(pathDraft.text)))
    }

    private func applyExecutablePath() {
        apply(pathDraft.commit(stored: model.settings.executablePath))
    }

    private func apply(_ outcome: ExecutablePathDraft.Outcome) {
        switch outcome {
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
            apply(pathDraft.pick(url, stored: model.settings.executablePath))
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

/// One theme as a selectable swatch: a small screen in its own colours with
/// three lines of text in its ramp, and its name below.
private struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                VStack(alignment: .leading, spacing: 3) {
                    line(theme.accentHex, width: 18)
                    line(theme.foregroundHex, width: 30)
                    HStack(spacing: 3) {
                        line(theme.ansiHex[2], width: 10)
                        line(theme.ansiHex[4], width: 14)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .background(shape.fill(Palette.color(theme.backgroundHex)))
                .overlay(
                    shape.strokeBorder(
                        isSelected ? palette.accent : (isHovering ? palette.lineStrong : palette.ring),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
                Text(theme.name)
                    .ui(12, isSelected ? .medium : .regular)
                    .foregroundStyle(isSelected ? palette.ink : palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(Motion.fade, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help("Use the \(theme.name) terminal theme")
    }

    private func line(_ hex: UInt32, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Palette.color(hex))
            .frame(width: width, height: 3)
    }
}

// MARK: - Settings layout

/// A scrolling page of cards, on the window's `canvas`.
struct SettingsPage<Content: View>: View {
    /// A scroll view has no height of its own; this is what the pane asks for.
    var minHeight: CGFloat = 0
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: minHeight)
        .background(palette.canvas)
    }
}

/// A titled card of rows: the title in 12.5 `ink2`, the rows on `surface`
/// with the card ring, and an optional note below.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .ui(12.5, .medium)
                .foregroundStyle(palette.ink2)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(palette.surface, radius: Radius.card, elevation: .card)
            if let footer {
                Text(footer)
                    .ui(12)
                    .foregroundStyle(palette.ink2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .ui(13)
                .foregroundStyle(palette.ink)
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }
}

struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(label: label) {
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct SettingsDivider: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Rectangle().fill(palette.lineSoft).frame(height: 1).padding(.leading, 12)
    }
}

/// Local Grok CLI path text. Call `commit` from Return or focus loss only.
/// The tab messaging switch shows what the user asked for while grok applies it,
/// then the saved value again, which also moves it back after a failure.
struct TabMessagingSwitch: Equatable {
    private var requested: Bool?

    func isOn(saved: Bool) -> Bool { requested ?? saved }

    /// False when the request matches the saved value and no change should run.
    mutating func request(_ enabled: Bool, saved: Bool) -> Bool {
        guard enabled != saved else { return false }
        requested = enabled
        return true
    }

    mutating func finish() { requested = nil }
}

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
        // An untouched field is no change, even when that path is missing.
        guard path != AppSettings.normalizedExecutablePath(stored) else { return .unchanged }
        guard AppSettings.isExecutableFile(at: URL(fileURLWithPath: path)) else {
            return .rejected
        }
        return .applied(path)
    }

    /// A file picked in the open panel is a choice even when it is already the
    /// stored path, so that path stays after the default changes.
    @MainActor
    mutating func pick(_ url: URL, stored: String) -> Outcome {
        text = url.path
        let outcome = commit(stored: stored)
        guard outcome == .unchanged, AppSettings.isExecutableFile(at: url) else { return outcome }
        return .applied(AppSettings.normalizedExecutablePath(text))
    }
}
