import SigilKit
import SwiftUI

/// The thread viewer: every Grok Build conversation on this machine.
///
/// Recents is the time-ordered list. Projects is the same list grouped by
/// folder. Pins sit at the top of either sort. Archived chats leave both
/// until the archivebox in the header is turned on. The list is the product:
/// find one conversation in a history of hundreds, without leaving the keyboard.
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
    @State private var hoveredMode: SidebarMode?
    @Namespace private var modeUnderline

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 36)
            searchRow
            modeRow
            list
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
            await Task.yield()
            focus = .search
        }
        .onChange(of: model.searchText) { _, _ in clampKeyboardSelection() }
        .onChange(of: model.scopeToCurrentFolder) { _, _ in clampKeyboardSelection() }
        .onChange(of: model.showingArchived) { _, _ in clampKeyboardSelection() }
        .onChange(of: model.settings.sidebarMode) { _, _ in clampKeyboardSelection() }
        .onChange(of: model.settings.showWorktreeSessions) { _, _ in clampKeyboardSelection() }
        .onChange(of: model.settings.archivedConversations) { _, _ in clampKeyboardSelection() }
        .onChange(of: model.store.isLoading) { _, loading in
            if !loading { model.pruneMissingPins() }
        }
    }

    // MARK: - Search

    private var searchRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(focus == .search ? palette.textDim : palette.textFaint)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.text)
                .focused($focus, equals: .search)
                .onKeyPress(.downArrow) { moveFocusToList() }
                .onKeyPress(.escape) { handleEscape() }
                .onExitCommand { _ = handleEscape() }
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textFaint)
            } else if focus != .search {
                KbdChip(label: "⌘F", palette: palette)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
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
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.12), value: focus == .search)
        .animation(.easeOut(duration: 0.12), value: model.searchText.isEmpty)
    }

    // MARK: - Mode

    private var modeRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ForEach(SidebarMode.allCases) { mode in
                let selected = model.settings.sidebarMode == mode
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        model.settings.sidebarMode = mode
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(mode.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(
                                selected
                                    ? palette.text
                                    : (hoveredMode == mode ? palette.textDim : palette.textFaint)
                            )
                        ZStack {
                            Rectangle().fill(Color.clear).frame(height: 2)
                            if selected {
                                Rectangle()
                                    .fill(palette.text)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "mode", in: modeUnderline)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredMode = hovering ? mode : nil
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(
                    mode == .recents
                        ? "Sort conversations by time"
                        : "Sort conversations by project"
                )
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ArchiveToggle(isOn: $model.showingArchived, count: model.archivedCount)
                ScopeToggle(isOn: $model.scopeToCurrentFolder, folder: model.currentDirectory)
            }
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        let pinned = visiblePinned
        let content = listContent
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !pinned.isEmpty {
                        section("Pinned", count: pinned.count, isFirst: true) {
                            ForEach(pinned, id: \.directory) { session in
                                sessionRow(session, showsProject: true)
                            }
                        }
                    }
                    content
                    if pinned.isEmpty && isListEmpty { emptyState }
                }
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .list)
            .onKeyPress(.upArrow) { moveKeyboardSelection(by: -1) }
            .onKeyPress(.downArrow) { moveKeyboardSelection(by: 1) }
            .onKeyPress(.return) { activateKeyboardSelection() }
            .onKeyPress(.escape) { handleEscape() }
            .onChange(of: keyboardSelectionID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        let unpinned = model.unpinnedSessions(from: model.sidebarSessions)
        let afterPinned = !visiblePinned.isEmpty
        switch model.settings.sidebarMode {
        case .recents:
            recentsSections(from: unpinned, afterPinned: afterPinned)
        case .projects:
            projectGroupedSections(from: unpinned, afterPinned: afterPinned)
        }
    }

    @ViewBuilder
    private func recentsSections(from sessions: [GrokSession], afterPinned: Bool) -> some View {
        let buckets = SessionBucket.bucket(sessions)
        ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
            section(bucket.title, count: bucket.sessions.count, isFirst: !afterPinned && index == 0) {
                ForEach(bucket.sessions, id: \.directory) { session in
                    sessionRow(session, showsProject: true)
                }
            }
        }
    }

    @ViewBuilder
    private func projectGroupedSections(from sessions: [GrokSession], afterPinned: Bool) -> some View {
        // Keep AppModel's folder order (most recently active first), then drop
        // folders whose remaining rows are all pinned.
        let ordered = model.sidebarProjects.compactMap { project -> (id: String, name: String, rows: [GrokSession])? in
            let rows = sessions.filter { session in
                project.sessions.contains { $0.directory == session.directory }
            }
            return rows.isEmpty ? nil : (project.id, project.name, rows)
        }
        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, item in
            section(
                item.name, count: item.rows.count, isFirst: !afterPinned && index == 0, caps: false
            ) {
                ForEach(item.rows, id: \.directory) { session in
                    sessionRow(session, showsProject: false)
                }
            }
        }
    }

    private var visiblePinned: [GrokSession] {
        model.pinnedSessions()
    }

    private var isListEmpty: Bool {
        model.sidebarSessions.isEmpty
    }

    private func sessionRow(_ session: GrokSession, showsProject: Bool) -> some View {
        SessionRow(
            session: session,
            state: state(of: session),
            activity: model.activity(of: session),
            isPinned: model.isPinned(session),
            isArchived: model.isArchived(session),
            isKeyboardSelected: model.sessionKey(session) == keyboardSelectionID,
            showsProject: showsProject,
            open: {
                keyboardSelectionID = model.sessionKey(session)
                model.open(session)
            },
            togglePin: { model.togglePin(session) },
            toggleArchive: { model.toggleArchive(session) }
        )
        .id(model.sessionKey(session))
        .contextMenu {
            Button(model.isPinned(session) ? "Unpin" : "Pin") { model.togglePin(session) }
            Button(model.isArchived(session) ? "Unarchive" : "Archive") { model.toggleArchive(session) }
            Divider()
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

    private func section<Content: View>(
        _ title: String,
        count: Int,
        isFirst: Bool,
        caps: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            let label = caps ? "\(title.uppercased()) (\(count))" : "\(title) (\(count))"
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(caps ? 0.6 : 0)
                .foregroundStyle(palette.textFaint)
                .padding(.horizontal, 14)
                .padding(.top, isFirst ? 10 : 18)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.sidebar)
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(emptyTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textDim)
            emptyHint
                .font(.system(size: 11))
                .foregroundStyle(palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty { return "No matches" }
        if model.showingArchived { return "No archived conversations" }
        return "No conversations yet"
    }

    @ViewBuilder
    private var emptyHint: some View {
        if !model.searchText.isEmpty {
            Text("Nothing matches “\(model.searchText)”.")
        } else if model.scopeToCurrentFolder {
            Text("Turn off the folder filter to see the rest.")
        } else if model.showingArchived {
            Text("Archive a conversation from Recents or Projects to send it here.")
        } else {
            HStack(spacing: 4) {
                Text("Press")
                KbdChip(label: "⌘T", palette: palette)
                Text("to start one. It shows up here as soon as it has a name.")
            }
        }
    }

    // MARK: - Keyboard

    private func visibleRowIDs() -> [String] {
        visiblePinned.map { model.sessionKey($0) }
            + groupedUnpinnedSessions().map { model.sessionKey($0) }
    }

    /// Unpinned chats in the order the current sort draws them.
    private func groupedUnpinnedSessions() -> [GrokSession] {
        let unpinned = model.unpinnedSessions(from: model.sidebarSessions)
        switch model.settings.sidebarMode {
        case .recents:
            return unpinned
        case .projects:
            return model.sidebarProjects.flatMap { project in
                unpinned.filter { session in
                    project.sessions.contains { $0.directory == session.directory }
                }
            }
        }
    }

    private func handleEscape() -> KeyPress.Result {
        if !model.searchText.isEmpty {
            model.searchText = ""
            return .handled
        }
        focus = nil
        return .handled
    }

    private func moveFocusToList() -> KeyPress.Result {
        let ids = visibleRowIDs()
        guard !ids.isEmpty else { return .ignored }
        if keyboardSelectionID == nil || !ids.contains(keyboardSelectionID ?? "") {
            keyboardSelectionID = ids[0]
        }
        focus = .list
        return .handled
    }

    private func moveKeyboardSelection(by delta: Int) -> KeyPress.Result {
        let ids = visibleRowIDs()
        guard !ids.isEmpty else { return .ignored }
        if let current = keyboardSelectionID, let index = ids.firstIndex(of: current) {
            keyboardSelectionID = ids[min(max(index + delta, 0), ids.count - 1)]
        } else {
            keyboardSelectionID = delta >= 0 ? ids.first : ids.last
        }
        return .handled
    }

    private func activateKeyboardSelection() -> KeyPress.Result {
        guard let id = keyboardSelectionID, let session = session(for: id) else { return .ignored }
        model.open(session)
        return .handled
    }

    private func session(for id: String) -> GrokSession? {
        model.sidebarSessions.first { model.sessionKey($0) == id }
    }

    private func clampKeyboardSelection() {
        guard let id = keyboardSelectionID else { return }
        if !visibleRowIDs().contains(id) {
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
                .font(.system(size: 10, design: .monospaced))
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
        if model.showingArchived {
            let threads = model.sidebarSessions.count
            return threads == 1 ? "1 archived" : "\(threads) archived"
        }
        let threads = model.sidebarSessions.count
        let pinned = model.pinnedSessions().count
        if model.settings.sidebarMode == .projects {
            let folders = model.sidebarProjects.count
            if pinned > 0 {
                return "\(threads) threads · \(folders) projects · \(pinned) pinned"
            }
            return "\(threads) threads · \(folders) projects"
        }
        if pinned > 0 {
            return "\(threads) threads · \(pinned) pinned"
        }
        return "\(threads) threads"
    }
}

/// Shows archived conversations instead of Recents and Projects.
private struct ArchiveToggle: View {
    @Binding var isOn: Bool
    let count: Int

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    private var helpText: String {
        if isOn {
            return count == 1
                ? "Showing 1 archived conversation"
                : "Showing \(count) archived conversations"
        }
        if count == 0 { return "No archived conversations" }
        return count == 1
            ? "Show 1 archived conversation"
            : "Show \(count) archived conversations"
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "archivebox.fill" : "archivebox")
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            isOn
                                ? palette.accent.opacity(0.14)
                                : (isHovering ? palette.raised : Color.clear)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? palette.accent : (isHovering ? palette.textDim : palette.textFaint))
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            isOn
                                ? palette.accent.opacity(0.14)
                                : (isHovering ? palette.raised : Color.clear)
                        )
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
        case closed
        case open
        case active
    }

    let session: GrokSession
    let state: State
    let activity: TerminalTab.Activity?
    let isPinned: Bool
    let isArchived: Bool
    let isKeyboardSelected: Bool
    let showsProject: Bool
    let open: () -> Void
    let togglePin: () -> Void
    let toggleArchive: () -> Void

    @Environment(\.palette) private var palette
    @SwiftUI.State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: state == .active ? .medium : .regular))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let activity, activity == .working {
                StatusDot(activity: activity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isKeyboardSelected && state != .active ? palette.hairline : Color.clear,
                            lineWidth: 1
                        )
                )
        )
        .overlay(alignment: .topTrailing) { trailingOverlay }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .help(
            "\(session.title)\n\(session.displayPath)\n"
                + "\(session.messageCount) messages · \(session.updatedAt.longRelative)"
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            "\(session.title), \(session.projectName), \(session.updatedAt.longRelative)"
                + (isPinned ? ", pinned" : "")
                + (isArchived ? ", archived" : "")
        )
        .accessibilityAction(named: isPinned ? "Unpin" : "Pin") { togglePin() }
        .accessibilityAction(named: isArchived ? "Unarchive" : "Archive") { toggleArchive() }
        .accessibilityAction { open() }
    }

    private var subtitle: String {
        if showsProject {
            return "\(session.projectName) · \(session.updatedAt.shortRelative)"
        }
        return session.updatedAt.shortRelative
    }

    @ViewBuilder
    private var trailingOverlay: some View {
        if isHovering || isKeyboardSelected {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [fill.opacity(0), fill],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 14)
                HStack(spacing: 0) {
                    rowActionButton(
                        systemImage: isArchived ? "archivebox.fill" : "archivebox",
                        tinted: isArchived,
                        help: isArchived ? "Unarchive" : "Archive",
                        action: toggleArchive
                    )
                    rowActionButton(
                        systemImage: isPinned ? "pin.fill" : "pin",
                        tinted: isPinned,
                        help: isPinned ? "Unpin" : "Pin",
                        action: togglePin
                    )
                }
                .padding(.trailing, 8)
                .padding(.top, 4)
                .background(fill)
            }
        } else if isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(palette.accent.opacity(0.9))
                .padding(.trailing, 12)
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
    }

    private func rowActionButton(
        systemImage: String,
        tinted: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tinted ? palette.accent : palette.textDim)
        .help(help)
        .accessibilityLabel(help)
    }

    private var fill: Color {
        if state == .active { return palette.selected }
        return (isHovering || isKeyboardSelected) ? palette.raised : .clear
    }
}
