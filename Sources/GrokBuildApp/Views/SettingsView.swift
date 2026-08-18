import GrokBuildKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

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
                    TextField("Path", text: Bindable(model.settings).executablePath)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                    Label(
                        model.settings.executableExists ? "Found" : "Not found",
                        systemImage: model.settings.executableExists
                            ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(model.settings.executableExists ? .green : .red)
                }
            }

            Picker("Default model", selection: Bindable(model.settings).model) {
                ForEach(AppSettings.modelOptions, id: \.self) { option in
                    Text(option.isEmpty ? "CLI default" : option).tag(option)
                }
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
        }
        .formStyle(.grouped)
    }
}
