import AppKit
import SigilKit
import SwiftUI

private enum SidebarFocus: Hashable {
    case search
    case list
    case rename
}

/// The thread viewer: every Grok Build conversation on this machine.
///
/// Recents is the time-ordered list. Projects is the same list grouped by
/// folder. Chat pins sit at the top of either sort. Project pins sit at the
/// top of Projects. Archived chats leave both until the archivebox in the
/// header is turned on. The list is the product: find one conversation in a
/// history of hundreds, without leaving the keyboard.
struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: SidebarFocus?
    /// Arrow-key highlight. Separate from open/active so those markers stay
    /// about the tab strip, not about where the keys are.
    @State private var keyboardSelectionID: String?
    @State private var pendingDelete: GrokSession?
    @State private var hoveredMode: SidebarMode?
    @Namespace private var modeUnderline

    /// F2. Unicode private-use scalar for `NSF2FunctionKey`.
    private static let f2 = KeyEquivalent(Character("\u{F705}"))

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
        .task(id: model.renamingSessionKey) {
            await prepareRename(
                forceReconfigure: model.renamingSessionKey != model.preparedRenameKey)
        }
        .task(id: visibleRowIDs()) {
            clampKeyboardSelection()
            await prepareRename(forceReconfigure: false)
        }
        .task {
            await restorePromptOnAppear()
        }
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
                .onKeyPress(Self.f2) { renameKeyboardSelection() }
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
                    // Reduce Motion: the underline jumps instead of sliding.
                    if reduceMotion {
                        model.settings.sidebarMode = mode
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) {
                            model.settings.sidebarMode = mode
                        }
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
                if let id { proxy.scrollTo(id, anchor: .center) }
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
        projects.compactMap { project in
            let rows = sessions.filter { session in
                project.sessions.contains { $0.directory == session.directory }
            }
            return rows.isEmpty ? nil : ProjectRows(project: project, rows: rows)
        }
    }

    private func projectSection(
        _ project: SidebarProject, rows: [GrokSession], isFirst: Bool
    ) -> some View {
        Section {
            ForEach(rows, id: \.directory) { session in
                sessionRow(session, showsProject: false)
            }
        } header: {
            ProjectSectionHeader(
                title: project.name,
                count: rows.count,
                isFirst: isFirst,
                isPinned: model.isPinned(project),
                togglePin: { model.togglePin(project) }
            )
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
            title: model.title(for: session),
            state: state(of: session),
            activity: model.activity(of: session),
            isPinned: model.isPinned(session),
            isArchived: model.isArchived(session),
            isKeyboardSelected: model.sessionKey(session) == keyboardSelectionID,
            isRenaming: model.renamingSessionKey == model.sessionKey(session),
            hasCustomName: model.hasCustomName(session),
            showsProject: showsProject,
            open: {
                keyboardSelectionID = model.sessionKey(session)
                model.open(session)
            },
            togglePin: { model.togglePin(session) },
            toggleArchive: { model.toggleArchive(session) },
            beginRename: { beginInlineRename(session) },
            commitRename: { model.commitInlineRename(session, to: $0) },
            commitBlur: { model.commitInlineBlur(session, to: $0, mountGeneration: $1) },
            cancelRename: { model.cancelRename() },
            resetName: { model.resetName(session) },
            noteMounted: { model.noteRenameFieldMounted($0, key: model.sessionKey(session)) },
            mountGeneration: { model.renameFieldMountGeneration },
            consumeSelectAll: { model.consumeRenameSelectAll() },
            model: model,
            focus: $focus
        )
        .id(model.sessionKey(session))
        .contextMenu {
            Button(model.isPinned(session) ? "Unpin" : "Pin") { model.togglePin(session) }
            Button(model.isArchived(session) ? "Unarchive" : "Archive") { model.toggleArchive(session) }
            Divider()
            Button("Rename") { beginInlineRename(session) }
            if model.hasCustomName(session) {
                Button("Reset Name") { model.resetName(session) }
            }
            Divider()
            Button("Open in New Tab") { model.open(session) }
            Divider()
            Button("New Session in This Folder") {
                model.newTab(in: URL(fileURLWithPath: session.cwd))
            }
            if let project = project(containing: session) {
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
            return (model.pinnedProjects() + model.unpinnedProjects()).flatMap { project in
                unpinned.filter { session in
                    project.sessions.contains { $0.directory == session.directory }
                }
            }
        }
    }

    private func handleEscape() -> KeyPress.Result {
        if model.renamingSessionKey != nil {
            model.cancelRename()
            focus = .list
            return .handled
        }
        if !model.searchText.isEmpty {
            model.searchText = ""
            return .handled
        }
        focus = nil
        return .handled
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

    private func project(containing session: GrokSession) -> SidebarProject? {
        model.sidebarProjects.first { project in
            project.sessions.contains { $0.directory == session.directory }
        }
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
            let pinnedFolders = model.pinnedProjects().count
            var parts = ["\(threads) threads", "\(folders) projects"]
            if pinned > 0 { parts.append("\(pinned) pinned") }
            if pinnedFolders == 1 {
                parts.append("1 pinned project")
            } else if pinnedFolders > 0 {
                parts.append("\(pinnedFolders) pinned projects")
            }
            return parts.joined(separator: " · ")
        }
        if pinned > 0 {
            return "\(threads) threads · \(pinned) pinned"
        }
        return "\(threads) threads"
    }
}

private struct ProjectRows: Identifiable {
    var id: String { project.id }
    var project: SidebarProject
    var rows: [GrokSession]
}

private struct ProjectSectionHeader: View {
    let title: String
    let count: Int
    let isFirst: Bool
    let isPinned: Bool
    let togglePin: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        let label = "\(title) (\(count))"
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.textFaint)
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
            }
            .help(isPinned ? "Unpin this project" : "Pin this project")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(
                "\(title), \(count) conversations" + (isPinned ? ", pinned" : "")
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
    let title: String
    let state: State
    let activity: TerminalTab.Activity?
    let isPinned: Bool
    let isArchived: Bool
    let isKeyboardSelected: Bool
    let isRenaming: Bool
    let hasCustomName: Bool
    let showsProject: Bool
    let open: () -> Void
    let togglePin: () -> Void
    let toggleArchive: () -> Void
    let beginRename: () -> Void
    let commitRename: (String) -> Void
    let commitBlur: (String, Int) -> Void
    let cancelRename: () -> Void
    let resetName: () -> Void
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
            .accessibilityAction(named: isPinned ? "Unpin" : "Pin") { togglePin() }
            .accessibilityAction(named: isArchived ? "Unarchive" : "Archive") {
                toggleArchive()
            }
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
            .onTapGesture { if !isRenaming { open() } }
            .onHover { isHovering = $0 }
            .help(rowHelpText)
    }

    @ViewBuilder
    private var rowChrome: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                Text(subtitle)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let activity, activity == .working, !isRenaming {
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
                    .strokeBorder(
                        isKeyboardSelected && state != .active ? palette.hairline : Color.clear,
                        lineWidth: 1
                    )
            )
    }

    private var rowHelpText: String {
        "\(title)\n\(session.displayPath)\n"
            + "\(session.messageCount) messages · \(session.updatedAt.longRelative)"
    }

    private var rowAccessibilityLabel: String {
        "\(title), \(session.projectName), \(session.updatedAt.longRelative)"
            + (isPinned ? ", pinned" : "")
            + (isArchived ? ", archived" : "")
    }

    @ViewBuilder
    private var titleLine: some View {
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
            Text(title)
                .font(.system(size: 12, weight: state == .active ? .medium : .regular))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var subtitle: String {
        if showsProject {
            return "\(session.projectName) · \(session.updatedAt.shortRelative)"
        }
        return session.updatedAt.shortRelative
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
        return (isHovering || isKeyboardSelected || isRenaming) ? palette.raised : .clear
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
        suppressBlurCommit = true
        blurCommitTask?.cancel()
        blurCommitTask = nil
        commitRename(model.renameDraft)
        if restoreListFocus { focus = .list }
        if AppModel.shouldClearBlurSuppressionAfterCommitOrAbandon() {
            suppressBlurCommit = false
        }
    }

    private func abandonRename() {
        suppressBlurCommit = true
        blurCommitTask?.cancel()
        blurCommitTask = nil
        cancelRename()
        focus = .list
        if AppModel.shouldClearBlurSuppressionAfterCommitOrAbandon() {
            suppressBlurCommit = false
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
