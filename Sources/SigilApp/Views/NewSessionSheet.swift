import SigilKit
import SwiftUI

/// What a press on a provider tile does. The first press selects. The next press starts.
enum NewSessionLaunch: Equatable {
    enum Action: Equatable {
        case select(CLIProvider)
        case start(CLIProvider)
    }

    /// The Model, Effort and Fast mode rows for `provider`. Nil for Kimi,
    /// whose model comes from its own config.
    @MainActor
    static func menu(
        for provider: CLIProvider, grokModels: [String], grokModel: String, loaded: ProviderModelMenu?
    ) -> ProviderModelMenu? {
        provider == .grokBuild
            ? .grok(listed: grokModels, saved: grokModel, efforts: AppSettings.effortOptions)
            : loaded ?? ProviderModelCatalog.fallback(provider)
    }

    /// The Grok path whose model list the sheet loads. Nil for other
    /// providers, which list their own models, so `grok models` never runs.
    static func modelListPath(provider: CLIProvider, executablePath: String) -> String? {
        provider == .grokBuild ? executablePath : nil
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
    /// Each CLI keeps its own choice while the sheet is open.
    @State private var choices: [CLIProvider: ProviderModelMenu.Choice] = [:]
    @State private var grokModels = GrokModelCatalog.fallback
    @State private var menus: [CLIProvider: ProviderModelMenu] = [:]
    @State private var startsInWorktree: Bool
    @State private var isCreatingWorktree = false
    @FocusState private var focusedProvider: CLIProvider?
    @FocusState private var isProviderRowFocused: Bool

    init(model: AppModel, provider: CLIProvider? = nil) {
        self.model = model
        _provider = State(initialValue: provider ?? model.settings.defaultProvider)
        _startsInWorktree = State(initialValue: model.settings.startsInWorktree)
    }

    /// Read once when the sheet opens; it resolves every folder on disk.
    @State private var recents: [URL] = []

    /// Distinct folders of recent conversations, filtered like the sidebar so
    /// agent worktrees, subagents and archived chats do not crowd out projects.
    static func recentDirectories(
        in model: AppModel, canonicalPath: (String) -> String = GrokPaths.canonicalPath
    ) -> [URL] {
        var seenCwds = Set<String>()
        var seen = Set<String>()
        var result: [URL] = []
        let settings = model.settings
        for session in model.store.sessions {
            if !settings.showWorktreeSessions, isEphemeral(path: session.cwd) { continue }
            if !settings.showSubagentSessions, session.isSubagent { continue }
            if model.isArchived(session) { continue }
            // Resolve each stored folder once, and stop when the list is full.
            guard seenCwds.insert(session.projectPath).inserted else { continue }
            let url = URL(fileURLWithPath: canonicalPath(session.projectPath))
            guard seen.insert(url.path).inserted, AppModel.isUsableDirectory(url) else { continue }
            result.append(url)
            if result.count == 8 { break }
        }
        return result
    }

    private var recentChoices: [URL] {
        recents.contains(directory) ? recents : [directory] + recents
    }

    private var directoryIsAvailable: Bool { isDirectory(directory) }

    private var isRepository: Bool { SigilWorktree.isInRepository(directory) }

    private var canStart: Bool { directoryIsAvailable && !isCreatingWorktree }

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

            VStack(alignment: .leading, spacing: 4) {
                providerRow
                if let problem = model.providerLaunchProblem(provider) {
                    Text(problem).ui(12).foregroundStyle(palette.ink2)
                        .accessibilityIdentifier("new-session-provider-problem")
                }
            }
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                folderRow
                if isRepository {
                    divider
                    SheetRow(label: "Work in") {
                        Picker("Work in", selection: $startsInWorktree) {
                            Text("New worktree").tag(true)
                            Text("Project folder").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
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
                if let menu = menu(for: provider) {
                    let current = choice(for: provider)
                    let selected = menu.model(current.model)
                    divider
                    SheetRow(label: "Model") {
                        Picker("Model", selection: choiceBinding(\.model)) {
                            Text("CLI default").tag("")
                            ForEach(menu.models.map(\.id).filter { !$0.isEmpty }, id: \.self) { name in
                                Text(name).monospaced().tag(name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    if menu.hasEffort {
                        let efforts = selected?.efforts ?? [""]
                        divider
                        SheetRow(label: "Effort") {
                            Picker("Effort", selection: choiceBinding(\.effort)) {
                                ForEach(efforts, id: \.self) { option in
                                    Text(AppSettings.effortLabel(option)).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .disabled(efforts.count < 2)
                        }
                    }
                    if menu.hasFastMode {
                        divider
                        SheetRow(label: "Fast mode") {
                            Toggle("Fast mode", isOn: choiceBinding(\.fast))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(selected?.offersFastMode(effort: current.effort) != true)
                        }
                    }
                }
            }
            .surface(palette.isDark ? palette.inset : palette.surface, radius: Radius.card, elevation: .flat)

            HStack(spacing: 8) {
                if isCreatingWorktree {
                    ProgressView().controlSize(.small)
                    Text("Creating worktree…")
                        .ui(12)
                        .foregroundStyle(palette.ink2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreatingWorktree)
                Button("Start") { start(provider) }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart || model.providerLaunchProblem(provider) != nil)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.surface)
        .environment(\.palette, Palette(theme: model.settings.theme))
        .tint(Palette(theme: model.settings.theme).accent)
        .animation(reduceMotion ? nil : Motion.slide, value: provider)
        .defaultFocus($isProviderRowFocused, true)
        .interactiveDismissDisabled(isCreatingWorktree)
        .onAppear {
            let initial = model.pendingSessionDirectory ?? model.newSessionDirectory
            directory =
                SigilWorktree.projectPath(of: initial.path)
                .map { URL(fileURLWithPath: $0) }
                .flatMap { isDirectory($0) ? $0 : nil } ?? initial
            recents = Self.recentDirectories(in: model)
            // Settings holds Grok's defaults. The other CLIs start on their own.
            choices[.grokBuild] = .init(
                model: model.settings.model.trimmingCharacters(in: .whitespacesAndNewlines),
                effort: model.settings.effort)
        }
        .task(
            id: NewSessionLaunch.modelListPath(
                provider: provider, executablePath: model.settings.executablePath)
        ) {
            guard provider == .grokBuild else { return }
            if let found = await GrokModelCatalog.menuModels(executable: model.settings.executableURL) {
                grokModels = found
            }
        }
        .task(id: provider) {
            let current = provider
            guard menus[current] == nil, let found = await ProviderModelCatalog.load(current) else { return }
            menus[current] = found
        }
    }

    private func menu(for provider: CLIProvider) -> ProviderModelMenu? {
        NewSessionLaunch.menu(
            for: provider, grokModels: grokModels, grokModel: choices[.grokBuild]?.model ?? "",
            loaded: menus[provider])
    }

    /// The stored choice, kept inside what the current menu offers.
    private func choice(for provider: CLIProvider) -> ProviderModelMenu.Choice {
        let stored = choices[provider] ?? .init()
        return menu(for: provider)?.normalized(stored) ?? stored
    }

    private func choiceBinding<Value>(_ field: WritableKeyPath<ProviderModelMenu.Choice, Value>) -> Binding<Value> {
        Binding(
            get: { choice(for: provider)[keyPath: field] },
            set: { value in
                var next = choice(for: provider)
                next[keyPath: field] = value
                choices[provider] = menu(for: provider)?.normalized(next) ?? next
            })
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
                .disabled(!canStart)
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
        guard canStart, model.providerLaunchProblem(provider) == nil, model.canSignIn(provider) else { return }
        let launch = menu(for: provider)?.launch(choice(for: provider)) ?? (model: "", effort: "", fastMode: false)
        let project = directory
        let useWorktree = startsInWorktree && isRepository
        isCreatingWorktree = useWorktree
        Task {
            defer { isCreatingWorktree = false }
            var folder = project
            if useWorktree {
                do {
                    folder = try await SigilWorktree.create(for: project) ?? project
                } catch {
                    model.showError(
                        title: "Could not create a worktree", message: error.localizedDescription)
                    return
                }
            }
            if model.newTab(
                in: folder, model: launch.model, effort: launch.effort, fastMode: launch.fastMode,
                provider: provider
            ) != nil {
                dismiss()
            }
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
