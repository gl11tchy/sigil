import SigilKit
import SwiftUI

/// The thread viewer: every Grok Build conversation on this machine, newest first.
struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette

    /// The history runs to thousands of rows; the sidebar shows the newest slice
    /// and search reaches the rest.
    private static let rowLimit = 400

    var body: some View {
        let sessions = model.sidebarSessions
        let shown = Array(sessions.prefix(Self.rowLimit))

        VStack(spacing: 0) {
            // The traffic lights live here. Nothing else may.
            Color.clear.frame(height: 38)
            searchRow
            list(buckets: SessionBucket.bucket(shown), isEmpty: sessions.isEmpty)
            footer(hidden: sessions.count - shown.count)
        }
        .background(palette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(palette.hairline).frame(width: 1) }
    }

    // MARK: - Search

    private var searchRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textFaint)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.text)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.textFaint)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(palette.raised))

            ScopeToggle(isOn: $model.scopeToCurrentFolder, folder: model.currentDirectory)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: - List

    @ViewBuilder
    private func list(buckets: [SessionBucket], isEmpty: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(buckets) { bucket in
                    Section {
                        ForEach(bucket.sessions) { session in
                            SessionRow(
                                session: session,
                                isOpen: model.openSessionIDs.contains(session.id),
                                open: { model.open(session) }
                            )
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
                    } header: {
                        Text(bucket.title.uppercased())
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(palette.textFaint)
                            .padding(.horizontal, 14)
                            .padding(.top, 9)
                            .padding(.bottom, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.sidebar)
                    }
                }
                if isEmpty { emptyState }
            }
            .padding(.bottom, 6)
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.searchText.isEmpty ? "No conversations" : "No matches")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textDim)
            Text(
                model.searchText.isEmpty
                    ? (model.scopeToCurrentFolder
                        ? "Nothing started in this folder yet."
                        : "Conversations you start show up here.")
                    : "Nothing matches “\(model.searchText)”."
            )
            .font(.system(size: 11))
            .foregroundStyle(palette.textFaint)
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
    }

    // MARK: - Footer

    private func footer(hidden: Int) -> some View {
        HStack(spacing: 5) {
            if model.store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
            }
            Text(statusText(hidden: hidden))
                .font(.system(size: 10))
                .foregroundStyle(
                    model.store.loadError == nil
                        ? AnyShapeStyle(palette.textFaint) : AnyShapeStyle(Color.red.opacity(0.85))
                )
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }

    private func statusText(hidden: Int) -> String {
        if let error = model.store.loadError { return error }
        let total = model.sidebarSessions.count
        if hidden > 0 { return "\(total) conversations · \(hidden) older" }
        return "\(total) conversations"
    }
}

/// Restricts the list to the folder the current session is working in.
private struct ScopeToggle: View {
    @Binding var isOn: Bool
    let folder: URL

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: "folder")
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? palette.accent.opacity(0.16) : (isHovering ? palette.raised : Color.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isOn ? palette.accent.opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? palette.accent : palette.textDim)
        .onHover { isHovering = $0 }
        .help(isOn ? "Showing only \(folder.abbreviatedPath)" : "Show only \(folder.abbreviatedPath)")
    }
}

private struct SessionRow: View {
    let session: GrokSession
    let isOpen: Bool
    let open: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1)
                .fill(isOpen ? palette.accent : Color.clear)
                .frame(width: 2, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isOpen ? palette.text : palette.text.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(session.projectName)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text("·")
                    Text(session.updatedAt.shortRelative)
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(palette.textFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? palette.raised : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .help("\(session.displayPath)\n\(session.messageCount) messages · \(session.id)")
    }
}
