import AppKit
import SigilKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var tabMessagingError: String?

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
                        TextField("Path", text: Bindable(model.settings).executablePath)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                        Button("Choose…") { pickExecutable() }
                    }
                    Label(
                        model.settings.executableExists ? "Found" : "Not found",
                        systemImage: model.settings.executableExists
                            ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(model.settings.executableExists ? .green : .red)
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
                .disabled(BridgeRegistration.bundledMCPBinary == nil)
            } footer: {
                Text(tabMessagingFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert(
            "Could not update tab messaging",
            isPresented: Binding(
                get: { tabMessagingError != nil },
                set: { if !$0 { tabMessagingError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tabMessagingError ?? "")
        }
    }

    private var tabMessagingIsOn: Binding<Bool> {
        Binding(
            get: { model.settings.isTabMessagingEnabled },
            set: { applyTabMessaging(enabled: $0) }
        )
    }

    private var tabMessagingFooter: String {
        if BridgeRegistration.bundledMCPBinary == nil {
            return "Unavailable: this build has no sigil-mcp helper."
        }
        return """
            Each session gets tools to list the other tabs, send one a message, \
            and ask one a question. This adds a sigil entry to ~/.grok/config.toml. \
            Tabs you open afterwards can message each other; tabs already open cannot.
            """
    }

    private func applyTabMessaging(enabled: Bool) {
        let previous = model.settings.isTabMessagingEnabled
        guard enabled != previous else { return }
        guard let binary = BridgeRegistration.bundledMCPBinary else { return }
        model.settings.isTabMessagingEnabled = enabled
        let executable = model.settings.executableURL
        Task.detached(priority: .userInitiated) {
            let registration = BridgeRegistration(executable: executable)
            do {
                if enabled {
                    try registration.install(mcpBinary: binary)
                } else {
                    try registration.remove()
                }
                await MainActor.run { model.setTabMessaging(enabled: enabled) }
            } catch {
                let text = error.localizedDescription
                await MainActor.run {
                    model.settings.isTabMessagingEnabled = previous
                    tabMessagingError = text
                }
            }
        }
    }

    private func pickExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: model.settings.executablePath)
            .deletingLastPathComponent()
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.executablePath = url.path
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
