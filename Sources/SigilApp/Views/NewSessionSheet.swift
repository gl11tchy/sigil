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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New session")
                    .ui(15, .semibold)
                    .foregroundStyle(palette.ink)
                Text("Pick a CLI and a folder. Press a CLI twice to start it.")
                    .ui(13)
                    .foregroundStyle(palette.ink2)
            }
            .padding(.bottom, 16)

            providerRow
                .padding(.bottom, 16)

            VStack(spacing: 0) {
                folderRow
                if !recents.isEmpty {
                    divider
                    SheetRow(label: "Recent") {
                        Picker("Recent", selection: $directory) {
                            ForEach(recentChoices, id: \.self) { url in
                                Text(url.abbreviatedPath).tag(url)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                if NewSessionLaunch.showsModelAndEffort(provider) {
                    divider
                    SheetRow(label: "Model") {
                        Picker("Model", selection: $modelName) {
                            Text("CLI default").tag("")
                            ForEach(GrokModelCatalog.choices(listed: models, saved: modelName), id: \.self) {
                                name in
                                Text(name).monospaced().tag(name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    divider
                    SheetRow(label: "Effort") {
                        Picker("Effort", selection: $effort) {
                            ForEach(AppSettings.effortOptions, id: \.self) { option in
                                Text(AppSettings.effortLabel(option)).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
            }
            .surface(palette.isDark ? palette.inset : palette.surface, radius: Radius.card, elevation: .flat)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start(provider) }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!directoryIsAvailable)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.surface)
        .environment(\.palette, Palette(theme: model.settings.theme))
        .tint(Palette(theme: model.settings.theme).accent)
        .animation(reduceMotion ? nil : Motion.slide, value: provider)
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

    private var divider: some View {
        Rectangle().fill(palette.lineSoft).frame(height: 1).padding(.leading, 12)
    }

    private var providerRow: some View {
        HStack(spacing: 6) {
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
        SheetRow(label: "Folder") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Text(directory.abbreviatedPath)
                        .mono(12)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(directory.path)
                    Button("Choose…") {
                        if let picked = model.pickDirectory(startingAt: directory) {
                            directory = picked
                        }
                    }
                    .buttonStyle(SigilButtonStyle(kind: .secondary, height: 26))
                }
                if !directoryIsAvailable {
                    Text("Folder unavailable.")
                        .ui(12)
                        .foregroundStyle(palette.redInk)
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

/// One labelled line inside the sheet's card: the label in `ink2` on the
/// leading side, its control on the trailing side.
private struct SheetRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .ui(13)
                .foregroundStyle(palette.ink2)
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
    }
}

/// A CLI as a large tile. Selected is `hover2`; the keyboard ring is `lineStrong`.
private struct ProviderChoice: View {
    let provider: CLIProvider
    let isSelected: Bool
    let isFocused: Bool
    var focus: FocusState<CLIProvider?>.Binding
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    private var fill: Color {
        if isSelected { return palette.hover2 }
        return (isHovering || isFocused) ? palette.hover : .clear
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ProviderLogo(provider: provider)
                    .frame(width: 32, height: 32)
                Text(provider.name)
                    .ui(12.5, .medium)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? palette.ink : palette.ink2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? palette.ringButton
                                    : (isFocused ? palette.lineStrong : Color.clear),
                                lineWidth: 1
                            )
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .animation(Motion.fade, value: isHovering)
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
