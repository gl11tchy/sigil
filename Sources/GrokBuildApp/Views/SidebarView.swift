import GrokBuildKit
import SwiftUI

/// The thread viewer: every Grok Build conversation on this machine, newest first.
struct SidebarView: View {
    @Bindable var model: AppModel

    /// The history runs to thousands of rows; the sidebar shows the newest slice
    /// and search reaches the rest.
    private static let rowLimit = 400

    var body: some View {
        let sessions = model.sidebarSessions
        let shown = Array(sessions.prefix(Self.rowLimit))
        let buckets = SessionBucket.bucket(shown)

        List {
            scopePicker

            ForEach(buckets) { bucket in
                Section(bucket.title) {
                    ForEach(bucket.sessions) { session in
                        SessionRow(
                            session: session,
                            isOpen: model.openSessionIDs.contains(session.id)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { model.open(session) }
                        .contextMenu {
                            Button("Open in New Tab") { model.open(session) }
                            Divider()
                            Button("New Session in This Folder") {
                                model.newTab(in: URL(fileURLWithPath: session.cwd))
                            }
                            Button("Reveal Folder in Finder") { model.revealInFinder(session) }
                            Button("Copy Session ID") { model.copySessionID(session) }
                            Button("Export Transcript…") { model.exportTranscript(session) }
                        }
                    }
                }
            }

            if sessions.count > shown.count {
                Text("\(sessions.count - shown.count) older conversations — search to find them")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 4)
            }

            if sessions.isEmpty { emptyState }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search conversations")
        .safeAreaInset(edge: .bottom) { footer }
    }

    @ViewBuilder
    private var scopePicker: some View {
        Picker("Scope", selection: $model.scopeToCurrentFolder) {
            Text("All").tag(false)
            Text("This folder").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .listRowSeparator(.hidden)
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            model.searchText.isEmpty ? "No conversations" : "No matches",
            systemImage: model.searchText.isEmpty
                ? "bubble.left.and.bubble.right" : "magnifyingglass",
            description: Text(
                model.searchText.isEmpty
                    ? (model.scopeToCurrentFolder
                        ? "Nothing started in this folder yet."
                        : "Conversations you start will show up here.")
                    : "Nothing matches “\(model.searchText)”."
            )
        )
        .listRowSeparator(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.store.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(model.store.loadError ?? "\(model.sidebarSessions.count) conversations")
                .font(.caption)
                .foregroundStyle(
                    model.store.loadError == nil
                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red)
                )
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
                HStack(spacing: 4) {
                    Text(session.projectName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text("·")
                    Text(session.updatedAt.formatted(.relative(presentation: .numeric)))
                        .lineLimit(1)
                    Text("·")
                    Text("\(session.messageCount)")
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .help("\(session.displayPath)\n\(session.id)")
    }
}
