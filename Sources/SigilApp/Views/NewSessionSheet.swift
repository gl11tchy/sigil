import SigilKit
import SwiftUI

/// What a press on a provider tile does. The first press selects. The next press starts.
enum NewSessionLaunch: Equatable {
    enum Action: Equatable {
        case select(CLIProvider)
        case start(CLIProvider)
    }

    static func showsModelAndEffort(_ provider: CLIProvider) -> Bool {
        provider == .grokBuild
    }

    /// Other CLIs do not take Grok's model or effort flags.
    static func fields(
        provider: CLIProvider, model: String, effort: String
    ) -> (model: String, effort: String) {
        guard showsModelAndEffort(provider) else { return ("", "") }
        return (model, effort)
    }

    static func action(selected: CLIProvider, tapped: CLIProvider) -> Action {
        selected == tapped ? .start(tapped) : .select(tapped)
    }

    /// Left and right arrows walk the row in screen order and stop at its ends.
    static func provider(after current: CLIProvider, movingBy offset: Int) -> CLIProvider {
        let all = CLIProvider.allCases
        guard let index = all.firstIndex(of: current) else { return current }
        return all[min(max(index + offset, all.startIndex), all.index(before: all.endIndex))]
    }
}

/// Chooses a provider and starts its CLI in the requested folder.
struct NewSessionSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var directory: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var provider: CLIProvider
    @State private var modelName = ""
    @State private var effort = ""
    @State private var models = GrokModelCatalog.fallback
    @FocusState private var focusedProvider: CLIProvider?
    @FocusState private var isProviderRowFocused: Bool

    init(model: AppModel, provider: CLIProvider = .grokBuild) {
        self.model = model
        _provider = State(initialValue: provider)
    }

    private var recents: [URL] {
        var seen = Set<String>()
        return model.store.sessions.compactMap { session in
            let url = URL(fileURLWithPath: GrokPaths.canonicalPath(session.cwd))
            guard seen.insert(url.path).inserted else { return nil }
            return isDirectory(url) ? url : nil
        }
        .prefix(8)
        .map { $0 }
    }

    private var recentChoices: [URL] {
        recents.contains(directory) ? recents : [directory] + recents
    }

    private var directoryIsAvailable: Bool { isDirectory(directory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session")
                .font(.headline)
                .foregroundStyle(palette.text)

            providerRow

            Form {
                folderRow
                if !recents.isEmpty {
                    Picker("Recent", selection: $directory) {
                        ForEach(recentChoices, id: \.self) { url in
                            Text(url.abbreviatedPath).tag(url)
                        }
                    }
                }
                if NewSessionLaunch.showsModelAndEffort(provider) {
                    Picker("Model", selection: $modelName) {
                        Text("CLI default").tag("")
                        ForEach(GrokModelCatalog.choices(listed: models, saved: modelName), id: \.self) {
                            name in
                            Text(name).monospaced().tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Effort", selection: $effort) {
                        ForEach(AppSettings.effortOptions, id: \.self) { option in
                            Text(AppSettings.effortLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start(provider) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!directoryIsAvailable)
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.palette, Palette(theme: model.settings.theme))
        .tint(Palette(theme: model.settings.theme).accent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: provider)
        .defaultFocus($isProviderRowFocused, true)
        .onAppear {
            directory = model.pendingSessionDirectory ?? model.newSessionDirectory
            modelName = model.settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
            effort = model.settings.effort
        }
        .task(id: model.settings.executablePath) {
            let found = await GrokModelCatalog.load(executable: model.settings.executableURL)
            if !found.isEmpty { models = found }
        }
    }

    private var providerRow: some View {
        HStack(spacing: 8) {
            ForEach(CLIProvider.allCases) { item in
                ProviderChoice(
                    provider: item,
                    isSelected: provider == item,
                    isFocused: focusedProvider == item,
                    focus: $focusedProvider
                ) {
                    switch NewSessionLaunch.action(selected: provider, tapped: item) {
                    case .select(let next):
                        provider = next
                    case .start(let next):
                        start(next)
                    }
                }
                .disabled(!directoryIsAvailable)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider")
        .focusable()
        .focusEffectDisabled()
        .focused($isProviderRowFocused)
        .onKeyPress(.leftArrow) { moveProvider(by: -1) }
        .onKeyPress(.rightArrow) { moveProvider(by: 1) }
    }

    private func moveProvider(by offset: Int) -> KeyPress.Result {
        provider = NewSessionLaunch.provider(after: provider, movingBy: offset)
        return .handled
    }

    private var folderRow: some View {
        LabeledContent("Folder") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(directory.abbreviatedPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") {
                        if let picked = model.pickDirectory(startingAt: directory) {
                            directory = picked
                        }
                    }
                }
                if !directoryIsAvailable {
                    Text("Folder unavailable.")
                        .font(.caption)
                        .foregroundStyle(palette.error)
                }
            }
        }
    }

    private func start(_ provider: CLIProvider) {
        let fields = NewSessionLaunch.fields(
            provider: provider, model: modelName, effort: effort)
        if model.newTab(
            in: directory, model: fields.model, effort: fields.effort, provider: provider
        ) != nil {
            dismiss()
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private struct ProviderChoice: View {
    let provider: CLIProvider
    let isSelected: Bool
    let isFocused: Bool
    var focus: FocusState<CLIProvider?>.Binding
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    private var fill: Color {
        if isSelected { return palette.selected }
        return (isHovering || isFocused) ? palette.raised : .clear
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ProviderLogo(provider: provider)
                    .frame(width: 36, height: 36)
                Text(provider.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? palette.text : palette.textDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isFocused && !isSelected ? palette.hairline : Color.clear,
                                lineWidth: 1
                            )
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focused(focus, equals: provider)
        .onHover { isHovering = $0 }
        .accessibilityLabel(provider.name)
        .accessibilityIdentifier("new-session-\(provider.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(isSelected ? "Start \(provider.name)" : provider.name)
    }
}
