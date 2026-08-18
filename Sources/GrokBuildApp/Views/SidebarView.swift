import GrokBuildKit
import SwiftUI

/// The thread viewer: every Grok Build conversation on this machine, grouped by project.
struct SidebarView: View {
    @Bindable var model: AppModel

    /// Rendering every project at once is wasteful once the history grows into the
    /// hundreds; search reaches the rest.
    private static let groupLimit = 80

    @State private var expanded: Set<String> = []
    @State private var didSeedExpansion = false

    var body: some View {
        let groups = model.sidebarGroups
        let shown = Array(groups.prefix(Self.groupLimit))

        List {
            ForEach(shown, id: \.cwd) { group in
                Section(isExpanded: expansion(for: group.cwd)) {
                    ForEach(group.sessions) { session in
                        SessionRow(
                            session: session,
                            isOpen: model.openSessionIDs.contains(session.id)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { model.open(session) }
                        .contextMenu {
                            Button("Open in New Tab") { model.open(session) }
                            Divider()
                            Button("Reveal Folder in Finder") { model.revealInFinder(session) }
                            Button("Copy Session ID") { model.copySessionID(session) }
                            Button("Export Transcript…") { model.exportTranscript(session) }
                        }
                    }
                } header: {
                    ProjectHeader(cwd: group.cwd, count: group.sessions.count)
                }
            }

            if groups.count > shown.count {
                Text("\(groups.count - shown.count) more projects — search to find them")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }

            if groups.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "No sessions yet" : "No matches",
                    systemImage: model.searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                    description: Text(
                        model.searchText.isEmpty
                            ? "Conversations you start will show up here."
                            : "No conversation matches “\(model.searchText)”."
                    )
                )
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search conversations")
        .task { seedExpansion(shown.map(\.cwd)) }
        .onChange(of: shown.map(\.cwd)) { _, cwds in seedExpansion(cwds) }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.store.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(model.store.loadError ?? "\(model.store.sessions.count) conversations")
                .font(.caption)
                .foregroundStyle(model.store.loadError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Opens the most recent few projects, once, so the sidebar is not a wall of headers.
    private func seedExpansion(_ cwds: [String]) {
        guard !didSeedExpansion, !cwds.isEmpty else { return }
        didSeedExpansion = true
        expanded = Set(cwds.prefix(3))
    }

    private func expansion(for cwd: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(cwd) },
            set: { isOn in
                if isOn { expanded.insert(cwd) } else { expanded.remove(cwd) }
            }
        )
    }
}

private struct ProjectHeader: View {
    let cwd: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(URL(fileURLWithPath: cwd).lastPathComponent)
                .lineLimit(1)
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .help(cwd)
    }
}

private struct SessionRow: View {
    let session: GrokSession
    let isOpen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(isOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(session.updatedAt.formatted(.relative(presentation: .numeric)))
                    Text("·")
                    Text("\(session.messageCount)")
                        .monospacedDigit()
                    if let model = session.modelID, !model.isEmpty {
                        Text("·")
                        Text(model)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help(session.displayPath)
    }
}
