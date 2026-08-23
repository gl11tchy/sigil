import SigilKit
import SwiftUI

/// The thread viewer: every Grok Build conversation on this machine, newest first.
///
/// This list is the product. It is built for someone who keeps nine hundred
/// conversations and is looking for one they half-remember the name of, so density
/// and legible state beat everything else competing for the space.
struct SidebarView: View {
    private enum Focus: Hashable {
        case search
        case list
    }

    @Bindable var model: AppModel
    @Environment(\.palette) private var palette
    @FocusState private var focus: Focus?
    /// Arrow-key highlight. Separate from open/active so those markers stay
    /// about the tab strip, not about where the keys are.
    @State private var keyboardSelectionID: String?
    @State private var pendingDelete: GrokSession?

    var body: some View {
        let sessions = model.sidebarSessions
        // LazyVStack keeps a large history cheap without making older matches
        // unreachable behind an arbitrary row cap.
        let shown = sessions

        VStack(spacing: 0) {
            // The traffic lights live here. Nothing else may.
            Color.clear.frame(height: 36)
            searchRow(shown: shown)
            list(shown: shown, buckets: SessionBucket.bucket(shown), isEmpty: sessions.isEmpty)
            footer
        }
        .background(palette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(palette.hairline).frame(width: 1) }
        .alert(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { session in
            Button("Move to Trash", role: .destructive) {
                if model.deleteConversation(session),
                    keyboardSelectionID == model.sessionKey(session)
                {
                    keyboardSelectionID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: model.searchFocusToken) {
            guard model.searchFocusToken > 0 else { return }
            // The field is not in the hierarchy until the sidebar has been shown.
            await Task.yield()
            focus = .search
        }
        .onChange(of: model.searchText) { _, _ in clampKeyboardSelection() }
        .onChange(of: model.scopeToCurrentFolder) { _, _ in clampKeyboardSelection() }
    }

    // MARK: - Search

    private func searchRow(shown: [GrokSession]) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(focus == .search ? palette.textDim : palette.textFaint)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.text)
                    .focused($focus, equals: .search)
                    .onKeyPress(.downArrow) { moveFocusToList(shown: shown) }
                    .onKeyPress(.escape) {
                        clearSearch()
                        return .handled
                    }
                    .onExitCommand { clearSearch() }
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
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
                                focus == .search ? palette.accent.opacity(0.45) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            .animation(.easeOut(duration: 0.12), value: focus == .search)

            ScopeToggle(isOn: $model.scopeToCurrentFolder, folder: model.currentDirectory)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: - List

    @ViewBuilder
    private func list(shown: [GrokSession], buckets: [SessionBucket], isEmpty: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(buckets) { bucket in
                        Section {
                            ForEach(Array(bucket.sessions.enumerated()), id: \.element.directory) { index, session in
                                SessionRow(
                                    session: session,
                                    state: state(of: session),
                                    isKeyboardSelected:
                                        model.sessionKey(session) == keyboardSelectionID,
                                    // The last row in a bucket runs into a section
                                    // header, which is its own separation.
                                    showsDivider: index < bucket.sessions.count - 1,
                                    open: {
                                        keyboardSelectionID = model.sessionKey(session)
                                        model.open(session)
                                    }
                                )
                                .id(model.sessionKey(session))
                                .contextMenu {
                                    Button("Open in New Tab") { model.open(session) }
                                    Divider()
                                    Button("New Session in This Folder") {
                                        model.newTab(in: URL(fileURLWithPath: session.cwd))
                                    }
                                    Button("Reveal Folder in Finder") { model.revealInFinder(session) }
                                    Button("Copy Session ID") { model.copySessionID(session) }
                                    Button("Export Transcript…") { model.exportTranscript(session) }
                                    Divider()
                                    Button("Delete Conversation…", role: .destructive) {
                                        pendingDelete = session
                                    }
                                }
                            }
                        } header: {
                            Text(bucket.title.uppercased())
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .tracking(0.5)
                                .foregroundStyle(palette.textFaint)
                                .padding(.horizontal, 14)
                                .padding(.top, 16)
                                .padding(.bottom, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(palette.sidebar)
                        }
                    }
                    if isEmpty { emptyState }
                }
                .padding(.bottom, 6)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .list)
            .onKeyPress(.upArrow) { moveKeyboardSelection(in: shown, by: -1) }
            .onKeyPress(.downArrow) { moveKeyboardSelection(in: shown, by: 1) }
            .onKeyPress(.return) { openKeyboardSelection(in: shown) }
            .onChange(of: keyboardSelectionID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func state(of session: GrokSession) -> SessionRow.State {
        if model.isActive(session) { return .active }
        if model.isOpen(session) { return .open }
        return .closed
    }

    private var deleteConfirmationTitle: String {
        guard let pendingDelete else { return "Move this conversation to Trash?" }
        if model.shouldWarnBeforeDeleting(pendingDelete) {
            return "Stop this working session and move it to Trash?"
        }
        if model.isRunning(pendingDelete) {
            return "Close this session and move it to Trash?"
        }
        return "Move this conversation to Trash?"
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

    // MARK: - Keyboard

    private func clearSearch() {
        model.searchText = ""
        focus = nil
    }

    private func moveFocusToList(shown: [GrokSession]) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        if keyboardSelectionID == nil
            || !shown.contains(where: { model.sessionKey($0) == keyboardSelectionID })
        {
            keyboardSelectionID = model.sessionKey(shown[0])
        }
        focus = .list
        return .handled
    }

    private func moveKeyboardSelection(in shown: [GrokSession], by delta: Int) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        let ids = shown.map(model.sessionKey)
        if let current = keyboardSelectionID, let index = ids.firstIndex(of: current) {
            keyboardSelectionID = ids[min(max(index + delta, 0), ids.count - 1)]
        } else {
            keyboardSelectionID = delta >= 0 ? ids.first : ids.last
        }
        return .handled
    }

    private func openKeyboardSelection(in shown: [GrokSession]) -> KeyPress.Result {
        guard let id = keyboardSelectionID,
            let session = shown.first(where: { model.sessionKey($0) == id })
        else { return .ignored }
        model.open(session)
        return .handled
    }

    private func clampKeyboardSelection() {
        guard let id = keyboardSelectionID else { return }
        if !model.sidebarSessions.contains(where: { model.sessionKey($0) == id }) {
            keyboardSelectionID = nil
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 5) {
            if model.store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
            }
            Text(statusText)
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

    private var statusText: String {
        if let error = model.store.loadError { return error }
        return "\(model.sidebarSessions.count) threads"
    }
}

/// Restricts the list to the folder the current session is working in.
private struct ScopeToggle: View {
    @Binding var isOn: Bool
    let folder: URL

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    private var helpText: String {
        isOn ? "Showing only \(folder.abbreviatedPath)" : "Show only \(folder.abbreviatedPath)"
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
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
        .help(helpText)
        .accessibilityLabel(helpText)
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
    let isKeyboardSelected: Bool
    let showsDivider: Bool
    let open: () -> Void

    @Environment(\.palette) private var palette
    @SwiftUI.State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(marker)
                    .frame(width: 2, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 12, weight: state == .active ? .medium : .regular))
                        .foregroundStyle(state == .closed ? palette.textDim : palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Machine-written metadata is set in mono, so it reads as
                    // metadata and not as a title that failed.
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
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))

            // A rule between items, so neighbouring rows are separate things
            // rather than one block of text.
            Rectangle()
                .fill(showsDivider ? palette.hairline : Color.clear)
                .frame(height: 1)
                .padding(.leading, 17)
                .padding(.trailing, 10)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .help(
            "\(session.title)\n\(session.displayPath)\n"
                + "\(session.messageCount) messages · \(session.updatedAt.shortRelative)"
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            "\(session.title), \(session.projectName), \(session.updatedAt.shortRelative)"
        )
        .accessibilityAction { open() }
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
        // Keyboard selection uses the hover fill so it stays distinct from
        // the open/active markers, which are the accent bar and selected fill.
        return (isHovering || isKeyboardSelected) ? palette.raised : .clear
    }
}
