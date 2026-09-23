import AppKit
import SigilKit
import SwiftUI

private enum SidebarFocus: Hashable {
    case search
    case list
    case rename
}

/// Sidebar row light: work in flight, or a finished turn that has not been read.
enum SidebarActivityDot {
    static func isVisible(
        activity: TerminalTab.Activity?,
        hasUnseenActivity: Bool,
        isActive: Bool
    ) -> Bool {
        guard let activity else { return false }
        if activity == .working { return true }
        return hasUnseenActivity && !isActive
    }
}

/// VoiceOver value for a folder row. The row combines its children, so the
/// working dot and the pin glyph are spoken here or not at all.
enum ProjectRowAccessibility {
    static func value(countLabel: String, isActive: Bool, isWorking: Bool, isPinned: Bool)
        -> String
    {
        var value = countLabel
        if isActive { value += ", one open" }
        if isWorking { value += ", working" }
        if isPinned { value += ", pinned" }
        return value
    }
}

/// The thread viewer: every Grok Build conversation on this machine.
///
/// Home is the project list. Recents and Archived sit under it as destinations
/// you open. A plus on a folder starts a chat there. Archive lives on the row.
struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette
    @FocusState private var focus: SidebarFocus?
    /// Arrow-key highlight. Separate from open/active so those markers stay
    /// about the tab strip, not about where the keys are.
    @State private var keyboardSelectionID: String?
    @State private var pendingDelete: GrokSession?
    /// ⌘/⇧-click multi-selection over the visible chat rows, for bulk archive
    /// and delete. Keys are `sessionKey`s; the anchor starts a ⇧ range.
    @State private var multiSelection: Set<String> = []
    @State private var selectionAnchor: String?
    @State private var pendingBulkDelete: [GrokSession]?
    /// Minute tick for relative times and Today/Yesterday buckets.
    @State private var now = Date()

    /// F2. Unicode private-use scalar for `NSF2FunctionKey`.
    private static let f2 = KeyEquivalent(Character("\u{F705}"))

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 36)
            searchRow
            modeArea
            list
            if showsDestinations { destinations }
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
        .alert(
            bulkDeleteTitle,
            isPresented: Binding(
                get: { pendingBulkDelete != nil },
                set: { if !$0 { pendingBulkDelete = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let sessions = pendingBulkDelete {
                    model.deleteConversations(sessions)
                }
                clearMultiSelection()
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: model.searchFocusToken) {
            await Task.yield()
            guard !Task.isCancelled, model.consumeSearchFocusRequest() else { return }
            focus = .search
        }
        .task(id: model.renamePrepareTaskID) {
            await prepareRename(
                forceReconfigure: model.renamingSessionKey != model.preparedRenameKey)
        }
        .task(id: visibleRowIDs()) {
            clampKeyboardSelection()
            pruneMultiSelection()
            await prepareRename(forceReconfigure: false)
        }
        .onChange(of: model.searchText) { _, query in
            let top = visibleRowIDs().first
            switch SidebarOrganization.selectionAfterQueryChange(query: query, topRowID: top) {
            case .keep:
                break
            case .row(let id):
                keyboardSelectionID = id
            }
        }
        .task {
            await restorePromptOnAppear()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
    }

    // MARK: - Search

    private var searchRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(focus == .search ? palette.textDim : palette.textFaint)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.text)
                    .focused($focus, equals: .search)
                    .onSubmit(activateSearchResult)
                    .onKeyPress(.downArrow) { moveFocusToList() }
                    .onKeyPress(Self.f2) { renameKeyboardSelection() }
                    .onKeyPress(.escape) { handleEscape() }
                    .onExitCommand { _ = handleEscape() }
                    .accessibilityLabel("Search conversations")
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.textFaint)
                    .accessibilityLabel("Clear conversation search")
                    .help("Clear search")
                } else if focus != .search {
                    KbdChip(label: "⌘⇧F", palette: palette)
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
                                focus == .search ? palette.accent : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            IconButton(
                systemImage: "plus",
                help: "New Session in \(model.newSessionDirectory.abbreviatedPath) (⌘T)"
            ) {
                model.requestNewSession()
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.12), value: focus == .search)
        .animation(.easeOut(duration: 0.12), value: model.searchText.isEmpty)
    }

    // MARK: - Mode

    @ViewBuilder
    private var modeArea: some View {
        switch model.sidebarSurface {
        case .project:
            if let project = model.focusedProject {
                DrillBar(
                    title: project.name,
                    isPinned: model.isPinned(project),
                    showsPin: true,
                    showsArchive: true,
                    canStart: true,
                    leave: { model.leaveProject() },
                    newChat: { model.requestNewSessionInProject(project) },
                    togglePin: { model.togglePin(project) },
                    toggleArchive: { model.archive(project) }
                )
            }
        case .recents:
            DrillBar(
                title: "Recents",
                leave: { model.leaveProject() }
            )
        case .archived:
            DrillBar(
                title: "Archived",
                leave: { model.leaveProject() }
            )
        case .folders:
            EmptyView()
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        let pinned = visiblePinned
        let projectIndex = SidebarOrganization.indexByDirectory(model.sidebarProjects)
        let content = listContent(projectIndex: projectIndex)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if listKind == .projectList, !model.tabs.isEmpty {
                        section("Open", count: model.tabs.count, isFirst: true) {
                            ForEach(model.tabs) { tab in
                                openTabRow(tab)
                            }
                        }
                    }
                    if listKind != .projectList, listKind != .search, !pinned.isEmpty {
                        section("Pinned", count: pinned.count, isFirst: true) {
                            ForEach(pinned, id: \.directory) { session in
                                sessionRow(
                                    session,
                                    showsProject: listKind != .projectChats,
                                    containingProject: projectIndex[session.directory]
                                )
                            }
                        }
                    }
                    content
                    if (listKind == .projectList || pinned.isEmpty) && isListEmpty { emptyState }
                }
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .list)
            .onKeyPress(.upArrow) {
                if model.renamingSessionKey != nil { return .ignored }
                return moveKeyboardSelection(by: -1)
            }
            .onKeyPress(.downArrow) {
                if model.renamingSessionKey != nil { return .ignored }
                return moveKeyboardSelection(by: 1)
            }
            .onKeyPress(.return) {
                if model.renamingSessionKey != nil { return .ignored }
                return activateKeyboardSelection()
            }
            .onKeyPress(Self.f2) { renameKeyboardSelection() }
            .onKeyPress(.escape) { handleEscape() }
            .onChange(of: keyboardSelectionID) { _, id in
                // No anchor: scroll only as far as needed to reveal the row, so a
                // click on a visible row leaves the list where it is.
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: model.renamingSessionKey) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .alert(
            "Rename Conversation",
            isPresented: Binding(
                get: { model.showRenameAlert },
                set: { newValue in
                    // Sidebar teardown (⌘B) and the forceRepresent pulse must
                    // not cancel or wipe the draft.
                    guard
                        AppModel.shouldApplyRenameAlertPresentedChange(
                            sidebarVisible: model.isSidebarVisible,
                            pulsing: model.renameAlertIsPulsing
                        )
                    else { return }
                    model.showRenameAlert = newValue
                    if !newValue,
                        AppModel.shouldCancelRenameAlert(didCommit: model.renameAlertDidCommit)
                    {
                        let generation = model.renameAlertDismissGeneration
                        Task { await model.deferCancelRenameAlert(expectedGeneration: generation) }
                    }
                }
            ),
            presenting: model.renameAlertSession
        ) { session in
            RenameAlertDraftField(model: model)
            Button("Rename") {
                commitRenameAlert(session)
            }
            .modifier(
                RenameAlertDefaultCommit(
                    enabled: AppModel.renameAlertCommitUsesDefaultAction()
                )
            )
            if model.hasCustomName(session) {
                Button("Reset Name") { resetNameAlert(session) }
            }
            Button("Cancel", role: .cancel) { cancelRenameAlert() }
        }
    }

    @ViewBuilder
    private func listContent(projectIndex: [URL: SidebarProject]) -> some View {
        let unpinned = model.unpinnedSessions(from: listedSessions)
        let afterPinned = listKind != .projectList && !visiblePinned.isEmpty
        switch listKind {
        case .recents:
            recentsSections(from: unpinned, afterPinned: afterPinned, projectIndex: projectIndex)
        case .projectList:
            projectList
        case .projectChats:
            ForEach(unpinned, id: \.directory) { session in
                sessionRow(
                    session,
                    showsProject: false,
                    containingProject: projectIndex[session.directory]
                )
            }
        case .search:
            ForEach(listedSessions, id: \.directory) { session in
                sessionRow(
                    session,
                    showsProject: true,
                    containingProject: projectIndex[session.directory]
                )
            }
        case .archived:
            projectGroupedSections(from: unpinned, afterPinned: afterPinned)
        }
    }

    private var listKind: SidebarListKind {
        SidebarOrganization.listKind(
            surface: model.sidebarSurface,
            isSearching: SidebarOrganization.isSearching(model.searchText)
        )
    }

    private var listedSessions: [GrokSession] {
        listKind == .projectChats ? model.focusedSidebarSessions : model.sidebarSessions
    }

    @ViewBuilder
    private var projectList: some View {
        // Home folders are grouped from the listed sessions, so no row needs a filter.
        let pinned = model.pinnedProjects().map { ProjectRows(project: $0, rows: $0.sessions) }
        let rest = model.unpinnedProjects().map { ProjectRows(project: $0, rows: $0.sessions) }
        ForEach(pinned, id: \.id) { item in
            projectRow(item.project, rows: item.rows)
        }
        ForEach(rest, id: \.id) { item in
            projectRow(item.project, rows: item.rows)
        }
    }

    private var showsDestinations: Bool {
        listKind == .projectList && !destinationIDs.isEmpty
    }

    private var destinationIDs: [String] {
        SidebarOrganization.destinationRowIDs(
            recentsCount: listedSessions.count,
            archivedCount: model.archivedCount
        )
    }

    @ViewBuilder
    private var destinations: some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.hairline).frame(height: 1)
            if listedSessions.count > 0 {
                destinationRow(
                    id: SidebarOrganization.recentsID,
                    icon: "clock",
                    title: "Recents",
                    count: listedSessions.count,
                    help: "All conversations, newest first",
                    open: { model.openRecents() }
                )
            }
            if model.archivedCount > 0 {
                destinationRow(
                    id: SidebarOrganization.archivedID,
                    icon: "archivebox",
                    title: "Archived",
                    count: model.archivedCount,
                    help: "Archived conversations",
                    open: { model.openArchived() }
                )
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func recentsSections(
        from sessions: [GrokSession],
        afterPinned: Bool,
        projectIndex: [URL: SidebarProject]
    ) -> some View {
        let buckets = SessionBucket.bucket(sessions, now: now)
        ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
            section(bucket.title, count: bucket.sessions.count, isFirst: !afterPinned && index == 0) {
                ForEach(bucket.sessions, id: \.directory) { session in
                    sessionRow(
                        session,
                        showsProject: true,
                        containingProject: projectIndex[session.directory]
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func projectGroupedSections(from sessions: [GrokSession], afterPinned: Bool) -> some View {
        // Pinned folders first (pin order), then remaining folders in recency
        // order. Drop folders whose remaining rows are all pinned chats.
        let pinned = visibleProjects(model.pinnedProjects(), from: sessions)
        let rest = visibleProjects(model.unpinnedProjects(), from: sessions)
        ForEach(Array(pinned.enumerated()), id: \.element.id) { index, item in
            projectSection(item.project, rows: item.rows, isFirst: !afterPinned && index == 0)
        }
        ForEach(Array(rest.enumerated()), id: \.element.id) { index, item in
            projectSection(
                item.project, rows: item.rows, isFirst: !afterPinned && pinned.isEmpty && index == 0)
        }
    }

    private func visibleProjects(
        _ projects: [SidebarProject], from sessions: [GrokSession]
    ) -> [ProjectRows] {
        let listed = Set(sessions.map(\.directory))
        return projects.compactMap { project in
            let rows = SidebarOrganization.listedRows(in: project, listed: listed)
            return rows.isEmpty ? nil : ProjectRows(project: project, rows: rows)
        }
    }

    @ViewBuilder
    private func projectSection(
        _ project: SidebarProject, rows: [GrokSession], isFirst: Bool
    ) -> some View {
        let paths = SidebarOrganization.pathHaystacks(
            name: project.name,
            displayPath: project.displayPath,
            cwd: project.cwd,
            sessions: rows
        )
        let headerCovers = SearchMatchHighlight.projectHeader(
            name: project.name,
            paths: paths,
            count: rows.count,
            query: model.searchText
        ).paints
        Section {
            ForEach(rows, id: \.directory) { session in
                sessionRow(
                    session,
                    showsProject: false,
                    headerCoversQuery: headerCovers,
                    containingProject: project
                )
            }
        } header: {
            ProjectSectionHeader(
                title: project.name,
                paths: paths,
                count: rows.count,
                searchQuery: model.searchText,
                isFirst: isFirst,
                isPinned: model.isPinned(project),
                togglePin: { model.togglePin(project) },
                unarchive: listKind == .archived ? { model.unarchive(project) } : nil
            )
        }
    }

    private var visiblePinned: [GrokSession] {
        if listKind == .projectChats {
            return model.pinnedSessions(in: model.focusedProject)
        }
        return model.pinnedSessions()
    }

    private var isListEmpty: Bool {
        if listKind == .projectList { return model.sidebarProjects.isEmpty }
        return listedSessions.isEmpty
    }

    private func destinationRow(
        id: String,
        icon: String,
        title: String,
        count: Int,
        help: String,
        open: @escaping () -> Void
    ) -> some View {
        DestinationRow(
            icon: icon,
            title: title,
            count: count,
            isKeyboardSelected: id == keyboardSelectionID,
            help: help,
            open: {
                keyboardSelectionID = id
                open()
            }
        )
        .id(id)
    }

    private func openTabRow(_ tab: TerminalTab) -> some View {
        let rowID = SidebarOrganization.openTabRowID(tab.id)
        return OpenTabRow(
            title: model.title(for: tab),
            folder: tab.workingDirectory.breadcrumbPath,
            path: tab.workingDirectory.abbreviatedPath,
            activity: tab.activity,
            hasUnseenActivity: tab.hasUnseenActivity,
            isSelected: tab.id == model.selectedTab?.id,
            isKeyboardSelected: rowID == keyboardSelectionID,
            select: {
                keyboardSelectionID = rowID
                model.select(tab.id)
            },
            close: { model.requestCloseTab(tab.id) }
        )
        .id(rowID)
        .contextMenu {
            Button("Close Tab") { model.requestCloseTab(tab.id) }
            if case .exited = tab.activity {
                Button("Restart Session") { model.restartTab(id: tab.id) }
            }
            Divider()
            Button("New Session in This Folder") {
                model.requestNewSession(in: tab.workingDirectory)
            }
        }
    }

    private func projectRow(_ project: SidebarProject, rows: [GrokSession]) -> some View {
        ProjectListRow(
            title: project.name,
            paths: SidebarOrganization.pathHaystacks(
                name: project.name,
                displayPath: project.displayPath,
                cwd: project.cwd,
                sessions: rows
            ),
            count: rows.count,
            relativeTime: rows.first?.updatedAt.shortRelative(to: now) ?? "",
            longRelative: rows.first?.updatedAt.longRelative(to: now) ?? "",
            isPinned: model.isPinned(project),
            isWorking: model.isWorking(project),
            isActive: rows.contains { model.isActive($0) },
            isKeyboardSelected: project.id == keyboardSelectionID,
            open: {
                keyboardSelectionID = project.id
                model.openProject(project)
            },
            newChat: { model.requestNewSessionInProject(project) },
            togglePin: { model.togglePin(project) },
            archive: { model.archive(project) }
        )
        .id(project.id)
        .contextMenu {
            Button("New Session") { model.requestNewSessionInProject(project) }
            Button(model.isPinned(project) ? "Unpin Project" : "Pin Project") {
                model.togglePin(project)
            }
            Button("Archive Project") { model.archive(project) }
            if let session = rows.first {
                Button("Reveal Folder in Finder") { model.revealInFinder(session) }
            }
        }
    }

    private func sessionRow(
        _ session: GrokSession,
        showsProject: Bool,
        headerCoversQuery: Bool = true,
        containingProject: SidebarProject? = nil
    ) -> some View {
        let isPinned = model.isPinned(session)
        let isArchived = model.isArchived(session)
        let hasCustomName = model.hasCustomName(session)
        return SessionRow(
            session: session,
            title: model.title(for: session),
            searchQuery: model.searchText,
            state: state(of: session),
            activity: model.activity(of: session),
            hasUnseenActivity: model.hasUnseenActivity(of: session),
            isPinned: isPinned,
            isArchived: isArchived,
            isKeyboardSelected: model.sessionKey(session) == keyboardSelectionID,
            isMultiSelected: multiSelection.contains(model.sessionKey(session)),
            isRenaming: model.renamingSessionKey == model.sessionKey(session),
            hasCustomName: hasCustomName,
            showsProject: showsProject,
            headerCoversQuery: headerCoversQuery,
            now: now,
            open: {
                keyboardSelectionID = model.sessionKey(session)
                clearMultiSelection()
                model.open(session)
            },
            tap: { handleSessionTap(session) },
            togglePin: { model.togglePin(session) },
            toggleArchive: { model.toggleArchive(session) },
            beginRename: { beginInlineRename(session) },
            commitRename: { model.commitInlineRename(session, to: $0) },
            commitBlur: { model.commitInlineBlur(session, to: $0, mountGeneration: $1) },
            cancelRename: { model.cancelRename() },
            resetName: { model.resetName(session) },
            dismissHelp: model.isOpen(session) ? "Close Tab" : "Delete Conversation",
            dismiss: { dismissSession(session) },
            noteMounted: { model.noteRenameFieldMounted($0, key: model.sessionKey(session)) },
            mountGeneration: { model.renameFieldMountGeneration },
            consumeSelectAll: { model.consumeRenameSelectAll() },
            model: model,
            focus: $focus
        )
        .id(model.sessionKey(session))
        .contextMenu {
            let selection = bulkSelection(containing: session)
            if selection.count > 1 {
                if isArchived {
                    Button("Unarchive \(selection.count) Conversations") {
                        model.unarchive(selection)
                        clearMultiSelection()
                    }
                } else {
                    Button("Archive \(selection.count) Conversations") {
                        model.archive(selection)
                        clearMultiSelection()
                    }
                }
                Divider()
                Button("Move \(selection.count) Conversations to Trash…", role: .destructive) {
                    pendingBulkDelete = selection
                }
            } else {
                Button(isPinned ? "Unpin" : "Pin") { model.togglePin(session) }
                Button(isArchived ? "Unarchive" : "Archive") { model.toggleArchive(session) }
                Divider()
                Button("Rename") { beginInlineRename(session) }
                if hasCustomName {
                    Button("Reset Name") { model.resetName(session) }
                }
                Divider()
                Button("Open in New Tab") { model.open(session) }
                if model.isOpen(session) {
                    Button("Close Tab") { dismissSession(session) }
                }
                Divider()
                Button("New Session in This Folder") {
                    model.requestNewSession(in: URL(fileURLWithPath: session.cwd))
                }
                if let project = containingProject {
                    Button(model.isPinned(project) ? "Unpin Project" : "Pin Project") {
                        model.togglePin(project)
                    }
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
    }

    private func section<Content: View>(
        _ title: String,
        count: Int,
        isFirst: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            Text("\(title.uppercased()) (\(count))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.6)
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
        if model.store.isLoading { return "Loading conversations…" }
        if model.store.loadError != nil { return "Could not load conversations" }
        if !model.searchText.isEmpty { return "No matches" }
        if listKind == .archived { return "No archived conversations" }
        if listKind == .projectList { return "No projects yet" }
        return "No conversations yet"
    }

    @ViewBuilder
    private var emptyHint: some View {
        if let error = model.store.loadError {
            VStack(alignment: .leading, spacing: 6) {
                Text(error)
                Button("Retry") { Task { await model.store.reload() } }
                    .controlSize(.small)
            }
        } else if model.store.isLoading {
            EmptyView()
        } else if !model.searchText.isEmpty {
            Text("Nothing matches “\(model.searchText)”.")
        } else if listKind == .archived {
            Text("Archive a chat or a project from its row to send it here.")
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
        switch listKind {
        case .projectList:
            return SidebarOrganization.homeRowIDs(
                recentsCount: listedSessions.count,
                archivedCount: model.archivedCount,
                pinnedIDs: model.pinnedProjects().map(\.id),
                restIDs: model.unpinnedProjects().map(\.id),
                openTabIDs: model.tabs.map { SidebarOrganization.openTabRowID($0.id) }
            )
        case .search:
            return listedSessions.map { model.sessionKey($0) }
        case .recents, .projectChats, .archived:
            return visiblePinned.map { model.sessionKey($0) }
                + groupedUnpinnedSessions().map { model.sessionKey($0) }
        }
    }

    /// Unpinned chats in the order the current sort draws them.
    private func groupedUnpinnedSessions() -> [GrokSession] {
        let unpinned = model.unpinnedSessions(from: listedSessions)
        switch listKind {
        case .recents, .projectChats:
            return unpinned
        case .search:
            return []
        case .archived:
            let listed = Set(unpinned.map(\.directory))
            return (model.pinnedProjects() + model.unpinnedProjects()).flatMap { project in
                SidebarOrganization.listedRows(in: project, listed: listed)
            }
        case .projectList:
            return []
        }
    }

    private func dismissSession(_ session: GrokSession) {
        switch model.sidebarDismiss(for: session) {
        case .closeTab:
            model.performSidebarDismiss(session)
        case .delete:
            pendingDelete = session
        }
    }

    private func handleEscape() -> KeyPress.Result {
        if model.renamingSessionKey == nil, !multiSelection.isEmpty {
            clearMultiSelection()
            return .handled
        }
        switch SidebarOrganization.escapeAction(
            isRenaming: model.renamingSessionKey != nil,
            surface: model.sidebarSurface
        ) {
        case .cancelRename:
            let returnFocus = model.renameReturnFocus
            model.cancelRename()
            if returnFocus == .terminal {
                focus = nil
                model.focusSelectedTerminal()
            } else {
                focus = .list
            }
        case .leaveFolder:
            model.leaveProject()
        case .leaveList:
            focus = nil
            model.focusSelectedTerminal()
        }
        return .handled
    }

    private func activateSearchResult() {
        guard
            let id = SidebarOrganization.activationKey(
                preferred: keyboardSelectionID, in: visibleRowIDs())
        else { return }
        keyboardSelectionID = id
        focus = nil
        activate(id: id)
    }

    private func beginInlineRename(_ session: GrokSession) {
        keyboardSelectionID = model.sessionKey(session)
        model.beginRename(session)
        focus = .rename
    }

    private func renameKeyboardSelection() -> KeyPress.Result {
        guard let id = keyboardSelectionID, let session = session(for: id) else {
            return .ignored
        }
        beginInlineRename(session)
        return .handled
    }

    private func sessionAnywhere(for key: String) -> GrokSession? {
        session(for: key)
            ?? model.store.sessions.first { model.sessionKey($0) == key }
    }

    private func commitRenameAlert(_ session: GrokSession) {
        model.commitCapturedRename(session)
    }

    private func resetNameAlert(_ session: GrokSession) {
        model.renameAlertDidCommit = true
        model.resetName(session)
    }

    private func cancelRenameAlert() {
        model.renameAlertDidCommit = true
        model.cancelRename()
    }

    @MainActor
    private func restorePromptOnAppear() async {
        let key = model.renamingSessionKey
        guard let key else { return }
        let rowVisible = visibleRowIDs().contains(key)
        guard
            AppModel.shouldForcePromptRepresent(
                isRenaming: true,
                rowVisible: rowVisible,
                sidebarVisible: model.isSidebarVisible,
                showRenameAlert: model.showRenameAlert,
                preparedSurface: model.preparedRenameSurface
            )
        else { return }
        await prepareRename(forceReconfigure: false, forceRepresent: true)
    }

    /// beginRename owns `renameDraft`. This only hands off inline vs prompt.
    @MainActor
    private func prepareRename(forceReconfigure: Bool, forceRepresent: Bool = false) async {
        guard AppModel.shouldPrepareRename(isCancelled: Task.isCancelled) else { return }
        let key = model.renamingSessionKey
        let session = key.flatMap { sessionAnywhere(for: $0) }
        let rowVisible = key.map { visibleRowIDs().contains($0) } ?? false
        let surface = AppModel.renameSurface(
            isRenaming: key != nil,
            sessionAvailable: session != nil,
            rowVisible: rowVisible
        )
        guard
            AppModel.shouldReconfigureRename(
                previousKey: model.preparedRenameKey,
                previousSurface: model.preparedRenameSurface,
                nextKey: key,
                nextSurface: surface,
                forceReconfigure: forceReconfigure,
                forceRepresent: forceRepresent
            )
        else { return }
        model.preparedRenameKey = key
        model.preparedRenameSurface = surface
        switch surface {
        case .none:
            model.renameAlertIsPulsing = false
            model.showRenameAlert = false
            if key != nil { model.cancelRename() }
        case .inline:
            if let key { keyboardSelectionID = key }
            // Tear down the fallback alert before yielding so its binding
            // cannot cancelRename during the wait, and a sibling visibility
            // task cannot fight this handoff.
            model.renameAlertIsPulsing = false
            model.renameAlertDidCommit = true
            model.renameAlertSession = nil
            model.showRenameAlert = false
            await Task.yield()
            let handoff = currentRenameHandoff()
            guard
                AppModel.shouldFinishInlineHandoff(
                    isCancelled: Task.isCancelled,
                    expectedKey: key,
                    currentKey: handoff.key,
                    currentSurface: handoff.surface
                )
            else { return }
            focus = .rename
        case .prompt:
            var presentedSession = session
            if AppModel.shouldPulseRenameAlert(
                forceRepresent: forceRepresent,
                currentlyShown: model.showRenameAlert
            ) {
                model.pulseRenameAlertOff()
                await Task.yield()
                let handoff = currentRenameHandoff()
                guard
                    AppModel.shouldFinishPromptHandoff(
                        isCancelled: Task.isCancelled,
                        expectedKey: key,
                        currentKey: handoff.key,
                        currentSurface: handoff.surface
                    )
                else {
                    model.renameAlertIsPulsing = false
                    return
                }
                presentedSession = handoff.session
            }
            model.revealRenameAlert(presentedSession)
            if AppModel.shouldSelectRenameAlertDraft(
                selectAllPending: model.renameSelectAllPending,
                isCancelled: Task.isCancelled,
                isRenaming: model.renamingSessionKey != nil,
                forceRepresent: forceRepresent
            ) {
                await consumeRenameSelectAllWhenEditorReady(
                    shouldProceed: {
                        let handoff = currentRenameHandoff()
                        return AppModel.shouldConsumeRenameAlertSelectAll(
                            expectedKey: key,
                            currentKey: handoff.key,
                            currentSurface: handoff.surface,
                            selectAllPending: model.renameSelectAllPending,
                            isCancelled: Task.isCancelled,
                            forceRepresent: forceRepresent
                        )
                    },
                    isEditingRenameField: { isEditingRenameAlertField(draft: model.renameDraft) },
                    isDraftUnedited: {
                        AppModel.shouldSelectRenameDraftIfUnedited(
                            currentDraft: model.renameDraft,
                            baseline: model.renameSelectAllBaseline
                        )
                    },
                    consume: { model.consumeRenameSelectAll() }
                )
            } else if AppModel.shouldClearRenameSelectAllOnPrepare(
                forceRepresent: forceRepresent,
                isCancelled: Task.isCancelled
            ) {
                model.clearRenameSelectAllPending()
            }
        }
    }

    private func currentRenameHandoff() -> (
        key: String?, session: GrokSession?, surface: AppModel.RenameSurface
    ) {
        let key = model.renamingSessionKey
        let session = key.flatMap { sessionAnywhere(for: $0) }
        let visible = key.map { visibleRowIDs().contains($0) } ?? false
        let surface = AppModel.renameSurface(
            isRenaming: key != nil,
            sessionAvailable: session != nil,
            rowVisible: visible
        )
        return (key, session, surface)
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
        let extending =
            NSEvent.modifierFlags.contains(.shift) && listKind != .projectList
        let anchor = extending ? (selectionAnchor ?? keyboardSelectionID) : nil
        if let current = keyboardSelectionID, let index = ids.firstIndex(of: current) {
            keyboardSelectionID = ids[min(max(index + delta, 0), ids.count - 1)]
        } else {
            keyboardSelectionID = delta >= 0 ? ids.first : ids.last
        }
        if extending, let anchor, let current = keyboardSelectionID {
            multiSelection = SidebarOrganization.selectionRange(from: anchor, to: current, in: ids)
            selectionAnchor = anchor
        } else {
            clearMultiSelection()
        }
        return .handled
    }

    private func activateKeyboardSelection() -> KeyPress.Result {
        guard let id = keyboardSelectionID else { return .ignored }
        return activate(id: id) ? .handled : .ignored
    }

    @discardableResult
    private func activate(id: String) -> Bool {
        if id == SidebarOrganization.recentsID {
            model.openRecents()
            return true
        }
        if id == SidebarOrganization.archivedID {
            model.openArchived()
            return true
        }
        if let tabID = SidebarOrganization.openTabID(fromRowID: id) {
            guard model.tabs.contains(where: { $0.id == tabID }) else { return false }
            model.select(tabID)
            return true
        }
        if listKind == .projectList, let project = project(for: id) {
            model.openProject(project)
            return true
        }
        guard let session = session(for: id) else { return false }
        model.open(session)
        return true
    }

    private func session(for id: String) -> GrokSession? {
        listedSessions.first { model.sessionKey($0) == id }
    }

    private func project(for id: String) -> SidebarProject? {
        model.sidebarProjects.first { $0.id == id }
    }

    private func clampKeyboardSelection() {
        guard let id = keyboardSelectionID else { return }
        if !visibleRowIDs().contains(id) {
            keyboardSelectionID = nil
        }
    }

    // MARK: - Multi-selection

    /// ⌘ toggles one row, ⇧ extends a range from the anchor, a plain click
    /// opens the conversation and drops the selection.
    private func handleSessionTap(_ session: GrokSession) {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = model.sessionKey(session)
        if modifiers.contains(.command) {
            if multiSelection.contains(key) {
                multiSelection.remove(key)
                if selectionAnchor == key { selectionAnchor = multiSelection.first }
            } else {
                multiSelection.insert(key)
                selectionAnchor = key
            }
            keyboardSelectionID = key
        } else if modifiers.contains(.shift), let anchor = selectionAnchor ?? keyboardSelectionID {
            multiSelection = SidebarOrganization.selectionRange(
                from: anchor, to: key, in: visibleRowIDs())
            selectionAnchor = anchor
            keyboardSelectionID = key
        } else {
            clearMultiSelection()
            keyboardSelectionID = key
            model.open(session)
        }
    }

    /// The rows a bulk action applies to: the multi-selection when this row is
    /// part of it, in visible order; otherwise the row alone.
    private func bulkSelection(containing session: GrokSession) -> [GrokSession] {
        let key = model.sessionKey(session)
        guard multiSelection.count > 1, multiSelection.contains(key) else { return [session] }
        let order = visibleRowIDs()
        return
            listedSessions
            .filter { multiSelection.contains(model.sessionKey($0)) }
            .sorted {
                (order.firstIndex(of: model.sessionKey($0)) ?? .max)
                    < (order.firstIndex(of: model.sessionKey($1)) ?? .max)
            }
    }

    private func clearMultiSelection() {
        multiSelection.removeAll()
        selectionAnchor = nil
    }

    /// Rows that leave the filter (search, archive, delete) leave the selection.
    /// A range anchor that left with them re-roots at the keyboard row, or the
    /// first selected row, so the next ⇧-click still extends instead of
    /// collapsing the selection to the target.
    private func pruneMultiSelection() {
        let rows = visibleRowIDs()
        let visible = Set(rows)
        if !multiSelection.isEmpty {
            multiSelection.formIntersection(visible)
        }
        if let anchor = selectionAnchor, !visible.contains(anchor) {
            selectionAnchor =
                keyboardSelectionID.flatMap { visible.contains($0) ? $0 : nil }
                ?? rows.first(where: { multiSelection.contains($0) })
        }
        if multiSelection.isEmpty, keyboardSelectionID == nil {
            selectionAnchor = nil
        }
    }

    private var bulkDeleteTitle: String {
        let sessions = pendingBulkDelete ?? []
        let count = sessions.count
        if sessions.contains(where: { model.shouldWarnBeforeDeleting($0) }) {
            return "Stop working sessions and move \(count) conversations to Trash?"
        }
        if sessions.contains(where: { model.isRunning($0) }) {
            return "Close \(count) sessions and move them to Trash?"
        }
        return "Move \(count) conversations to Trash?"
    }
}

private struct ProjectRows: Identifiable {
    var id: String { project.id }
    var project: SidebarProject
    var rows: [GrokSession]
}

private struct DrillBar: View {
    let title: String
    var isPinned: Bool = false
    var showsPin: Bool = false
    var showsArchive: Bool = false
    var canStart: Bool = false
    let leave: () -> Void
    var newChat: (() -> Void)? = nil
    var togglePin: (() -> Void)? = nil
    var toggleArchive: (() -> Void)? = nil

    @Environment(\.palette) private var palette
    @State private var isHoveringBack = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: leave) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(isHoveringBack ? palette.text : palette.textDim)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHoveringBack ? palette.raised : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringBack = $0 }
            .help("Back to projects")
            .accessibilityLabel("Back to projects")
            Spacer(minLength: 4)
            if showsArchive, let toggleArchive {
                IconButton(systemImage: "archivebox", help: "Archive Project") {
                    toggleArchive()
                }
            }
            if showsPin, let togglePin {
                IconButton(
                    systemImage: isPinned ? "pin.fill" : "pin",
                    help: isPinned ? "Unpin Project" : "Pin Project"
                ) {
                    togglePin()
                }
                .foregroundStyle(isPinned ? palette.accent : palette.textDim)
            }
            if let newChat {
                IconButton(
                    systemImage: "plus",
                    help: "New Session in \(title) (⌘T)"
                ) {
                    newChat()
                }
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }
}

private struct DestinationRow: View {
    let icon: String
    let title: String
    let count: Int
    let isKeyboardSelected: Bool
    let help: String
    let open: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textFaint)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(countLabel)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(palette.textFaint)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(rowFill)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(countLabel)
        .accessibilityAction(.default, open)
    }

    private var countLabel: String {
        count == 1 ? "1 chat" : "\(count) chats"
    }

    private var fill: Color {
        (isHovering || isKeyboardSelected) ? palette.raised : .clear
    }

    @ViewBuilder
    private var rowFill: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isKeyboardSelected ? palette.hairline : Color.clear,
                        lineWidth: 1
                    )
            )
    }
}

/// One open session at the top of home: its title, its folder and state in
/// mono, and the same light the tab strip shows. Click selects the tab.
private struct OpenTabRow: View {
    let title: String
    let folder: String
    let path: String
    let activity: TerminalTab.Activity
    let hasUnseenActivity: Bool
    let isSelected: Bool
    let isKeyboardSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(folder) · \(stateLabel)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(activity.endedInFailure ? palette.error : palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if SidebarActivityDot.isVisible(
                activity: activity, hasUnseenActivity: hasUnseenActivity, isActive: isSelected)
                || activity.endedInFailure
            {
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
                            isKeyboardSelected && !isSelected ? palette.hairline : Color.clear,
                            lineWidth: 1
                        )
                )
        )
        .overlay(alignment: .topTrailing) { trailing }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help("\(title)\n\(path)\n\(stateLabel)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(title), \(folder)")
        .accessibilityValue(isSelected ? "Selected, \(stateLabel)" : stateLabel)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: "Close Tab", close)
    }

    private var stateLabel: String {
        switch activity {
        case .starting: return "Starting"
        case .working: return "Working"
        case .idle: return hasUnseenActivity ? "Finished" : "Idle"
        case .exited(let code):
            if let code, code != 0 { return "Ended · code \(code)" }
            return "Ended"
        }
    }

    private var fill: Color {
        if isSelected { return palette.selected }
        return (isHovering || isKeyboardSelected) ? palette.raised : .clear
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovering || isKeyboardSelected {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [fill.opacity(0), fill],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 14)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textDim)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")
                .padding(.trailing, 8)
                .padding(.top, 4)
                .background(fill)
            }
        }
    }
}

private struct ProjectListRow: View {
    let title: String
    let paths: [String]
    let count: Int
    let relativeTime: String
    let longRelative: String
    let isPinned: Bool
    let isWorking: Bool
    let isActive: Bool
    let isKeyboardSelected: Bool
    let open: () -> Void
    let newChat: () -> Void
    let togglePin: () -> Void
    var archive: (() -> Void)? = nil

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isWorking {
                // Clear of the plus, and of a pinned folder's pin glyph, in the
                // trailing overlay.
                StatusDot(activity: .working)
                    .padding(.trailing, 22 + (isPinned ? 22 : 0))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(rowFill)
        .overlay(alignment: .topTrailing) { trailing }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .help(rowHelp)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(
            ProjectRowAccessibility.value(
                countLabel: countLabel,
                isActive: isActive,
                isWorking: isWorking,
                isPinned: isPinned
            )
        )
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "New Session", newChat)
        .accessibilityAction(named: isPinned ? "Unpin Project" : "Pin Project", togglePin)
        .modifier(ArchiveProjectAction(archive: archive))
    }

    private var rowHelp: String {
        let path = paths.first { $0.hasPrefix("/") || $0.hasPrefix("~") } ?? title
        if longRelative.isEmpty { return "\(path)\n\(countLabel)" }
        return "\(path)\n\(countLabel) · \(longRelative)"
    }

    private var countLabel: String {
        count == 1 ? "1 chat" : "\(count) chats"
    }

    private var subtitle: String {
        relativeTime.isEmpty ? countLabel : "\(countLabel) · \(relativeTime)"
    }

    /// A folder is never the conversation on screen; the Open section above
    /// carries the `selected` fill. The folder keeps its medium title.
    private var fill: Color {
        (isHovering || isKeyboardSelected) ? palette.raised : .clear
    }

    @ViewBuilder
    private var rowFill: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isKeyboardSelected ? palette.hairline : Color.clear,
                        lineWidth: 1
                    )
            )
    }

    private var trailing: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [fill.opacity(0), fill],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 14)
            // The plus stays trailing-most so hover adds controls to its left
            // and nothing moves under the pointer.
            HStack(spacing: 0) {
                if isHovering || isKeyboardSelected {
                    if let archive {
                        Button(action: archive) {
                            Image(systemName: "archivebox")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.textDim)
                        .help("Archive Project")
                        .accessibilityLabel("Archive Project")
                    }
                    Button(action: togglePin) {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isPinned ? palette.accent : palette.textDim)
                    .help(isPinned ? "Unpin Project" : "Pin Project")
                    .accessibilityLabel(isPinned ? "Unpin Project" : "Pin Project")
                } else if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(palette.accent.opacity(0.9))
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
                Button(action: newChat) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    (isHovering || isKeyboardSelected) ? palette.textDim : palette.textFaint
                )
                .help("New Session")
                .accessibilityLabel("New Session")
            }
            .padding(.trailing, 8)
            .padding(.top, 4)
            .background(fill)
        }
    }
}

private struct ProjectSectionHeader: View {
    let title: String
    let paths: [String]
    let count: Int
    let searchQuery: String
    let isFirst: Bool
    let isPinned: Bool
    let togglePin: () -> Void
    var unarchive: (() -> Void)? = nil

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        let paint = SearchMatchHighlight.projectHeader(
            name: title,
            paths: paths,
            count: count,
            query: searchQuery
        )
        SearchHighlightedText(
            runs: paint.runs,
            match: palette.accent,
            rest: palette.textFaint
        )
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .truncationMode(textTruncationMode(paint.visibleTruncation))
        .padding(.horizontal, 14)
        .padding(.top, isFirst ? 10 : 18)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.sidebar)
        .overlay(alignment: .topTrailing) { trailing }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(isPinned ? "Unpin Project" : "Pin Project", action: togglePin)
            if let unarchive {
                Button("Unarchive Project", action: unarchive)
            }
        }
        .help(
            "\(paths.first { $0.hasPrefix("/") || $0.hasPrefix("~") } ?? title)\n"
                + (isPinned ? "Unpin this project" : "Pin this project")
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(
            SearchMatchHighlight.headerAccessibilityLabel(
                paint: paint,
                shortName: title,
                count: count,
                isPinned: isPinned,
                query: searchQuery
            )
        )
        .accessibilityAction(named: isPinned ? "Unpin Project" : "Pin Project") {
            togglePin()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovering {
            Button(action: togglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isPinned ? palette.accent : palette.textDim)
            .help(isPinned ? "Unpin Project" : "Pin Project")
            .accessibilityLabel(isPinned ? "Unpin Project" : "Pin Project")
            .padding(.trailing, 10)
            .padding(.top, isFirst ? 6 : 14)
        } else if isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(palette.accent.opacity(0.9))
                .padding(.trailing, 12)
                .padding(.top, isFirst ? 10 : 18)
                .accessibilityHidden(true)
        }
    }
}

private struct SessionRow: View {
    enum State {
        case closed
        case open
        case active
    }

    let session: GrokSession
    let title: String
    let searchQuery: String
    let state: State
    let activity: TerminalTab.Activity?
    let hasUnseenActivity: Bool
    let isPinned: Bool
    let isArchived: Bool
    let isKeyboardSelected: Bool
    /// In the ⌘/⇧-click bulk selection; draws the accent stroke.
    let isMultiSelected: Bool
    let isRenaming: Bool
    let hasCustomName: Bool
    let showsProject: Bool
    let headerCoversQuery: Bool
    /// The sidebar's minute tick, for relative times.
    let now: Date
    /// Plain activation (keyboard, VoiceOver): opens the conversation.
    let open: () -> Void
    /// Mouse click: modifier-aware (⌘ toggles, ⇧ ranges), falls back to open.
    let tap: () -> Void
    let togglePin: () -> Void
    let toggleArchive: () -> Void
    let beginRename: () -> Void
    let commitRename: (String) -> Void
    let commitBlur: (String, Int) -> Void
    let cancelRename: () -> Void
    let resetName: () -> Void
    let dismissHelp: String
    let dismiss: () -> Void
    let noteMounted: (Bool) -> Void
    let mountGeneration: () -> Int
    let consumeSelectAll: () -> Bool
    let model: AppModel
    @FocusState.Binding var focus: SidebarFocus?

    @Environment(\.palette) private var palette
    @SwiftUI.State private var isHovering = false
    @SwiftUI.State private var suppressBlurCommit = false
    @SwiftUI.State private var blurCommitTask: Task<Void, Never>?

    var body: some View {
        accessibleRow
            .onAppear { if isRenaming { noteMounted(true) } }
            .onDisappear {
                blurCommitTask?.cancel()
                blurCommitTask = nil
                if isRenaming {
                    noteMounted(false)
                }
            }
            .onChange(of: isRenaming) { _, renaming in
                if renaming {
                    blurCommitTask?.cancel()
                    blurCommitTask = nil
                    suppressBlurCommit = false
                }
                noteMounted(renaming)
            }
            .onChange(of: focus) { _, newFocus in
                if AppModel.shouldCancelPendingBlurCommit(focusIsRename: newFocus == .rename) {
                    blurCommitTask?.cancel()
                    blurCommitTask = nil
                }
            }
            .task(id: isRenaming) { await focusRenameFieldIfNeeded() }
    }

    @ViewBuilder
    private var accessibleRow: some View {
        interactiveRow
            .accessibilityElement(children: isRenaming ? .contain : .combine)
            .modifier(
                SessionRowActivateTrait(
                    isButton: AppModel.renameRowUsesButtonTrait(isRenaming: isRenaming),
                    open: open
                )
            )
            .accessibilityLabel(rowAccessibilityLabel)
            .accessibilityValue(rowAccessibilityValue)
            .accessibilityAddTraits(state == .active ? .isSelected : [])
            .accessibilityAction(named: isPinned ? "Unpin" : "Pin") { togglePin() }
            .accessibilityAction(named: isArchived ? "Unarchive" : "Archive") {
                toggleArchive()
            }
            .accessibilityAction(named: dismissHelp, dismiss)
            .accessibilityAction(named: "Rename") { beginRename() }
            .modifier(
                SessionRowResetNameAction(
                    enabled: AppModel.renameRowOffersResetName(hasCustomName: hasCustomName),
                    resetName: resetName
                )
            )
    }

    @ViewBuilder
    private var interactiveRow: some View {
        rowChrome
            .onTapGesture { if !isRenaming { tap() } }
            .onHover { isHovering = $0 }
            .help(rowHelpText)
    }

    @ViewBuilder
    private var rowChrome: some View {
        let paint = rowPaint
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                titleLine(runs: paint.titleRuns, truncation: paint.titleTruncation)
                SearchHighlightedText(
                    runs: paint.subtitleRuns,
                    match: palette.accent,
                    rest: palette.textFaint
                )
                .font(.system(size: 9.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(textTruncationMode(paint.subtitleTruncation))
            }
            Spacer(minLength: 8)
            if let activity, !isRenaming,
                SidebarActivityDot.isVisible(
                    activity: activity,
                    hasUnseenActivity: hasUnseenActivity,
                    isActive: state == .active
                )
            {
                StatusDot(activity: activity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(rowFill)
        .overlay(alignment: .topTrailing) { trailingOverlay }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowFill: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(stroke, lineWidth: 1)
            )
    }

    /// Multi-selection wears the accent hairline — even on the active row, so
    /// the open conversation never looks outside a bulk action it is in. The
    /// arrow-key highlight keeps the plain one.
    private var stroke: Color {
        if isMultiSelected { return palette.accent }
        if state == .active { return .clear }
        if isKeyboardSelected { return palette.hairline }
        return .clear
    }

    private var rowHelpText: String {
        "\(title)\n\(session.displayPath)\n"
            + "\(session.messageCount) messages · \(session.updatedAt.longRelative(to: now))"
    }

    private var rowAccessibilityValue: String {
        var value: String
        switch state {
        case .active: value = "Selected"
        case .open: value = "Open in another tab"
        case .closed: value = "Closed"
        }
        if isMultiSelected { value += ", in selection" }
        if activity == .working {
            value += ", working"
        } else if hasUnseenActivity {
            value += ", unread"
        }
        return value
    }

    private var rowAccessibilityLabel: String {
        SearchMatchHighlight.rowAccessibilityLabel(
            title: title,
            projectName: session.projectName,
            longRelative: session.updatedAt.longRelative(to: now),
            paint: rowPaint,
            isPinned: isPinned,
            isArchived: isArchived,
            query: searchQuery
        )
    }

    @ViewBuilder
    private func titleLine(
        runs: [SearchMatchHighlight.Run], truncation: SearchMatchHighlight.Truncation
    ) -> some View {
        if isRenaming {
            SessionRenameField(
                model: model,
                placeholder: session.title,
                emphasize: state == .active,
                focus: $focus,
                onSubmit: { commitCurrentDraft(restoreListFocus: true) },
                onAbandon: abandonRename,
                onBlur: commitOnBlurIfNeeded
            )
        } else {
            SearchHighlightedText(
                runs: runs,
                match: palette.accent,
                rest: palette.text
            )
            .font(.system(size: 12, weight: state == .active ? .medium : .regular))
            .lineLimit(1)
            .truncationMode(textTruncationMode(truncation))
        }
    }

    /// One subtitle string; its runs are built from that same instance.
    private var rowPaint: SearchMatchHighlight.RowPaint {
        SearchMatchHighlight.row(
            displayedTitle: title,
            cliTitle: session.title,
            projectName: session.projectName,
            cwd: session.cwd,
            displayPath: session.displayPath,
            relativeTime: session.updatedAt.shortRelative(to: now),
            showsProject: showsProject,
            headerCoversQuery: headerCoversQuery,
            query: searchQuery
        )
    }

    @ViewBuilder
    private var trailingOverlay: some View {
        if isRenaming {
            EmptyView()
        } else if isHovering || isKeyboardSelected {
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
                    rowActionButton(
                        systemImage: "xmark",
                        tinted: false,
                        help: dismissHelp,
                        action: dismiss
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
        return (isHovering || isKeyboardSelected || isRenaming || isMultiSelected)
            ? palette.raised : .clear
    }

    @MainActor
    private func focusRenameFieldIfNeeded() async {
        guard isRenaming else { return }
        // Suppress only the focus steal. Click-away must commit during the wait.
        do {
            suppressBlurCommit = true
            defer { suppressBlurCommit = false }
            await Task.yield()
            guard
                AppModel.shouldStealRenameFocusAfterYield(
                    isCancelled: Task.isCancelled,
                    isRenaming: isRenaming
                )
            else { return }
            focus = .rename
            await Task.yield()
            guard
                AppModel.shouldStealRenameFocusAfterYield(
                    isCancelled: Task.isCancelled,
                    isRenaming: isRenaming
                )
            else { return }
        }
        // Two yields are not a miss — wait for the field editor (same timeout
        // as select-all) so a later .rename FocusState still reaches select-all.
        switch await waitForRenameFocusStealFollowUp() {
        case .miss:
            commitOnBlurIfNeeded()
            return
        case .selectAll:
            break
        case .abort, .wait:
            return
        }
        await consumeRenameSelectAllWhenEditorReady(
            shouldProceed: {
                AppModel.shouldStealRenameFocusAfterYield(
                    isCancelled: Task.isCancelled,
                    isRenaming: isRenaming
                )
            },
            isEditingRenameField: { focus == .rename },
            isDraftUnedited: {
                AppModel.shouldSelectRenameDraftIfUnedited(
                    currentDraft: model.renameDraft,
                    baseline: model.renameSelectAllBaseline
                )
            },
            consume: consumeSelectAll
        )
    }

    /// First check is immediate so F2/⌘⇧R stay instant when the editor is ready.
    @MainActor
    private func waitForRenameFocusStealFollowUp() async -> AppModel.RenameFocusStealFollowUp {
        let started = ContinuousClock.now
        while true {
            let editor = currentRenameFieldEditor()
            let isFirstResponder = editor.map { $0.window?.firstResponder === $0 } ?? false
            let ready = AppModel.isRenameFieldEditorReady(
                fieldEditorExists: editor != nil,
                fieldEditorIsFirstResponder: isFirstResponder,
                isEditingRenameField: focus == .rename
            )
            let followUp = AppModel.renameFocusStealFollowUp(
                fieldEditorReady: ready,
                focusIsRename: focus == .rename,
                isCancelled: Task.isCancelled,
                isRenaming: isRenaming,
                elapsed: ContinuousClock.now - started
            )
            if followUp != .wait { return followUp }
            try? await Task.sleep(for: AppModel.renameSelectAllRetryInterval)
        }
    }

    private func commitCurrentDraft(restoreListFocus: Bool) {
        let returnFocus = model.renameReturnFocus
        suppressBlurCommit = true
        blurCommitTask?.cancel()
        blurCommitTask = nil
        commitRename(model.renameDraft)
        if restoreListFocus { restoreFocus(after: returnFocus) }
        if AppModel.shouldClearBlurSuppressionAfterCommitOrAbandon() {
            suppressBlurCommit = false
        }
    }

    private func abandonRename() {
        let returnFocus = model.renameReturnFocus
        suppressBlurCommit = true
        blurCommitTask?.cancel()
        blurCommitTask = nil
        cancelRename()
        restoreFocus(after: returnFocus)
        if AppModel.shouldClearBlurSuppressionAfterCommitOrAbandon() {
            suppressBlurCommit = false
        }
    }

    /// A ⌘⇧R rename hands the keyboard back to the terminal it came from.
    private func restoreFocus(after returnFocus: AppModel.RenameReturnFocus) {
        switch returnFocus {
        case .list:
            focus = .list
        case .terminal:
            focus = nil
            model.focusSelectedTerminal()
        }
    }

    private func commitOnBlurIfNeeded() {
        guard !suppressBlurCommit else { return }
        let draft = model.renameDraft
        let generation = mountGeneration()
        blurCommitTask?.cancel()
        blurCommitTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard AppModel.shouldCommitInlineBlurAfterYield(focusIsRename: focus == .rename)
            else { return }
            commitBlur(draft, generation)
        }
    }
}

@MainActor
private func currentRenameFieldEditor() -> NSText? {
    NSApp.keyWindow?.fieldEditor(false, for: nil)
}

@MainActor
private func isEditingRenameAlertField(draft: String) -> Bool {
    guard let key = NSApp.keyWindow else { return false }
    return AppModel.isEditingRenameAlertField(
        hasKeyWindow: true,
        keyWindowIsMain: key.isMainWindow,
        keyWindowIsSheet: key.isSheet,
        editorStringMatchesDraft: currentRenameFieldEditor()?.string == draft
    )
}

/// Select-all only when the rename field editor is first responder.
/// A leftover search or dormant editor must not consume pending.
/// First check is immediate; later retries sleep, then stop at the timeout
/// and clear pending without selecting. Skip select-all if the draft was edited.
@MainActor
private func consumeRenameSelectAllWhenEditorReady(
    shouldProceed: @escaping () -> Bool,
    isEditingRenameField: @escaping () -> Bool,
    isDraftUnedited: @escaping () -> Bool,
    consume: @escaping () -> Bool
) async {
    let started = ContinuousClock.now
    while shouldProceed() {
        let editor = currentRenameFieldEditor()
        let isFirstResponder = editor.map { $0.window?.firstResponder === $0 } ?? false
        let ready = AppModel.isRenameFieldEditorReady(
            fieldEditorExists: editor != nil,
            fieldEditorIsFirstResponder: isFirstResponder,
            isEditingRenameField: isEditingRenameField()
        )
        if ready {
            let unedited = isDraftUnedited()
            if AppModel.shouldConsumeRenameSelectAll(
                fieldEditorReady: true,
                selectAllPending: consume()
            ), unedited {
                editor?.selectAll(nil)
            }
            return
        }
        let elapsed = ContinuousClock.now - started
        guard AppModel.shouldContinueRenameSelectAllRetry(elapsed: elapsed) else {
            if AppModel.shouldClearRenameSelectAllOnRetryTimeout() {
                let pending = consume()
                if AppModel.shouldConsumeRenameSelectAll(
                    fieldEditorReady: AppModel.shouldSelectRenameDraftOnRetryTimeout(),
                    selectAllPending: pending
                ) {
                    editor?.selectAll(nil)
                }
            }
            return
        }
        try? await Task.sleep(for: AppModel.renameSelectAllRetryInterval)
    }
}

private func textTruncationMode(_ truncation: SearchMatchHighlight.Truncation) -> Text.TruncationMode {
    switch truncation {
    case .tail: return .tail
    case .middle: return .middle
    }
}

/// Accent on matched runs only. Empty query (or no hit in this string) is plain `Text`.
private struct SearchHighlightedText: View {
    let runs: [SearchMatchHighlight.Run]
    let match: Color
    let rest: Color

    var body: some View {
        if runs.contains(where: \.isMatch) {
            Text(Self.attributed(runs, match: match, rest: rest))
        } else {
            Text(runs.map(\.text).joined())
                .foregroundStyle(rest)
        }
    }

    private static func attributed(
        _ runs: [SearchMatchHighlight.Run],
        match: Color,
        rest: Color
    ) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            piece.foregroundColor = run.isMatch ? match : rest
            result += piece
        }
        return result
    }
}

/// Owns the Bindable `renameDraft` read so keystrokes do not rebuild the sidebar.
private struct SessionRenameField: View {
    @Bindable var model: AppModel
    let placeholder: String
    let emphasize: Bool
    @FocusState.Binding var focus: SidebarFocus?
    let onSubmit: () -> Void
    let onAbandon: () -> Void
    let onBlur: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        TextField(placeholder, text: $model.renameDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: emphasize ? .medium : .regular))
            .foregroundStyle(palette.text)
            .focused($focus, equals: .rename)
            .onSubmit(onSubmit)
            .onKeyPress(.escape) {
                onAbandon()
                return .handled
            }
            .onExitCommand(perform: onAbandon)
            .onChange(of: focus) { _, newFocus in
                if newFocus != .rename { onBlur() }
            }
    }
}

/// Owns the alert field's Bindable `renameDraft` read, same isolation as inline.
private struct RenameAlertDraftField: View {
    @Bindable var model: AppModel

    var body: some View {
        TextField("Name", text: $model.renameDraft)
    }
}

/// Return commits the fallback alert, matching the inline field's onSubmit.
private struct RenameAlertDefaultCommit: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

/// VoiceOver/full-keyboard activate opens the thread. While the inline
/// rename field is up, the row is not a button — activate would steal
/// focus and can blur-commit.
private struct SessionRowActivateTrait: ViewModifier {
    let isButton: Bool
    let open: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isButton {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open() }
        } else {
            content
        }
    }
}

private struct ArchiveProjectAction: ViewModifier {
    let archive: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let archive {
            content.accessibilityAction(named: "Archive Project", archive)
        } else {
            content
        }
    }
}

private struct SessionRowResetNameAction: ViewModifier {
    let enabled: Bool
    let resetName: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: "Reset Name") { resetName() }
        } else {
            content
        }
    }
}
