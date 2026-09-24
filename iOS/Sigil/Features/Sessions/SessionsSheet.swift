import SwiftUI

/// Open tabs on the Mac, plus every saved chat, newest first and searchable.
struct SessionsSheet: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onNew: () -> Void
    @State private var query = ""
    @State private var renaming: RemoteTab?
    @State private var newName = ""
    @State private var closing: RemoteTab?

    private var matches: [RemoteTab] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.tabs }
        return store.tabs.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if matches.isEmpty {
                        Text(store.tabs.isEmpty ? "No open sessions." : "No matching sessions.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(matches) { tab in
                        Button {
                            store.select(tab)
                            dismiss()
                        } label: {
                            row(title: tab.title, detail: detail(for: tab), status: tab.status,
                                selected: tab.id == store.selectedTabID)
                        }
                        .disabled(!store.isConnected || store.busy)
                        .accessibilityAddTraits(tab.id == store.selectedTabID ? .isSelected : [])
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if store.supportsSessionOps {
                                Button(role: .destructive) {
                                    closing = tab
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                                if tab.canArchive == true {
                                    Button {
                                        store.archive(tab)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(Theme.caution)
                                }
                                Button {
                                    newName = tab.title
                                    renaming = tab
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(Theme.accentDeep)
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
                                if tab.canArchive == true {
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
                    Text(store.macName.map { "Open on \($0)" } ?? "Open on your Mac")
                }

                Section {
                    if store.loadingChats, store.chats.isEmpty {
                        HStack(spacing: Theme.Space.small) {
                            ProgressView()
                            Text(searching ? "Searching…" : "Loading…").foregroundStyle(Theme.secondaryText)
                        }
                    } else if store.chats.isEmpty {
                        Text(!store.isConnected ? "Reconnecting…" : searching ? "No matching chats." : "No saved chats.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(store.chats) { chat in
                        Button {
                            store.open(chat)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat.title)
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(2)
                                Text(chat.folder)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .padding(.vertical, 2)
                        }
                        .disabled(!store.isConnected || store.busy)
                    }
                    if store.chatList.hasMore {
                        Button {
                            store.loadMoreChats()
                        } label: {
                            HStack(spacing: Theme.Space.small) {
                                Text("Show more")
                                if store.loadingChats { ProgressView() }
                            }
                        }
                        .disabled(!store.isConnected || store.loadingChats)
                    }
                } header: {
                    Text(searching ? "Saved chats" : "Recent chats")
                }
            }
            .privacySensitive()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions and chats")
            .onChange(of: query) { _, value in store.loadChats(value) }
            .onChange(of: store.isConnected) { _, connected in
                if connected, store.chats.isEmpty { store.loadChats(query) }
            }
            .onAppear { store.loadChats(query) }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onNew()
                    } label: {
                        Label("New session", systemImage: "plus")
                    }
                    .disabled(!store.isConnected || store.busy)
                }
            }
            .onDisappear { store.clearChats() }
        }
        .presentationDetents([.medium, .large])
    }

    /// "Claude Code · Working · sigil/feature"; older Macs send status only.
    private func detail(for tab: RemoteTab) -> String {
        [tab.providerName, tab.status.label, tab.folder].compactMap { $0 }.joined(separator: " · ")
    }

    private func row(title: String, detail: String, status: TabStatus, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.small) {
            Circle()
                .fill(Theme.color(for: status))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

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
            List {
                if let options { agentSection(options) }
                projectSection
            }
            .privacySensitive()
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .disabled(!canStart)
                }
            }
            .task { await load() }
            .onChange(of: store.isConnected) { _, connected in
                // Opened while reconnecting: the provider list and projects arrive now.
                if connected, store.sessionOptions == nil { Task { await load() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func agentSection(_ options: NewSessionOptions) -> some View {
        Section {
            Picker("Provider", selection: $providerID) {
                ForEach(options.providers) { item in
                    Text(item.name).tag(item.id)
                }
            }
            if takesModel {
                Picker("Model", selection: $model) {
                    Text("CLI default").tag("")
                    ForEach(Self.unique(options.models), id: \.self) { name in
                        Text(name).monospaced().tag(name)
                    }
                }
                Picker("Effort", selection: $effort) {
                    ForEach(options.efforts) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
            }
        } header: {
            Text("Agent")
        } footer: {
            if let problem = provider?.problem {
                Label(problem, systemImage: Theme.cautionSymbol)
                    .foregroundStyle(Theme.caution)
            }
        }
        .disabled(!store.isConnected || store.busy)
    }

    private var projectSection: some View {
        Section {
            if let locations = options?.locations, !locations.isEmpty {
                NavigationLink {
                    NewProjectForm(locations: locations) { created in target = .project(created.folder) }
                } label: {
                    Label("New project", systemImage: "folder.badge.plus")
                        .foregroundStyle(Theme.accent)
                }
                .disabled(!store.isConnected || store.busy)
            }
            if loading, store.projects.isEmpty {
                HStack(spacing: Theme.Space.small) {
                    ProgressView()
                    Text("Loading projects…").foregroundStyle(Theme.secondaryText)
                }
            } else if store.projects.isEmpty {
                choice(
                    "Current folder", detail: "The folder Sigil uses for a new session", monospaced: false,
                    target: .currentFolder)
            }
            ForEach(store.projects) { project in
                choice(project.name, detail: project.folder, monospaced: true, target: .project(project.folder))
            }
            if store.projectsTruncated, !store.projects.isEmpty {
                Button("More projects") {
                    Task { _ = await store.loadProjects(from: store.projects.count) }
                }
                .disabled(!store.isConnected || store.busy)
            }
            if canUseWorktree {
                Toggle("Start in a new worktree", isOn: $inWorktree)
                    .disabled(!store.isConnected || store.busy)
            }
        } header: {
            Text("Project")
        } footer: {
            if let error = store.errorMessage {
                Label(error, systemImage: Theme.cautionSymbol)
                    .foregroundStyle(Theme.caution)
            } else if canUseWorktree, inWorktree {
                Text("A fresh checkout on its own branch, under ~/.sigil/worktrees, as the Mac does.")
            }
        }
    }

    private func choice(_ title: String, detail: String, monospaced: Bool, target choice: Target) -> some View {
        Button {
            target = choice
        } label: {
            HStack(spacing: Theme.Space.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Theme.primaryText)
                    Text(detail)
                        .font(monospaced ? .caption.monospaced() : .caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                if target == choice {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 2)
        }
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
        Form {
            Section {
                TextField("Folder name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit(create)
            } header: {
                Text("Name")
            } footer: {
                if validName == nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Use a name without slashes, colons or a leading dot.")
                } else if let validName, let place {
                    Text(place.name == "~" ? "~/\(validName)" : "\(place.name)/\(validName)")
                        .monospaced()
                }
            }
            Section("Location") {
                ForEach(locations) { item in
                    Button {
                        location = item.folder
                    } label: {
                        HStack {
                            Text(item.name)
                                .font(.body.monospaced())
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 0)
                            if item.folder == location {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityAddTraits(item.folder == location ? .isSelected : [])
                }
            }
            if let problem {
                Section {
                    Label(problem, systemImage: Theme.cautionSymbol)
                        .foregroundStyle(Theme.caution)
                }
            }
        }
        .privacySensitive()
        .disabled(creating)
        .navigationTitle("New project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if creating {
                    ProgressView()
                } else {
                    Button("Create", action: create)
                        .disabled(validName == nil || place == nil || !store.isConnected || store.busy)
                }
            }
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
