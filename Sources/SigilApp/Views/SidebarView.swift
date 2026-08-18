import SigilKit
import SwiftUI

/// The thread viewer: every Grok Build conversation on this machine, newest first.
///
/// This list is the product. It is built for someone who keeps nine hundred
/// conversations and is looking for one they half-remember the name of, so density
/// and legible state beat everything else competing for the space.
struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette
    @FocusState private var isSearchFocused: Bool

    /// The history runs to thousands of rows; the sidebar shows the newest slice
    /// and search reaches the rest.
    private static let rowLimit = 400

    var body: some View {
        let sessions = model.sidebarSessions
        let shown = Array(sessions.prefix(Self.rowLimit))

        VStack(spacing: 0) {
            // The traffic lights live here. Nothing else may.
            Color.clear.frame(height: 36)
            searchRow
            list(buckets: SessionBucket.bucket(shown), isEmpty: sessions.isEmpty)
            footer(hidden: sessions.count - shown.count)
        }
        .background(palette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(palette.hairline).frame(width: 1) }
    }

    // MARK: - Search

    private var searchRow: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSearchFocused ? palette.textDim : palette.textFaint)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.text)
                    .focused($isSearchFocused)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.textFaint)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(palette.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isSearchFocused ? palette.accent.opacity(0.45) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            .animation(.easeOut(duration: 0.12), value: isSearchFocused)

            ScopeToggle(isOn: $model.scopeToCurrentFolder, folder: model.currentDirectory)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
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
                                state: state(of: session),
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
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
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

    private func state(of session: GrokSession) -> SessionRow.State {
        if session.id == model.activeSessionID { return .active }
        if model.openSessionIDs.contains(session.id) { return .open }
        return .closed
    }

    /// Empty states teach the interface rather than announcing the obvious.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.searchText.isEmpty ? "No conversations yet" : "No matches")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textDim)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
    }

    private var hint: String {
        if !model.searchText.isEmpty { return "Nothing matches “\(model.searchText)”." }
        if model.scopeToCurrentFolder { return "Turn off the folder filter to see the rest." }
        return "Press ⌘T to start one. It shows up here as soon as it has a name."
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
                .font(.system(size: 9.5, design: .monospaced))
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
        if hidden > 0 { return "\(total) threads · \(hidden) older" }
        return "\(total) threads"
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
            Image(systemName: isOn ? "folder.fill" : "folder")
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? palette.accent.opacity(0.14) : (isHovering ? palette.raised : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? palette.accent : (isHovering ? palette.textDim : palette.textFaint))
        .onHover { isHovering = $0 }
        .help(isOn ? "Showing only \(folder.abbreviatedPath)" : "Show only \(folder.abbreviatedPath)")
    }
}

private struct SessionRow: View {
    enum State {
        /// Not open in any tab.
        case closed
        /// Open in a background tab.
        case open
        /// The conversation on screen.
        case active
    }

    let session: GrokSession
    let state: State
    let open: () -> Void

    @Environment(\.palette) private var palette
    @SwiftUI.State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(marker)
                .frame(width: 2, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12, weight: state == .active ? .medium : .regular))
                    .foregroundStyle(state == .closed ? palette.textDim : palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Machine-written metadata is set in mono, so it reads as metadata
                // and not as a title that failed.
                Text("\(session.projectName) · \(session.updatedAt.shortRelative)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .padding(.vertical, 3.5)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .help("\(session.displayPath)\n\(session.messageCount) messages · \(session.id)")
    }

    private var marker: Color {
        switch state {
        case .active: return palette.accent
        case .open: return palette.accent.opacity(0.35)
        case .closed: return .clear
        }
    }

    private var fill: Color {
        if state == .active { return palette.selected }
        return isHovering ? palette.raised : .clear
    }
}
