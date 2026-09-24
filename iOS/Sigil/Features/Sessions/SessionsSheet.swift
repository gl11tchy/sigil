import SwiftUI

/// Open tabs on the Mac, plus a search across every saved chat.
struct SessionsSheet: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onNew: () -> Void
    @State private var query = ""

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
                            row(title: tab.title, detail: tab.status.label, status: tab.status,
                                selected: tab.id == store.selectedTabID)
                        }
                        .disabled(!store.isConnected || store.busy)
                        .accessibilityAddTraits(tab.id == store.selectedTabID ? .isSelected : [])
                    }
                } header: {
                    Text("Open on your Mac")
                }

                if searching {
                    Section {
                        if store.searchingChats, store.chats.isEmpty {
                            HStack(spacing: Theme.Space.small) {
                                ProgressView()
                                Text("Searching…").foregroundStyle(Theme.secondaryText)
                            }
                        } else if store.chats.isEmpty {
                            Text("No matching chats.")
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
                        if store.chatsTruncated, !store.chats.isEmpty {
                            Text("Showing the first matches. Narrow the search for more.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    } header: {
                        Text("Saved chats")
                    }
                }
            }
            .privacySensitive()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions and chats")
            .onChange(of: query) { _, value in store.searchChats(value) }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
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
            .onDisappear { store.searchChats("") }
        }
        .presentationDetents([.medium, .large])
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

/// Pick the project folder for a new session.
struct NewSessionSheet: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if loading, store.projects.isEmpty {
                    HStack(spacing: Theme.Space.small) {
                        ProgressView()
                        Text("Loading projects…").foregroundStyle(Theme.secondaryText)
                    }
                } else if store.projects.isEmpty {
                    Button {
                        start(nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Current folder").foregroundStyle(Theme.primaryText)
                            Text("The folder Sigil uses for a new session")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                ForEach(store.projects) { project in
                    Button {
                        start(project)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .foregroundStyle(Theme.primaryText)
                            Text(project.folder)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .padding(.vertical, 2)
                    }
                }
                if store.projectsTruncated, !store.projects.isEmpty {
                    Button("More projects") {
                        Task { _ = await store.loadProjects(from: store.projects.count) }
                    }
                }
            }
            .privacySensitive()
            .disabled(!store.isConnected || store.busy)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if store.isDemo {
                    loading = false
                    return
                }
                let supported = await store.loadProjects()
                loading = false
                // A Mac without the project list starts New in its current folder.
                if !supported { start(nil) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func start(_ project: RemoteProject?) {
        store.newSession(in: project)
        dismiss()
    }
}
