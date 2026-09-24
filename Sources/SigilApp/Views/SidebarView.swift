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
    /// The row under the pointer. The one `hover` fill glides to it.
    @State private var hoveredRowID: String?
    @Namespace private var glideSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// F2. Unicode private-use scalar for `NSF2FunctionKey`.
    private static let f2 = KeyEquivalent(Character("\u{F705}"))

    var body: some View {
        VStack(spacing: 0) {
            header
            searchRow
            navItems
            modeArea
            list
        }
        .background(palette.canvas)
        .environment(\.sidebarGlide, glide)
        .onChange(of: focus) { _, focus in model.isSidebarFocused = focus != nil }
        .onDisappear { model.isSidebarFocused = false }
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
    }

    // MARK: - Header

    /// The row beside the traffic lights: only the collapse button, at the
    /// trailing edge, as in Beautiful UI's sidebar.
    private var header: some View {
        HStack {
            Spacer()
            IconButton(systemImage: "sidebar.leading", help: "Hide Sidebar (⌘B)") {
                withAnimation(reduceMotion ? nil : Motion.slide) {
                    model.isSidebarVisible.toggle()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    /// Where the gliding `hover` fill sits: the row under the pointer, else the
    /// arrow-key row while the list has the keyboard.
    private var glide: SidebarGlide {
        SidebarGlide(
            target: hoveredRowID ?? (focus == .list ? keyboardSelectionID : nil),
            namespace: glideSpace,
            hover: { id, inside in
                if inside {
                    withAnimation(reduceMotion ? nil : Motion.glide) { hoveredRowID = id }
                } else if hoveredRowID == id {
                    // Let the next row claim the fill first, so it glides
                    // instead of fading out and back in.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        if hoveredRowID == id {
                            withAnimation(reduceMotion ? nil : Motion.fade) { hoveredRowID = nil }
                        }
                    }
                }
            }
        )
    }

    // MARK: - Search

    private var searchRow: some View {
        FieldFrame(isFocused: focus == .search) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(focus == .search ? palette.ink2 : palette.ink3)
                TextField(
                    "", text: $model.searchText,
                    prompt: Text("Search chats").foregroundStyle(palette.ink2)
                )
                .textFieldStyle(.plain)
                .ui(13.5)
                .foregroundStyle(palette.ink)
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
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.ink3)
                    .accessibilityLabel("Clear conversation search")
                    .help("Clear search")
                } else if focus != .search {
                    KbdChip(label: "⌘⇧F", palette: palette)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(Motion.fade, value: focus == .search)
        .animation(Motion.fade, value: model.searchText.isEmpty)
    }

    // MARK: - Nav

    /// Beautiful UI's nav items: where you can go, above what is in the list.
    private var navItems: some View {
        VStack(spacing: 0) {
            NavRow(
                id: "sigil:nav:new",
                icon: "square.and.pencil",
                title: "New session",
                trailing: .key("⌘T"),
                isSelected: false,
                isKeyboardSelected: false,
                help: "New Session… (⌘T)",
                open: { model.requestNewSession() }
            )
            NavRow(
                id: "sigil:nav:home",
                icon: "house",
                title: "Home",
                trailing: .none,
                isSelected: model.sidebarSurface == .folders || model.sidebarSurface == .project,
                isKeyboardSelected: false,
                help: "Open sessions and projects",
                open: { model.leaveProject() }
            )
            if model.sidebarSessions.count > 0 {
                navDestination(
                    id: SidebarOrganization.recentsID,
                    icon: "clock",
                    title: "Recents",
                    count: model.sidebarSessions.count,
                    isSelected: model.sidebarSurface == .recents,
                    help: "All conversations, newest first",
                    open: { model.openRecents() }
                )
            }
            if model.archivedCount > 0 {
                navDestination(
                    id: SidebarOrganization.archivedID,
                    icon: "archivebox",
                    title: "Archived",
                    count: model.archivedCount,
                    isSelected: model.sidebarSurface == .archived,
                    help: "Archived conversations",
                    open: { model.openArchived() }
                )
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Mode

    @ViewBuilder
    private var modeArea: some View {
        if model.sidebarSurface == .project, let project = model.focusedProject {
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
                .padding(.bottom, 10)
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
        case .projectSearch:
            projectGroupedSections(from: unpinned, afterPinned: afterPinned)
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
        let pinned = visibleProjects(model.pinnedProjects(), from: listedSessions, keepEmpty: true)
        let rest = visibleProjects(model.unpinnedProjects(), from: listedSessions, keepEmpty: true)
        section(
            "Projects",
            count: pinned.count + rest.count,
            isFirst: model.tabs.isEmpty,
            add: { model.chooseProjectToAdd() }
        ) {
            ForEach(pinned, id: \.id) { item in
                projectRow(item.project, rows: item.rows)
            }
            ForEach(rest, id: \.id) { item in
                projectRow(item.project, rows: item.rows)
            }
        }
    }

    @ViewBuilder
    private func recentsSections(
        from sessions: [GrokSession],
        afterPinned: Bool,
        projectIndex: [URL: SidebarProject]
    ) -> some View {
        let buckets = SessionBucket.bucket(sessions)
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

    /// `keepEmpty` keeps an added folder that has no chats yet.
    private func visibleProjects(
        _ projects: [SidebarProject], from sessions: [GrokSession], keepEmpty: Bool = false
    ) -> [ProjectRows] {
        projects.compactMap { project in
            let rows = SidebarOrganization.listedRows(in: project, from: sessions)
            if rows.isEmpty, !(keepEmpty && project.sessions.isEmpty) { return nil }
            return ProjectRows(project: project, rows: rows)
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

    private func navDestination(
        id: String,
        icon: String,
        title: String,
        count: Int,
        isSelected: Bool,
        help: String,
        open: @escaping () -> Void
    ) -> some View {
        NavRow(
            id: id,
            icon: icon,
            title: title,
            trailing: .count(count),
            isSelected: isSelected,
            isKeyboardSelected: id == keyboardSelectionID,
            help: help,
            open: {
                keyboardSelectionID = id
                if isSelected { model.leaveProject() } else { open() }
            }
        )
        .id(id)
    }

    private func openTabRow(_ tab: TerminalTab) -> some View {
        let rowID = SidebarOrganization.openTabRowID(tab.id)
        return OpenTabRow(
            rowID: rowID,
            title: model.title(for: tab),
            folder: tab.workingDirectory.folderName,
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
            rowID: project.id,
            title: project.name,
            paths: SidebarOrganization.pathHaystacks(
                name: project.name,
                displayPath: project.displayPath,
                cwd: project.cwd,
                sessions: rows
            ),
            count: rows.count,
            relativeTime: rows.first?.updatedAt.shortRelative ?? "",
            longRelative: rows.first?.updatedAt.longRelative ?? "",
            isPinned: model.isPinned(project),
            isWorking: model.isWorking(project),
            isActive: rows.contains { model.isActive($0) },
            isKeyboardSelected: project.id == keyboardSelectionID,
            canStart: true,
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
            Button(project.sessions.isEmpty ? "Remove Project" : "Archive Project") {
                model.archive(project)
            }
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

    /// A sentence-case label with a trailing mono count, as Beautiful UI's
    /// "Chats" header. No uppercase, no tracking.
    private func section<Content: View>(
        _ title: String,
        count: Int,
        isFirst: Bool,
        add: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            SidebarSectionLabel(title: title, count: count, isFirst: isFirst, add: add)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(emptyTitle)
                .ui(13.5, .medium)
                .foregroundStyle(palette.ink)
            emptyHint
                .ui(12.5)
                .foregroundStyle(palette.ink2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
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
                    .buttonStyle(SigilButtonStyle(kind: .secondary, height: 26))
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
        case .recents, .projectChats, .projectSearch, .archived:
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
        case .projectSearch, .archived:
            return (model.pinnedProjects() + model.unpinnedProjects()).flatMap { project in
                SidebarOrganization.listedRows(in: project, from: unpinned)
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

// MARK: - Glide

/// The sidebar's one `hover` fill, and the row it sits on. Rows report the
/// pointer through `hover`; the fill moves between them with
/// `matchedGeometryEffect`, so it glides instead of blinking.
struct SidebarGlide {
    var target: String?
    var namespace: Namespace.ID?
    var hover: (String, Bool) -> Void = { _, _ in }
}

private struct SidebarGlideKey: EnvironmentKey {
    static var defaultValue: SidebarGlide { SidebarGlide() }
}

extension EnvironmentValues {
    var sidebarGlide: SidebarGlide {
        get { self[SidebarGlideKey.self] }
        set { self[SidebarGlideKey.self] = newValue }
    }
}

/// A sidebar row's fill: the gliding `hover`, the `hover2` of the open row
/// over it, and the rings for keyboard and multi-selection.
private struct RowHighlight: View {
    let id: String
    var isSelected = false
    var isKeyboardSelected = false
    var isMultiSelected = false
    var isRenaming = false

    @Environment(\.palette) private var palette
    @Environment(\.sidebarGlide) private var glide

    /// The sidebar sits on `canvas`. In dark mode `hover` lifts off it; in
    /// light mode `hover` is lighter than the canvas, so hover darkens to `hover2`.
    private var hoverFill: Color { palette.isDark ? palette.hover : palette.hover2 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        ZStack {
            if glide.target == id || isRenaming {
                if let namespace = glide.namespace, !isRenaming {
                    shape.fill(hoverFill)
                        .matchedGeometryEffect(id: "sidebar.glide", in: namespace)
                } else {
                    shape.fill(hoverFill)
                }
            }
            if isSelected {
                if palette.isDark {
                    shape.fill(palette.hover2)
                } else {
                    // On the light canvas the open row lifts to `surface`, as
                    // Beautiful UI's selected segment does; a grey fill vanishes.
                    shape.fill(palette.surface)
                        .overlay(shape.strokeBorder(palette.ringButton, lineWidth: 1))
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                }
            }
            if isMultiSelected {
                shape.strokeBorder(palette.accent, lineWidth: 1)
            } else if isKeyboardSelected && !isSelected {
                shape.strokeBorder(palette.lineStrong, lineWidth: 1)
            }
        }
    }
}

/// "Open 3", "Projects 12": the label in `ink2`, the count in mono.
private struct SidebarSectionLabel: View {
    let title: String
    let count: Int
    let isFirst: Bool
    var add: (() -> Void)? = nil
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .ui(12.5, .medium)
                    .foregroundStyle(palette.ink2)
                Spacer(minLength: 4)
                Text("\(count)")
                    .mono(11.5)
                    .foregroundStyle(palette.ink2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("\(title), \(count)")
            if let add {
                RowAction(systemImage: "plus", help: "Add Project", action: add)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, add == nil ? 16 : 10)
        .padding(.top, isFirst ? 8 : 16)
        .padding(.bottom, add == nil ? 4 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.canvas)
    }
}

/// A trailing action on a sidebar row: 22pt, `ink3` at rest.
private struct RowAction: View {
    let systemImage: String
    var tinted = false
    let help: String
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(isHovering ? palette.hover2 : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tinted ? palette.accent : (isHovering ? palette.ink : palette.ink2))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The small pin a pinned row keeps at rest.
private struct PinMark: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(45))
            .foregroundStyle(palette.ink3)
            .accessibilityHidden(true)
    }
}

/// The open project's bar: back, the name, and its actions.
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
        HStack(spacing: 2) {
            Button(action: leave) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHoveringBack ? palette.ink : palette.ink3)
                    Text(title)
                        .ui(14, .medium)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(isHoveringBack ? palette.hover : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringBack = $0 }
            .animation(Motion.fade, value: isHoveringBack)
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
                    help: isPinned ? "Unpin Project" : "Pin Project",
                    isOn: isPinned
                ) {
                    togglePin()
                }
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
        .padding(.top, 4)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, 16)
        }
    }
}

/// A Beautiful UI nav item: a 16pt icon, a label, and a trailing count or key.
private struct NavRow: View {
    enum Trailing {
        case none
        case count(Int)
        case key(String)
    }

    let id: String
    let icon: String
    let title: String
    let trailing: Trailing
    let isSelected: Bool
    let isKeyboardSelected: Bool
    let help: String
    let open: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.sidebarGlide) private var glide

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isSelected ? palette.ink : palette.ink2)
                .frame(width: 18)
            Text(title)
                .ui(14, isSelected ? .medium : .regular)
                .foregroundStyle(palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            switch trailing {
            case .none:
                EmptyView()
            case .count(let count):
                Text("\(count)")
                    .mono(11.5)
                    .foregroundStyle(palette.ink2)
            case .key(let key):
                KbdChip(label: key, palette: palette)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RowHighlight(id: id, isSelected: isSelected, isKeyboardSelected: isKeyboardSelected)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { glide.hover(id, $0) }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(.default, open)
    }

    private var accessibilityValue: String {
        switch trailing {
        case .none, .key: return ""
        case .count(let count): return count == 1 ? "1 chat" : "\(count) chats"
        }
    }
}

/// One open session on the sidebar home: its state mark, its title, and its
/// folder in mono. Click selects the tab.
private struct OpenTabRow: View {
    let rowID: String
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
    @Environment(\.sidebarGlide) private var glide
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            ActivityMark(activity: activity, hasUnseenActivity: hasUnseenActivity && !isSelected)
            Text(title)
                .ui(14, isSelected ? .medium : .regular)
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if isHovering || isKeyboardSelected {
                RowAction(systemImage: "xmark", help: "Close Tab", action: close)
            } else {
                Text(folder)
                    .mono(11.5)
                    .foregroundStyle(activity.endedInFailure ? palette.redInk : palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 96, alignment: .trailing)
                    .fixedSize(horizontal: folder.count <= 12, vertical: false)
                    .layoutPriority(1)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .frame(height: 32)
        .background(
            RowHighlight(id: rowID, isSelected: isSelected, isKeyboardSelected: isKeyboardSelected)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { inside in
            isHovering = inside
            glide.hover(rowID, inside)
        }
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
}

/// A project on the sidebar home: folder icon, name, and its latest time in
/// mono. Hover adds archive and pin beside the plus.
private struct ProjectListRow: View {
    let rowID: String
    let title: String
    let paths: [String]
    let count: Int
    let relativeTime: String
    let longRelative: String
    let isPinned: Bool
    let isWorking: Bool
    let isActive: Bool
    let isKeyboardSelected: Bool
    let canStart: Bool
    var showsPin: Bool = true
    let open: () -> Void
    let newChat: () -> Void
    let togglePin: () -> Void
    var archive: (() -> Void)? = nil

    @Environment(\.palette) private var palette
    @Environment(\.sidebarGlide) private var glide
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "folder.fill" : "folder")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(isActive ? palette.ink2 : palette.ink3)
                .frame(width: 16)
            Text(title)
                .ui(14, isActive ? .medium : .regular)
                .foregroundStyle(palette.ink)
                .lineLimit(1)
            if isPinned && showsPin && !showsControls {
                PinMark()
            }
            Spacer(minLength: 8)
            if showsControls {
                HStack(spacing: 0) {
                    if let archive {
                        RowAction(systemImage: "archivebox", help: "Archive Project", action: archive)
                    }
                    if showsPin {
                        RowAction(
                            systemImage: isPinned ? "pin.fill" : "pin",
                            tinted: isPinned,
                            help: isPinned ? "Unpin Project" : "Pin Project",
                            action: togglePin
                        )
                    }
                    if canStart {
                        RowAction(systemImage: "plus", help: "New Session", action: newChat)
                    }
                }
            } else {
                if isWorking {
                    PixelLoader(color: palette.accent)
                }
                Text(relativeTime.isEmpty ? "\(count)" : relativeTime)
                    .mono(11.5)
                    .foregroundStyle(palette.ink2)
                    .fixedSize()
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, showsControls ? 5 : 8)
        .frame(height: 32)
        .background(RowHighlight(id: rowID, isKeyboardSelected: isKeyboardSelected))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { inside in
            isHovering = inside
            glide.hover(rowID, inside)
        }
        .help(rowHelp)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(
            ProjectRowAccessibility.value(
                countLabel: countLabel,
                isActive: isActive,
                isWorking: isWorking,
                isPinned: isPinned && showsPin
            )
        )
        .accessibilityAction(.default, open)
        .modifier(NamedActionIf(name: "New Session", enabled: canStart, action: newChat))
        .modifier(
            NamedActionIf(
                name: isPinned ? "Unpin Project" : "Pin Project",
                enabled: showsPin,
                action: togglePin
            )
        )
        .modifier(ArchiveProjectAction(archive: archive))
    }

    private var showsControls: Bool { isHovering || isKeyboardSelected }

    private var rowHelp: String {
        let path = paths.first { $0.hasPrefix("/") || $0.hasPrefix("~") } ?? title
        if longRelative.isEmpty { return "\(path)\n\(countLabel)" }
        return "\(path)\n\(countLabel) · \(longRelative)"
    }

    private var countLabel: String {
        count == 1 ? "1 chat" : "\(count) chats"
    }
}

/// A project's name above its chats in Archived and in a search across
/// projects. Search matches paint in `accentInk`.
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
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(palette.ink3)
            SearchHighlightedText(
                runs: paint.runs,
                match: palette.accentInk,
                rest: palette.ink2
            )
            .ui(12.5, .medium)
            .lineLimit(1)
            .truncationMode(textTruncationMode(paint.visibleTruncation))
            Spacer(minLength: 4)
            if isHovering {
                Button(action: togglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isPinned ? palette.accent : palette.ink2)
                .help(isPinned ? "Unpin Project" : "Pin Project")
                .accessibilityLabel(isPinned ? "Unpin Project" : "Pin Project")
            } else if isPinned {
                PinMark()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isFirst ? 8 : 16)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.canvas)
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
    @Environment(\.sidebarGlide) private var glide
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
            .onHover { inside in
                isHovering = inside
                glide.hover(rowID, inside)
            }
            .help(rowHelpText)
    }

    /// One line while browsing: title, then the time (and project, in lists
    /// that span projects) in mono. A search result adds the matched context
    /// as a second mono line, as Beautiful UI's search results do.
    @ViewBuilder
    private var rowChrome: some View {
        let paint = rowPaint
        HStack(spacing: 8) {
            if isSearchResult {
                VStack(alignment: .leading, spacing: 2) {
                    titleLine(runs: paint.titleRuns, truncation: paint.titleTruncation)
                    metadata(paint)
                }
                Spacer(minLength: 4)
                if !isRenaming, showsControls {
                    actions
                } else {
                    stateMarks
                }
            } else {
                titleLine(runs: paint.titleRuns, truncation: paint.titleTruncation)
                    .layoutPriority(0)
                Spacer(minLength: 8)
                if isRenaming {
                    EmptyView()
                } else if showsControls {
                    actions
                } else {
                    stateMarks
                    metadata(paint)
                        .frame(maxWidth: 120, alignment: .trailing)
                        .fixedSize(horizontal: paint.subtitle.count <= 4, vertical: false)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, showsControls && !isRenaming ? 5 : 8)
        .padding(.vertical, isSearchResult ? 6 : 0)
        .frame(minHeight: 32)
        .background(
            RowHighlight(
                id: rowID,
                isSelected: state == .active,
                isKeyboardSelected: isKeyboardSelected,
                isMultiSelected: isMultiSelected,
                isRenaming: isRenaming
            )
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private var rowID: String { model.sessionKey(session) }

    private var isSearchResult: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsControls: Bool { isHovering || isKeyboardSelected }

    private func metadata(_ paint: SearchMatchHighlight.RowPaint) -> some View {
        SearchHighlightedText(
            runs: paint.subtitleRuns,
            match: palette.accentInk,
            rest: palette.ink2
        )
        .mono(11.5)
        .lineLimit(1)
        .truncationMode(textTruncationMode(paint.subtitleTruncation))
    }

    /// Working light and pin, at rest.
    @ViewBuilder
    private var stateMarks: some View {
        if isPinned {
            PinMark()
        }
        if let activity, !isRenaming,
            SidebarActivityDot.isVisible(
                activity: activity,
                hasUnseenActivity: hasUnseenActivity,
                isActive: state == .active
            )
        {
            ActivityMark(activity: activity, hasUnseenActivity: hasUnseenActivity)
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            RowAction(
                systemImage: isArchived ? "archivebox.fill" : "archivebox",
                tinted: isArchived,
                help: isArchived ? "Unarchive" : "Archive",
                action: toggleArchive
            )
            RowAction(
                systemImage: isPinned ? "pin.fill" : "pin",
                tinted: isPinned,
                help: isPinned ? "Unpin" : "Pin",
                action: togglePin
            )
            RowAction(systemImage: "xmark", help: dismissHelp, action: dismiss)
        }
    }

    private var rowHelpText: String {
        "\(title)\n\(session.displayPath)\n"
            + "\(session.messageCount) messages · \(session.updatedAt.longRelative)"
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
            longRelative: session.updatedAt.longRelative,
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
                match: palette.accentInk,
                rest: palette.ink
            )
            .ui(14, state == .active ? .medium : .regular)
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
            relativeTime: session.updatedAt.shortRelative,
            showsProject: showsProject,
            headerCoversQuery: headerCoversQuery,
            query: searchQuery
        )
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
            .ui(14, emphasize ? .medium : .regular)
            .foregroundStyle(palette.ink)
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

private struct NamedActionIf: ViewModifier {
    let name: String
    let enabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: name, action)
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
