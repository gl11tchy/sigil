import AppKit
import SigilKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var settingsError: String?
    @State private var executablePath: String

    init(model: AppModel) {
        self.model = model
        _executablePath = State(initialValue: model.settings.executablePath)
    }

    var body: some View {
        TabView {
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
            general.tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460)
        .scenePadding()
    }

    private var appearance: some View {
        Form {
            Picker("Theme", selection: Bindable(model.settings).themeName) {
                ForEach(TerminalTheme.all) { theme in
                    Text(theme.name).tag(theme.name)
                }
            }
            .onChange(of: model.settings.themeName) { _, _ in model.applyAppearance() }

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
                        TextField("Path", text: $executablePath)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                            .onSubmit { applyExecutablePath() }
                            .onChange(of: executablePath) { _, _ in
                                if draftExecutableExists { applyExecutablePath() }
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
        AppSettings.isExecutableFile(at: URL(fileURLWithPath: executablePath))
    }

    private func applyExecutablePath() {
        guard draftExecutableExists else {
            settingsError = "Choose an executable file."
            return
        }
        guard executablePath != model.settings.executablePath else { return }
        model.settings.executablePath = executablePath
        Task { await model.executableConfigurationChanged() }
    }

    private func pickExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            executablePath = url.path
            applyExecutablePath()
        }
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
