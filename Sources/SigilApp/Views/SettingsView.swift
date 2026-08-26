import AppKit
import SigilKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var settingsError: String?
    @State private var pathDraft: ExecutablePathDraft
    @FocusState private var isExecutablePathFocused: Bool

    init(model: AppModel) {
        self.model = model
        _pathDraft = State(initialValue: ExecutablePathDraft(text: model.settings.executablePath))
    }

    var body: some View {
        TabView {
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
            general.tabItem { Label("General", systemImage: "gearshape") }
        }
        .tint(Palette(theme: model.settings.theme).accent)
        .environment(\.palette, Palette(theme: model.settings.theme))
        .frame(width: 460)
        .scenePadding()
    }

    private var appearance: some View {
        Form {
            LabeledContent("Theme") {
                HStack(spacing: 8) {
                    ForEach(TerminalTheme.all) { theme in
                        ThemeCard(
                            theme: theme,
                            isSelected: model.settings.themeName == theme.name
                        ) {
                            model.settings.themeName = theme.name
                            model.applyAppearance()
                        }
                    }
                }
                .padding(.vertical, 2)
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

            LabeledContent("Default model") {
                ModelNameField(text: Bindable(model.settings).model)
            }

            Picker("Default effort", selection: Bindable(model.settings).effort) {
                ForEach(AppSettings.effortOptions, id: \.self) { option in
                    Text(option.isEmpty ? "CLI default" : option.capitalized).tag(option)
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
        AppSettings.isExecutableFile(at: URL(fileURLWithPath: pathDraft.text))
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
                    .frame(width: 64, height: 34)
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
            }
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
        guard AppSettings.isExecutableFile(at: URL(fileURLWithPath: text)) else {
            return .rejected
        }
        guard text != stored else { return .unchanged }
        return .applied(text)
    }
}

/// Free-text model name with the known CLI names as fill-in suggestions.
struct ModelNameField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            TextField("CLI default", text: $text)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(AppSettings.modelOptions.filter { !$0.isEmpty }, id: \.self) { option in
                    Button(option) { text = option }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("Suggested models")
        }
    }
}
