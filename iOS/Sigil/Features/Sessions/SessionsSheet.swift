import SwiftUI

/// Open tabs on the Mac, plus every saved chat, newest first and searchable.
/// Beautiful UI's sidebar on a phone: a search field, sentence-case sections
/// with a count, and one-line rows with trailing mono metadata.
struct SessionsSheet: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onNew: () -> Void
    @State private var query = ""
    @State private var renaming: RemoteTab?
    @State private var newName = ""
    @State private var closing: RemoteTab?
    @State private var addingMac = false

    private var matches: [RemoteTab] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.tabs }
        return store.tabs.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if store.macs.count > 1 { macsSection }
                Section {
                    if matches.isEmpty {
                        emptyRow(store.tabs.isEmpty ? "No open sessions." : "No matching sessions.")
                    }
                    ForEach(matches) { tab in
                        let selected = tab.id == store.selectedTabID
                        Button {
                            store.select(tab)
                            dismiss()
                        } label: {
                            row(tab, selected: selected)
                        }
                        .buttonStyle(SidebarRowStyle(selected: selected))
                        .disabled(!store.isConnected || store.busy)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .sidebarRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if store.supportsSessionOps {
                                Button(role: .destructive) {
                                    closing = tab
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                                if tab.supportsArchive {
                                    Button {
                                        store.archive(tab)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(Theme.orange)
                                }
                                Button {
                                    newName = tab.title
                                    renaming = tab
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(Theme.accentFill)
                                .disabled(!tab.canRename)
                            }
                        }
                        .contextMenu {
                            if store.supportsSessionOps {
                                Button {
                                    newName = tab.title
                                    renaming = tab
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .disabled(!tab.canRename)
                                if tab.supportsArchive {
                                    Button {
                                        store.archive(tab)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                }
                                Button(role: .destructive) {
                                    closing = tab
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                            }
                        }
                    }
                } header: {
                    SectionHeader(
                        title: store.macName.map { "Open on \($0)" } ?? "Open on your Mac",
                        count: matches.isEmpty ? nil : matches.count)
                }

                Section {
                    if store.loadingChats, store.chats.isEmpty {
                        HStack(spacing: Theme.Space.small) {
                            PixelLoader(color: Theme.ink3)
                                .frame(width: 10, height: 10)
                            Text(searching ? "Searching…" : "Loading…")
                                .typeStep(.body)
                                .foregroundStyle(Theme.ink2)
                        }
                        .padding(.horizontal, Theme.Space.s8)
                        .frame(maxWidth: .infinity, minHeight: Theme.tapTarget, alignment: .leading)
                        .sidebarRow()
                    } else if store.chats.isEmpty {
                        emptyRow(!store.isConnected ? "Reconnecting…" : searching ? "No matching chats." : "No saved chats.")
                    }
                    ForEach(store.chats) { chat in
                        Button {
                            store.open(chat)
                            dismiss()
                        } label: {
                            HStack(spacing: Theme.Space.small) {
                                // An empty mark slot keeps chat titles in line with the open tabs'.
                                Color.clear.frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                                TitleAndMeta(title: chat.title, meta: chat.folder)
                            }
                        }
                        .buttonStyle(SidebarRowStyle())
                        .disabled(!store.isConnected || store.busy)
                        .sidebarRow()
                    }
                    if store.chatList.hasMore {
                        Button {
                            store.loadMoreChats()
                        } label: {
                            HStack(spacing: Theme.Space.small) {
                                Text("Show more")
                                    .typeStep(.row)
                                    .foregroundStyle(Theme.accentInk)
                                if store.loadingChats { PixelLoader(color: Theme.accent) }
                            }
                        }
                        .buttonStyle(SidebarRowStyle())
                        .disabled(!store.isConnected || store.loadingChats)
                        .accessibilityValue(store.loadingChats ? "Loading" : "")
                        .sidebarRow()
                    }
                } header: {
                    SectionHeader(
                        title: searching ? "Saved chats" : "Recent chats",
                        count: store.chats.isEmpty ? nil : store.chats.count)
                }

                if !store.isDemo || store.macs.count <= 1 {
                    Section {
                        Button {
                            addingMac = true
                        } label: {
                            Label {
                                Text("Pair another Mac")
                                    .typeStep(.row)
                                    .foregroundStyle(Theme.ink)
                            } icon: {
                                Image(systemName: "desktopcomputer.and.arrow.down")
                                    .font(Theme.glyph)
                                    .foregroundStyle(Theme.ink3)
                            }
                        }
                        .buttonStyle(SidebarRowStyle())
                        .sidebarRow()
                    }
                }
            }
            .listStyle(.plain)
            // The first header keeps the same rhythm under the search field as between sections.
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search sessions and chats")
            .sheet(isPresented: $addingMac) { PairView(embedded: true) }
            .privacySensitive()
            .onChange(of: query) { _, value in store.loadChats(value) }
            .onChange(of: store.isConnected) { _, connected in
                if connected, store.chats.isEmpty { store.loadChats(query) }
            }
            .onAppear { store.loadChats(query) }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let tab = renaming { store.rename(tab, to: newName) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("An empty name restores the Mac's own title.")
            }
            .confirmationDialog(
                "Close this session?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                titleVisibility: .visible
            ) {
                Button("Close session", role: .destructive) {
                    if let tab = closing { store.close(tab) }
                    closing = nil
                }
            } message: {
                Text(closing?.status == .working ? "It is still working. Closing stops it." : "This closes the tab on your Mac.")
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Sessions")
                        .typeStep(.title)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.bar)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onNew()
                    } label: {
                        Label("New session", systemImage: "plus")
                            .labelStyle(.iconOnly)
                            .font(Theme.glyph)
                    }
                    .buttonStyle(.icon)
                    .disabled(!store.isConnected || store.busy)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .onDisappear { store.clearChats() }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.canvas)
    }

    /// Every paired Mac; choosing one swaps the whole screen to it.
    private var macsSection: some View {
        Section {
            ForEach(store.macs) { mac in
                let active = mac.id == store.activeMacID
                Button {
                    store.switchTo(macID: mac.id)
                    dismiss()
                } label: {
                    HStack(spacing: Theme.Space.small) {
                        Image(systemName: "desktopcomputer")
                            .font(Theme.glyph)
                            .foregroundStyle(active ? Theme.accent : Theme.ink3)
                            .accessibilityHidden(true)
                        TitleAndMeta(title: mac.label, meta: mac.origin.host ?? "", selected: active)
                    }
                }
                .buttonStyle(SidebarRowStyle(selected: active))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(active ? .isSelected : [])
                .sidebarRow()
            }
        } header: {
            SectionHeader(title: "Macs", count: store.macs.count)
        }
    }

    /// "Claude Code · Working · sigil/feature"; older Macs send status only.
    private func detail(for tab: RemoteTab) -> String {
        [tab.providerName, tab.status.label, tab.folder].compactMap { $0 }.joined(separator: " · ")
    }

    /// The state mark, the title, and "Claude Code · sigil/feature" in mono.
    /// The mark carries working and ready on screen; a state the mark cannot
    /// tell apart by shape alone is named in the meta too. VoiceOver hears it as a word.
    private func row(_ tab: RemoteTab, selected: Bool) -> some View {
        let word: String? =
            switch tab.status {
            case .working, .idle: nil
            case .starting, .waitingForApproval, .interrupted, .failed, .disconnected, .exited, .unknown: tab.status.label
            }
        return HStack(spacing: Theme.Space.small) {
            ActivityMark(status: tab.status)
            TitleAndMeta(
                title: tab.title,
                meta: [tab.providerName, tab.folder].compactMap { $0 }.joined(separator: " · "),
                state: word, selected: selected)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tab.title), \(detail(for: tab))")
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .typeStep(.body)
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, Theme.Space.s8)
            .frame(maxWidth: .infinity, minHeight: Theme.tapTarget, alignment: .leading)
            .sidebarRow()
    }
}

// MARK: - Sidebar parts

/// A section label in `ink2` with its count in mono, on the canvas so a
/// pinned header hides the rows scrolling under it.
private struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s6) {
            Text(title)
                .sectionLabelStyle()
            if let count {
                Text("\(count)")
                    .typeStep(.mono)
                    .foregroundStyle(Theme.ink2)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.horizontal, Theme.Space.large)
        .padding(.top, Theme.Space.medium)
        .padding(.bottom, Theme.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas)
        .listRowInsets(EdgeInsets())
    }
}

/// A row's title in `ink` and its metadata in mono `ink2`, on one line. At
/// accessibility text sizes the metadata moves under the title.
private struct TitleAndMeta: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let meta: String
    /// A state word that leads the metadata and is never cut; the rest is cut from the head.
    var state: String?
    var selected = false

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout =
            stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s2))
            : AnyLayout(TrailingMetaLayout())
        layout {
            Text(title)
                .typeStep(.row, weight: selected ? .medium : .regular)
                .foregroundStyle(Theme.ink)
                .lineLimit(stacked ? 2 : 1)
            HStack(spacing: 0) {
                if let state {
                    Text(meta.isEmpty ? state : "\(state) · ")
                        .layoutPriority(1)
                }
                Text(meta)
                    .truncationMode(.head)
            }
            .typeStep(.mono)
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
        }
        .padding(.vertical, stacked ? Theme.Space.s6 : 0)
    }
}

/// The title on the leading edge and the metadata on the trailing edge. The
/// metadata takes what it needs, up to 45% of the row, and more when the
/// title is short; the title takes the rest and truncates.
private struct TrailingMetaLayout: Layout {
    var spacing: CGFloat = Theme.Space.s12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width =
            proposal.width
            ?? subviews[0].sizeThatFits(.unspecified).width + spacing + subviews[1].sizeThatFits(.unspecified).width
        let (title, meta) = sizes(for: width, subviews)
        return CGSize(width: width, height: max(title.height, meta.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (title, meta) = sizes(for: bounds.width, subviews)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(title))
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(meta))
    }

    private func sizes(for width: CGFloat, _ subviews: Subviews) -> (CGSize, CGSize) {
        let titleIdeal = subviews[0].sizeThatFits(.unspecified).width
        let metaIdeal = subviews[1].sizeThatFits(.unspecified).width
        let available = max(0, width - spacing)
        let metaWidth = min(metaIdeal, max(available * 0.45, available - titleIdeal))
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: available - metaWidth, height: nil))
        let meta = subviews[1].sizeThatFits(ProposedViewSize(width: metaWidth, height: nil))
        return (title, meta)
    }
}

/// Beautiful UI's sidebar row: 44pt, `control` radius, 8pt side padding. The
/// open row is `hover2` in dark mode; in light mode it lifts to `surface` with
/// the `button` ring, because a grey fill vanishes on the light canvas. A
/// press takes the hover fill: `hover` in dark mode, `hover2` in light.
private struct SidebarRowStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        SidebarRowBody(configuration: configuration, selected: selected)
    }
}

private struct SidebarRowBody: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        let dark = colorScheme == .dark
        configuration.label
            .padding(.horizontal, Theme.Space.s8)
            .frame(maxWidth: .infinity, minHeight: Theme.tapTarget, alignment: .leading)
            .background {
                if selected {
                    if dark {
                        shape.fill(Theme.hover2)
                    } else {
                        Color.clear.surface(Theme.surface, in: shape, elevation: .button)
                    }
                }
                // The selected row deepens a step; any other row takes the hover fill.
                shape.fill(selected ? Theme.ink.opacity(0.06) : dark ? Theme.hover : Theme.hover2)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(
                Theme.animation(Theme.Motion.fade, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    /// A row that draws its own fill: no cell background, no separator, and
    /// the sidebar's 8pt inset from the sheet's edges.
    fileprivate func sidebarRow() -> some View {
        listRowInsets(EdgeInsets(top: 1, leading: Theme.Space.s8, bottom: 1, trailing: Theme.Space.s8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - New session

/// Choose the CLI, its model and the project folder for a new session, as the
/// Mac's New Session sheet does. A Mac from before provider choice starts its default CLI.
struct NewSessionSheet: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var providerID = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var target: Target?
    @State private var inWorktree = true

    enum Target: Hashable {
        case currentFolder
        case project(String)
    }

    private var options: NewSessionOptions? { store.sessionOptions }
    private var provider: NewSessionOptions.Provider? { options?.providers.first { $0.id == providerID } }
    private var takesModel: Bool { provider?.takesModel == true }

    private var canStart: Bool {
        store.isConnected && !store.busy && !loading && target != nil && provider?.problem == nil
    }

    /// The chosen project is a git repository on a Mac that can make worktrees.
    private var canUseWorktree: Bool {
        guard store.supportsSessionOps, case .project(let folder) = target else { return false }
        return store.projects.first { $0.folder == folder }?.repository == true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.large) {
                    if let options { agentSection(options) }
                    projectSection
                }
                .padding(.horizontal, Theme.Space.large)
                .padding(.vertical, Theme.Space.small)
            }
            .flowsUnderChrome()
            .background(Theme.surface)
            .privacySensitive()
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("New session")
                        .typeStep(.title)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bar)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .buttonStyle(.barProminent)
                        .disabled(!canStart)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .task { await load() }
            .onChange(of: store.isConnected) { _, connected in
                // Opened while reconnecting: the provider list and projects arrive now.
                if connected, store.sessionOptions == nil { Task { await load() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.surface)
    }

    private func agentSection(_ options: NewSessionOptions) -> some View {
        FormSection("Agent") {
            FormCard {
                SegmentedChoice(
                    "Provider", selection: $providerID,
                    items: options.providers.map { ($0.id, $0.name) })
                if takesModel {
                    FormRule()
                    FormRow("Model") {
                        MenuField(title: model.isEmpty ? "CLI default" : model, monospaced: !model.isEmpty) {
                            Picker("Model", selection: $model) {
                                Text("CLI default").tag("")
                                ForEach(Self.unique(options.models), id: \.self) { name in
                                    Text(name).monospaced().tag(name)
                                }
                            }
                        }
                        .accessibilityLabel("Model")
                        .accessibilityValue(model.isEmpty ? "CLI default" : model)
                    }
                    FormRule()
                    SegmentedChoice(
                        "Effort", selection: $effort,
                        items: options.efforts.map { ($0.id, $0.name) })
                }
            }
            .disabled(!store.isConnected || store.busy)
        } footer: {
            if let problem = provider?.problem {
                Notice(text: problem)
            }
        }
    }

    private var projectSection: some View {
        // A rule between every two rows, as the Agent card has.
        let hasNewProject = options?.locations.isEmpty == false
        return FormSection("Project") {
            FormCard {
                if let locations = options?.locations, !locations.isEmpty {
                    NavigationLink {
                        NewProjectForm(locations: locations) { created in target = .project(created.folder) }
                    } label: {
                        HStack(spacing: Theme.Space.small) {
                            Label {
                                Text("New project")
                                    .typeStep(.row)
                                    .foregroundStyle(Theme.accentInk)
                            } icon: {
                                Image(systemName: "folder.badge.plus")
                                    .font(Theme.glyph)
                                    .foregroundStyle(Theme.accent)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(Theme.font(.small, weight: .medium))
                                .foregroundStyle(Theme.ink3)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(FormRowStyle())
                    .disabled(!store.isConnected || store.busy)
                }
                if hasNewProject, store.projects.isEmpty { FormRule() }
                if loading, store.projects.isEmpty {
                    HStack(spacing: Theme.Space.small) {
                        PixelLoader(color: Theme.ink3)
                        Text("Loading projects…")
                            .typeStep(.body)
                            .foregroundStyle(Theme.ink2)
                    }
                    .padding(.horizontal, Theme.Space.s8)
                    .frame(maxWidth: .infinity, minHeight: Theme.tapTarget, alignment: .leading)
                } else if store.projects.isEmpty {
                    choice(
                        "Current folder", detail: "The folder Sigil uses for a new session", monospaced: false,
                        target: .currentFolder)
                }
                ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                    if hasNewProject || index > 0 { FormRule() }
                    choice(project.name, detail: project.folder, monospaced: true, target: .project(project.folder))
                }
                if store.projectsTruncated, !store.projects.isEmpty {
                    FormRule()
                    Button {
                        Task { _ = await store.loadProjects(from: store.projects.count) }
                    } label: {
                        Text("More projects")
                            .typeStep(.row)
                            .foregroundStyle(Theme.accentInk)
                    }
                    .buttonStyle(FormRowStyle())
                    .disabled(!store.isConnected || store.busy)
                }
                if canUseWorktree {
                    FormRule()
                    Toggle(isOn: $inWorktree) {
                        Text("Start in a new worktree")
                            .typeStep(.row)
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, Theme.Space.s8)
                    .frame(minHeight: Theme.tapTarget)
                    .disabled(!store.isConnected || store.busy)
                }
            }
        } footer: {
            if let error = store.errorMessage {
                Notice(text: error, tone: .failure)
            } else if canUseWorktree, inWorktree {
                Text("A fresh checkout on its own branch, under ~/.sigil/worktrees, as the Mac does.")
                    .typeStep(.small)
                    .foregroundStyle(Theme.ink2)
            }
        }
    }

    private func choice(_ title: String, detail: String, monospaced: Bool, target choice: Target) -> some View {
        Button {
            target = choice
        } label: {
            HStack(spacing: Theme.Space.small) {
                VStack(alignment: .leading, spacing: Theme.Space.s2) {
                    Text(title)
                        .typeStep(.row, weight: target == choice ? .medium : .regular)
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .typeStep(monospaced ? .mono : .small)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.vertical, Theme.Space.s6)
                Spacer(minLength: 0)
                if target == choice {
                    Image(systemName: "checkmark")
                        .font(Theme.glyph)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(FormRowStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(target == choice ? .isSelected : [])
        .disabled(!store.isConnected || store.busy)
    }

    private func load() async {
        let hasOptions = await store.loadSessionOptions()
        let hasProjects = store.isDemo ? true : await store.loadProjects()
        if let options = store.sessionOptions {
            providerID = options.provider
            model = options.model
            effort = options.effort
            // The Mac's own default; a Mac without the field made worktrees by default.
            inWorktree = options.startsInWorktree ?? true
        }
        loading = false
        guard hasProjects else {
            // A Mac without the project list starts New in its current folder.
            target = .currentFolder
            if !hasOptions { start() }
            return
        }
        if target == nil {
            target = store.projects.first.map { .project($0.folder) } ?? .currentFolder
        }
    }

    private func start() {
        guard let target else { return }
        let folder: String?
        switch target {
        case .currentFolder: folder = nil
        case .project(let path): folder = path
        }
        store.newSession(
            in: folder, provider: options == nil ? nil : providerID, model: takesModel ? model : nil,
            effort: takesModel ? effort : nil, worktree: canUseWorktree ? inWorktree : nil)
        dismiss()
    }

    /// `grok models` may repeat a row; the menu needs each once.
    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Makes a folder on the Mac and adds it to Projects, then selects it for the new session.
struct NewProjectForm: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let locations: [RemoteProject]
    let onCreated: (RemoteProject) -> Void
    @State private var name = ""
    @State private var location = ""
    @State private var creating = false
    @State private var problem: String?
    @FocusState private var nameFocused: Bool

    private var validName: String? { ProjectName.validated(name) }
    private var place: RemoteProject? { locations.first { $0.folder == location } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.large) {
                FormSection("Name") {
                    TextField(
                        "Folder name", text: $name,
                        prompt: Text("Folder name").foregroundStyle(Theme.ink2)
                    )
                    .typeStep(.field)
                    .foregroundStyle(Theme.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit(create)
                    .padding(.horizontal, Theme.Space.medium)
                    .frame(minHeight: Theme.tapTarget)
                    .fieldBackground(isFocused: nameFocused)
                } footer: {
                    if validName == nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Use a name without slashes, colons or a leading dot.")
                            .typeStep(.small)
                            .foregroundStyle(Theme.ink2)
                    } else if let validName, let place {
                        Text(place.name == "~" ? "~/\(validName)" : "\(place.name)/\(validName)")
                            .typeStep(.mono)
                            .foregroundStyle(Theme.ink2)
                    }
                }
                FormSection("Location") {
                    FormCard {
                        ForEach(locations) { item in
                            Button {
                                location = item.folder
                            } label: {
                                HStack {
                                    Text(item.name)
                                        .typeStep(.mono, weight: item.folder == location ? .medium : .regular)
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Spacer(minLength: 0)
                                    if item.folder == location {
                                        Image(systemName: "checkmark")
                                            .font(Theme.glyph)
                                            .foregroundStyle(Theme.accent)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .buttonStyle(FormRowStyle())
                            .accessibilityAddTraits(item.folder == location ? .isSelected : [])
                        }
                    }
                } footer: {
                    EmptyView()
                }
                if let problem {
                    Notice(text: problem, tone: .failure)
                }
            }
            .padding(.horizontal, Theme.Space.large)
            .padding(.vertical, Theme.Space.small)
        }
        .flowsUnderChrome()
        .background(Theme.surface)
        .privacySensitive()
        .disabled(creating)
        .navigationTitle("New project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.surface, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("New project")
                    .typeStep(.title)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .confirmationAction) {
                if creating {
                    PixelLoader(color: Theme.accent)
                        .frame(minWidth: Theme.tapTarget, minHeight: Theme.tapTarget)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("In progress")
                } else {
                    Button("Create", action: create)
                        .buttonStyle(.barProminent)
                        .disabled(validName == nil || place == nil || !store.isConnected || store.busy)
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .onAppear {
            if location.isEmpty { location = locations.first?.folder ?? "" }
            nameFocused = true
        }
    }

    private func create() {
        guard !creating, validName != nil, let place else { return }
        creating = true
        problem = nil
        Task {
            switch await store.createProject(named: name, in: place) {
            case .success(let project):
                onCreated(project)
                dismiss()
            case .failure(let error):
                problem = error.localizedDescription
            }
            creating = false
        }
    }
}

// MARK: - Form parts

/// A group on the sheet: a sentence-case label, its content, and a footer.
private struct FormSection<Content: View, Footer: View>: View {
    let title: String
    let content: Content
    let footer: Footer

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text(title)
                .sectionLabelStyle()
                .padding(.horizontal, Theme.Space.s4)
                .accessibilityAddTraits(.isHeader)
            content
            footer
                .padding(.horizontal, Theme.Space.s4)
        }
    }
}

/// Rows grouped on the sheet, as the Mac's New Session sheet groups them:
/// `inset` in dark mode and `surface` in light, with a `line` ring and no shadow.
private struct FormCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(Theme.Space.s4)
            .surface(colorScheme == .dark ? Theme.inset : Theme.surface, radius: Theme.Radius.card, elevation: .flat)
    }
}

/// A `lineSoft` rule between rows inside a card.
private struct FormRule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.lineSoft)
            .frame(height: 1)
            .padding(.horizontal, Theme.Space.s8)
            .padding(.vertical, Theme.Space.s2)
            .accessibilityHidden(true)
    }
}

/// A label in `ink2` on the leading side and its control on the trailing side. At
/// accessibility text sizes the control moves under the label, so its value keeps the width.
private struct FormRow<Control: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let label: String
    let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout =
            stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s6))
            : AnyLayout(HStackLayout(spacing: Theme.Space.medium))
        layout {
            Text(label)
                .typeStep(.body)
                .foregroundStyle(Theme.ink2)
                .accessibilityHidden(true)
            if !stacked { Spacer(minLength: 0) }
            control
        }
        .padding(.leading, Theme.Space.s8)
        .padding(.vertical, stacked ? Theme.Space.s6 : 0)
        .frame(minHeight: Theme.tapTarget)
    }
}

/// Beautiful UI's segmented control: the label over a pill track with a lifted
/// thumb that slides to the choice. When the choices do not fit the row, it is
/// a form row: the label leading and a menu trailing, as the web companion's
/// provider field. VoiceOver hears a native picker either way.
private struct SegmentedChoice: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb
    let title: String
    @Binding var selection: String
    let items: [(id: String, name: String)]

    init(_ title: String, selection: Binding<String>, items: [(String, String)]) {
        self.title = title
        _selection = selection
        self.items = items.map { (id: $0.0, name: $0.1) }
    }

    private var selectedName: String { items.first { $0.id == selection }?.name ?? selection }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // The track keeps the rows' 8pt inset, in line with their labels and rules.
            VStack(alignment: .leading, spacing: Theme.Space.s6) {
                label
                track
            }
            .padding(.horizontal, Theme.Space.s8)
            .padding(.vertical, Theme.Space.s6)
            // At accessibility sizes the menu moves under the label, so its value keeps the width.
            menuLayout {
                label
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                MenuField(title: selectedName, monospaced: false) { picker }
            }
            .padding(.leading, Theme.Space.s8)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? Theme.Space.s6 : 0)
            .frame(minHeight: Theme.tapTarget)
        }
        .accessibilityRepresentation { picker }
    }

    private var menuLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s6))
            : AnyLayout(HStackLayout(spacing: Theme.Space.medium))
    }

    private var label: some View {
        Text(title)
            .typeStep(.body)
            .foregroundStyle(Theme.ink2)
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(items, id: \.id) { item in
                Text(item.name).tag(item.id)
            }
        }
    }

    private var track: some View {
        let dark = colorScheme == .dark
        return HStack(spacing: 0) {
            ForEach(items, id: \.id) { item in
                let selected = item.id == selection
                Button {
                    selection = item.id
                } label: {
                    Text(item.name)
                        .typeStep(.body, weight: .medium)
                        .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Theme.Space.medium)
                        .frame(maxWidth: .infinity, minHeight: Theme.tapTarget)
                        .background {
                            if selected {
                                Color.clear
                                    .surface(
                                        dark ? Theme.hover2 : Theme.surface, in: Capsule(style: .continuous),
                                        elevation: .button
                                    )
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Space.s2)
        .background(Capsule(style: .continuous).fill(dark ? Theme.page : Theme.hover2.opacity(0.6)))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.lineSoft, lineWidth: 1))
        .animation(Theme.animation(Theme.Motion.slide, reduceMotion: reduceMotion), value: selection)
    }
}

/// A native menu behind a field: the choice on the `field` fill with an
/// up-and-down chevron in `ink3`, as the web companion's picker draws it.
private struct MenuField<Content: View>: View {
    let title: String
    let monospaced: Bool
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Menu {
            content
        } label: {
            HStack(spacing: Theme.Space.small) {
                Text(title)
                    .typeStep(monospaced ? .mono : .body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.font(.small, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Space.medium)
            .frame(minHeight: Theme.tapTarget)
            .background(Theme.field, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

/// A row inside a form card: 44pt, `control` radius, the `hover2` fill while pressed.
private struct FormRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FormRowBody(configuration: configuration)
    }
}

private struct FormRowBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        configuration.label
            .padding(.horizontal, Theme.Space.s8)
            .frame(maxWidth: .infinity, minHeight: Theme.tapTarget, alignment: .leading)
            .background(shape.fill(Theme.hover2).opacity(configuration.isPressed ? 1 : 0))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(
                Theme.animation(Theme.Motion.fade, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// A message in words on its tint: a warning is `orangeInk` on the orange tint
/// with the caution mark; a failure is `redInk` on the red tint with the danger mark.
private struct Notice: View {
    enum Tone { case warning, failure }

    let text: String
    var tone: Tone = .warning

    var body: some View {
        let failure = tone == .failure
        Label {
            Text(text)
                .typeStep(.body)
                .foregroundStyle(failure ? Theme.redInk : Theme.orangeInk)
        } icon: {
            Image(systemName: failure ? Theme.dangerSymbol : Theme.cautionSymbol)
                .foregroundStyle(failure ? Theme.red : Theme.orange)
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            failure ? Theme.redTint : Theme.orangeTint,
            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
