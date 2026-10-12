import SigilKit
import SwiftUI

/// The window. Until the launch has read the login shell's GROK_HOME there is
/// no model, so it shows only its own background.
struct RootView: View {
    let launch: AppLaunch

    var body: some View {
        #if DEBUG
            if let fixture = WorkbenchFixture.requested {
                WorkbenchReferenceRoot(fixture: fixture)
            } else {
                window
            }
        #else
            window
        #endif
    }

    @ViewBuilder
    private var window: some View {
        if let model = launch.model {
            #if DEBUG
                WindowContent(model: model)
                    .background(FirstKeyView())
                    .overlay(alignment: .bottomTrailing) {
                        if SidebarNoticeFixture.requested { SidebarNoticeFixtureControls(model: model) }
                        if SidebarTitleFixture.requested { SidebarTitleFixtureControls(model: model) }
                    }

            #else
                WindowContent(model: model)
                    .background(FirstKeyView())
            #endif
        } else {
            LaunchCanvas(isSlow: launch.isSlow)
        }
    }
}

/// AppKit gives a window its first key view as the window first shows. A
/// window that showed with only the launch canvas got none and kept no first
/// responder, so this makes the same pick once the content is in and shown.
private struct FirstKeyView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Picker(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Picker: NSView {
        private var visibility: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibility = nil
            guard let window else { return }
            guard window.isVisible else {
                // Pick when it shows. On a first show AppKit has picked by
                // then; a window hidden or minimized since the canvas has not.
                visibility = window.observe(\.isVisible) { [weak self] window, _ in
                    MainActor.assumeIsolated {
                        if window.isVisible { self?.pick() }
                    }
                }
                return
            }
            pick()
        }

        private func pick() {
            visibility = nil
            DispatchQueue.main.async { [weak window] in
                guard let window, window.firstResponder === window,
                    let content = window.contentView
                else { return }
                // Content that came in while the window was hidden is not in
                // the key view loop until the loop is rebuilt.
                window.recalculateKeyViewLoop()
                window.selectKeyView(following: content)
            }
        }
    }
}

/// The window's canvas and chrome while the launch waits for the login shell.
/// A wait past half a second adds a small spinner and nothing else.
private struct LaunchCanvas: View {
    let isSlow: Bool
    private let theme = AppSettings.storedTheme()

    var body: some View {
        let palette = Palette(theme: theme)
        ZStack {
            palette.canvas
            if isSlow {
                ProgressView()
                    .controlSize(.small)
                    .environment(\.colorScheme, theme.isDark ? .dark : .light)
                    .accessibilityLabel("Starting Sigil")
            }
        }
        .modifier(WindowBackgroundDrag())
        .background(WindowChrome(background: palette.canvasNSColor))
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct WindowContent: View {
    @Bindable var model: AppModel
    @AppStorage("window.sidebarWidth") private var sidebarWidth: Double = 272
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: Palette { Palette(theme: model.settings.theme) }

    /// Beautiful UI's window inset: the screen sits this far off the window edge.
    static let inset: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let columns = WindowColumns(
                width: geometry.size.width,
                sidebarWidth: model.isSidebarVisible ? sidebarWidth : nil,
                panelWidth: model.panel.isVisible ? model.panel.width : nil
            )
            HStack(spacing: 0) {
                if model.isSidebarVisible {
                    SidebarView(model: model)
                        .frame(width: columns.sidebar)
                    SplitDivider(
                        width: Binding(
                            get: { columns.sidebar },
                            set: { sidebarWidth = $0 }
                        ),
                        maximumWidth: WindowColumns(
                            width: geometry.size.width, sidebarWidth: 430,
                            panelWidth: model.panel.isVisible ? model.panel.width : nil
                        ).sidebar,
                        onFocusChange: { model.isSidebarDividerFocused = $0 }
                    )
                    .zIndex(1)
                }
                detail
                    .padding(.leading, model.isSidebarVisible ? 0 : Self.inset)
                    .padding(.trailing, model.panel.isVisible ? Self.inset / 2 : Self.inset)
                    .padding(.vertical, Self.inset)
                if model.panel.isVisible {
                    PanelDivider(
                        width: Binding(
                            get: { columns.panel },
                            set: { model.panel.width = $0 }
                        ),
                        maximumWidth: WindowColumns(
                            width: geometry.size.width,
                            sidebarWidth: model.isSidebarVisible ? columns.sidebar : nil,
                            panelWidth: RightPanel.maxWidth
                        ).panel
                    )
                    .zIndex(1)
                    RightPanelView(model: model, availableWidth: columns.panel)
                        .padding(.leading, Self.inset / 2)
                        .padding(.trailing, Self.inset)
                        .padding(.vertical, Self.inset)
                        .frame(width: columns.panel)
                }
            }
        }
        .background(palette.canvas)
        .tint(palette.accent)
        .environment(\.palette, palette)
        .background(WindowChrome(background: palette.canvasNSColor))
        .background(
            WindowCloseGuard {
                model.tabs.contains(where: \.shouldWarnBeforeStopping)
                    || model.panel.shellHasForegroundJob
            }
        )
        .sheet(isPresented: $model.isShowingNewSessionSheet) {
            NewSessionSheet(model: model)
                .environment(\.palette, Palette(theme: model.settings.theme))
                .tint(Palette(theme: model.settings.theme).accent)
        }
        .task { await model.onAppear() }
        .task(id: model.selectedTabID) {
            await Task.yield()
            model.focusSelectedTerminal()
        }
        .onChange(of: model.isShowingNewSessionSheet) { _, shown in
            if !shown { model.newSessionSheetDidClose() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.windowDidBecomeKey()
        }
        .onChange(of: announcementSnapshot) { old, new in
            announce(ScreenAnnouncement.change(from: old, to: new))
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var announcementSnapshot: ScreenAnnouncement.Snapshot {
        let tab = model.selectedTab
        return ScreenAnnouncement.Snapshot(
            tabID: tab?.id,
            title: tab?.title ?? "",
            activity: tab?.activity ?? .starting,
            inboxCount: tab?.bridgeInbox.count ?? 0
        )
    }

    /// Speaks only while Sigil is the active app, so VoiceOver is not cut off
    /// in another app. Unseen activity still shows on the tab.
    private func announce(_ text: String?) {
        guard let text, NSApp.isActive else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: - The screen

    /// Beautiful UI's inset screen: `page`, a 14pt radius, and a `line` border.
    /// It holds the tab bar and the terminal; the sidebar sits outside it on
    /// the window's own `canvas`.
    private var detail: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
        return VStack(spacing: 0) {
            TopBar(model: model)
            Rectangle().fill(palette.line).frame(height: 1)
            content
        }
        .background(shape.fill(palette.page))
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.line, lineWidth: 1).allowsHitTesting(false))
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ForEach(model.tabs) { tab in
                    let isSelected = !model.showsNewSessionSurface && tab.id == model.selectedTab?.id
                    TerminalScreen(
                        tab: tab, theme: model.settings.theme,
                        onWindowAttachment: { model.terminalViewDidAttach(tabID: tab.id) }
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                }
                if model.showsNewSessionSurface {
                    NewSessionSurface(model: model)
                }
                if !model.showsNewSessionSurface, model.isFindBarVisible, model.selectedTab != nil {
                    HStack {
                        Spacer(minLength: 0)
                        TerminalFindBar(
                            query: Bindable(model).findQuery,
                            matchIndex: model.findMatchIndex,
                            matchCount: model.findMatchCount,
                            focusToken: model.findFocusToken,
                            findNext: { model.findNextInTerminal() },
                            findPrevious: { model.findPreviousInTerminal() },
                            dismiss: { model.dismissFindBar() }
                        )
                    }
                    .padding(10)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .offset(y: -6))
                    )
                    .zIndex(1)
                }
            }
            // Docked below the terminal, never over it: the CLI's input
            // line and an exit reason sit at the bottom of the screen.
            if !model.showsNewSessionSurface, let tab = model.selectedTab, let item = tab.bridgeInbox.first {
                BridgeInboxCard(
                    prompt: item.prompt,
                    pendingCount: tab.bridgeInbox.count,
                    canDeliver: tab.canDeliverBridgePrompt,
                    deliver: {
                        tab.deliverNextBridgePrompt()
                        tab.controller.focus()
                    },
                    dismiss: { tab.dismissNextBridgePrompt() }
                )
                .padding(10)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
            if !model.showsNewSessionSurface, let tab = model.selectedTab, case .exited = tab.activity {
                ExitedCapsule(
                    activity: tab.activity,
                    close: { model.closeTab(tab.id) },
                    restart: { model.restartTab(id: tab.id) }
                )
                .padding(10)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.1) : Motion.slide,
            value: model.isFindBarVisible
        )
        .animation(reduceMotion ? nil : Motion.slide, value: model.selectedTab?.bridgeInbox.count)
        .onChange(of: model.findQuery) { _, query in
            model.applyFindQuery()
            announce(ScreenAnnouncement.findMatches(query: query, count: model.findMatchCount))
        }
    }
}

/// The selected session's folder stays on screen for one tab and for many.
enum SelectedSessionFolder {
    static func text(tabCount: Int, folder: String?) -> String? {
        guard tabCount > 0, let folder, !folder.isEmpty else { return nil }
        return folder
    }

    static func breadcrumb(of directory: URL) -> String {
        directory.breadcrumbPath
    }
}

/// What VoiceOver speaks for changes the detail column shows only visually.
enum ScreenAnnouncement {
    /// The parts of the selected tab that can need an announcement.
    struct Snapshot: Equatable {
        var tabID: UUID?
        var title: String
        var activity: TerminalTab.Activity
        var inboxCount: Int
    }

    /// A new tab message, or a turn that finished or ended with its session, on
    /// the tab the user is on. A tab switch also changes the snapshot, and it
    /// speaks nothing.
    static func change(from old: Snapshot, to new: Snapshot) -> String? {
        guard new.tabID != nil, old.tabID == new.tabID else { return nil }
        if new.inboxCount > old.inboxCount {
            return "Incoming tab message. Deliver or Dismiss."
        }
        guard old.activity == .working else { return nil }
        switch new.activity {
        case .idle: return "\(new.title): turn finished"
        case .exited: return "\(new.title): session ended"
        case .failed: return "\(new.title): failed"
        case .interrupted: return "\(new.title): stopped"
        case .waitingForApproval: return "\(new.title): needs approval"
        case .starting, .working, .unknown, .disconnected: return nil
        }
    }

    static func findMatches(query: String, count: Int) -> String? {
        guard !query.isEmpty else { return nil }
        switch count {
        case 0: return "No matches"
        case 1: return "1 match"
        default: return "\(count) matches"
        }
    }
}

/// The screen's tab bar: 44pt, Beautiful UI's harness. Tab chips and a plus
/// on the leading side; the folder, the working time, and the panel and
/// session controls on the trailing side. It replaces the title bar entirely.
private struct TopBar: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            if !model.isSidebarVisible {
                // Room for the traffic lights, which now sit over the screen.
                Color.clear.frame(width: 66)
                IconButton(systemImage: "sidebar.leading", help: "Show Sidebar (⌘B)", label: "Show Sidebar") {
                    withAnimation(reduceMotion ? nil : Motion.slide) {
                        model.isSidebarVisible.toggle()
                    }
                }
            }

            if model.tabs.isEmpty {
                Spacer(minLength: 8)
                    .contentShape(Rectangle())
                    .modifier(WindowBackgroundDrag())
            } else {
                TabStripView(model: model)
            }

            if model.showsNewSessionSurface {
                Text(SelectedSessionFolder.breadcrumb(of: model.pendingSessionDirectory ?? model.newSessionDirectory))
                    .mono(12)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 6)
                    .modifier(WindowBackgroundDrag())
            } else if let tab = model.selectedTab {
                if tab.activity == .working {
                    WorkingLabel(since: tab.workingSince)
                        .padding(.horizontal, 6)
                        .transition(.opacity)
                }
                selectedFolder(tab)
            }

            if TabListRows.isShown(tabCount: model.tabs.count) {
                TabListView(model: model)
            }

            IconButton(
                systemImage: "sidebar.trailing",
                help: model.panel.isVisible ? "Hide Panel (⌥⌘B)" : "Show Panel (⌥⌘B)",
                label: model.panel.isVisible ? "Hide Panel" : "Show Panel",
                isOn: model.panel.isVisible
            ) {
                withAnimation(reduceMotion ? nil : Motion.slide) { model.togglePanel() }
            }

            Menu {
                Button("New Session in Folder…") { model.requestNewSessionInFolder { model.pickDirectory() } }
                if let tab = model.selectedTab, tab.spec.provider == .codex, tab.sessionReference == nil {
                    Menu("Link Conversation…") {
                        let candidates = model.codexLinkCandidates(for: tab)
                        if candidates.isEmpty {
                            Text("No Codex history in this folder")
                        }
                        ForEach(candidates) { session in
                            Button(
                                "Link this tab to \(model.title(for: session))? (\(session.nativeSessionID.prefix(8)))"
                            ) {
                                Task { await model.linkCodexSession(session, to: tab.id) }
                            }
                            .help("Link this tab to \(session.nativeSessionID) in \(session.cwd)")
                        }
                    }
                    .accessibilityIdentifier("codex-link-conversation")
                }
                Divider()
                SettingsLink { Text("Settings…") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .foregroundStyle(palette.ink3)
            // A borderless menu draws its label in the tint; keep it an icon, not a link.
            .tint(palette.ink3)
            .help("Session actions")
            .accessibilityLabel("Session actions")
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 44)
        .animation(reduceMotion ? nil : Motion.fade, value: model.selectedTab?.activity)
    }

    @ViewBuilder
    private func selectedFolder(_ tab: TerminalTab) -> some View {
        if let folder = SelectedSessionFolder.text(
            tabCount: model.tabs.count,
            folder: SelectedSessionFolder.breadcrumb(of: tab.workingDirectory)
        ) {
            Text(folder)
                .mono(11.5)
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)
                .layoutPriority(1)
                .padding(.horizontal, 4)
                .help(tab.workingDirectory.abbreviatedPath)
                .accessibilityLabel("Folder \(folder)")
                .modifier(WindowBackgroundDrag())
        }
    }
}

/// Beautiful UI's loading state: the pixel loader, a shimmering label, and
/// the elapsed time in mono.
struct WorkingLabel: View {
    let since: Date?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            PixelLoader(color: palette.accent)
            ShimmerText(text: "Working")
            if let since {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date))
                        .mono(11.5)
                        .foregroundStyle(palette.ink2)
                        .monospacedDigit()
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }

    /// `8s`, `1m 04s`, `12m`.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 10 { return String(format: "%dm %02ds", minutes, seconds % 60) }
        return "\(minutes)m"
    }
}

/// The draggable seam between the sidebar and the screen. It draws nothing:
/// the screen's own border is the edge. Focus shows an accent bar.
private struct SplitDivider: View {
    @Binding var width: Double
    let maximumWidth: Double
    let onFocusChange: (Bool) -> Void
    @Environment(\.palette) private var palette
    @FocusState private var isFocused: Bool

    private var limits: ClosedRange<Double> { min(200, maximumWidth)...maximumWidth }

    private func clamp(_ value: Double) -> Double {
        min(limits.upperBound, max(limits.lowerBound, value))
    }

    var body: some View {
        Color.clear
            .frame(width: 1)
            .overlay {
                if isFocused {
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: 2)
                        .padding(.vertical, WindowContent.inset + Radius.window)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                DividerDragHandle(width: $width, limits: limits, direction: .right) { isFocused = true }
                    .frame(width: 9)
                    .accessibilityHidden(true)
            }
            .focusable(interactions: .edit)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
            .onDisappear { onFocusChange(false) }
            .onKeyPress(.leftArrow) {
                width = clamp(width - 20)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                width = clamp(width + 20)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = clamp(width + 20)
                case .decrement: width = clamp(width - 20)
                @unknown default: break
                }
            }
    }
}

/// The inbox and ended-session banner actions for the selected tab, so the
/// File menu can run them from the keyboard.
extension AppModel {
    var canDeliverSelectedTabMessage: Bool {
        guard let tab = selectedTab else { return false }
        return !tab.bridgeInbox.isEmpty && tab.canDeliverBridgePrompt
    }

    func deliverSelectedTabMessage() {
        guard let tab = selectedTab, canDeliverSelectedTabMessage else { return }
        tab.deliverNextBridgePrompt()
        tab.controller.focus()
    }

    var canDismissSelectedTabMessage: Bool {
        !(selectedTab?.bridgeInbox.isEmpty ?? true)
    }

    func dismissSelectedTabMessage() {
        selectedTab?.dismissNextBridgePrompt()
    }

    var canRestartSelectedTab: Bool {
        guard let tab = selectedTab, case .exited = tab.activity else { return false }
        return true
    }

    func restartSelectedTab() {
        guard let tab = selectedTab, canRestartSelectedTab else { return }
        restartTab(id: tab.id)
    }
}

/// A tab message, as Beautiful UI's approval card: the question the other
/// tab is asking, and the two answers.
private struct BridgeInboxCard: View {
    let prompt: String
    let pendingCount: Int
    let canDeliver: Bool
    let deliver: () -> Void
    let dismiss: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text("Message from another tab")
                    .ui(13.5, .semibold)
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 0)
                if pendingCount > 1 {
                    Text("1/\(pendingCount)")
                        .mono(11.5)
                        .foregroundStyle(palette.ink2)
                        .accessibilityLabel("\(pendingCount) queued")
                }
            }
            ScrollView {
                Text(prompt)
                    .ui(13)
                    .foregroundStyle(palette.ink2)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.secondary)
                Button("Deliver", action: deliver)
                    .buttonStyle(.primary)
                    .disabled(!canDeliver)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .surface(palette.surface, radius: Radius.card, elevation: .card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Incoming tab message")
    }
}

/// Hides the title bar and paints the window itself, so no system grey shows through
/// behind the content during a resize.
struct WindowChrome: NSViewRepresentable {
    let background: NSColor

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let color = background
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.backgroundColor = color
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

/// Apply only to non-interactive chrome. A bounded native view keeps window
/// dragging out of the terminal and editor's event handling.
struct WindowBackgroundDrag: ViewModifier {
    func body(content: Content) -> some View {
        content.background(WindowDragRegion())
    }
}

private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Surface() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Surface: NSView {
        // Deliver the initial click even while this window is inactive.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// An ended session, as Beautiful UI's failed task row: a mark, what
/// happened, and the two ways on.
struct ExitedCapsule: View {
    let activity: TerminalTab.Activity
    var closeTitle = "Close Tab"
    let close: () -> Void
    let restart: () -> Void
    @Environment(\.palette) private var palette

    private var code: Int32? {
        if case .exited(let code) = activity { return code }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(activity.endedInFailure ? palette.red : palette.hover2)
                Image(systemName: activity.endedInFailure ? "xmark" : "stop.fill")
                    .font(.system(size: activity.endedInFailure ? 9 : 7, weight: .bold))
                    .foregroundStyle(activity.endedInFailure ? .white : palette.ink2)
            }
            .frame(width: 18, height: 18)
            Text(
                activity.endedInFailure
                    ? "Session ended with code \(code.map(String.init) ?? "unknown")"
                    : "Session ended"
            )
            .ui(13, .medium)
            .foregroundStyle(palette.ink)
            if activity.endedInFailure {
                StatusPill(text: "Failed", tone: .red)
            }
            Spacer(minLength: 12)
            Button(closeTitle, action: close)
                .buttonStyle(SigilButtonStyle(kind: .ghost, height: 26))
            Button("Restart", action: restart)
                .buttonStyle(SigilButtonStyle(kind: .secondary, height: 26))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(Capsule(style: .continuous).fill(palette.surface))
        .overlay(Capsule(style: .continuous).strokeBorder(palette.ring, lineWidth: 1))
    }
}

extension URL {
    /// `~`-abbreviated path, for the top bar and tooltips.
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The folder's own name, e.g. `wt-pr-a`; the home folder is `~`.
    var folderName: String {
        path == FileManager.default.homeDirectoryForCurrentUser.path ? "~" : lastPathComponent
    }

    /// `project/worktree` for a folder in a Sigil worktree, e.g. `app/9e27b2dd`.
    var sigilWorktreeLabel: String? {
        guard let project = SigilWorktree.projectPath(of: path) else { return nil }
        let prefix = SigilWorktree.root.path + "/"
        let rest = path.hasPrefix(prefix) ? path.dropFirst(prefix.count) : Substring(path)
        let parts = rest.split(separator: "/")
        let name = parts.count >= 2 ? String(parts[1]) : lastPathComponent
        return "\(URL(fileURLWithPath: project).lastPathComponent)/\(name)"
    }

    /// Last two path components, e.g. `scratchpad/wt-pr-a`. The home folder
    /// keeps its `~`, which is shorter than its own two components.
    var breadcrumbPath: String {
        if let label = sigilWorktreeLabel { return label }
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        let names = pathComponents.filter { $0 != "/" }
        guard names.count >= 2 else { return abbreviatedPath }
        return names.suffix(2).joined(separator: "/")
    }
}

struct WindowColumns: Equatable {
    let sidebar: Double
    let panel: Double

    static func minimumWidth(sidebarVisible: Bool, panelVisible: Bool) -> Double {
        max(760, 400 + (sidebarVisible ? 201 : 0) + (panelVisible ? 281 : 0))
    }

    init(width: Double, sidebarWidth: Double?, panelWidth: Double?) {
        let total = width.isFinite ? max(0, width) : 0
        let seams = (sidebarWidth == nil ? 0.0 : 1.0) + (panelWidth == nil ? 0.0 : 1.0)
        let available = max(0, total - 400 - seams)
        let panelReserve = panelWidth == nil ? 0 : min(280, available)
        let wantedSidebar = sidebarWidth.map { $0.isFinite ? min(430, max(200, $0)) : 272 } ?? 0
        sidebar = min(wantedSidebar, max(0, available - panelReserve))
        let wantedPanel = panelWidth.map { $0.isFinite ? min(900, max(280, $0)) : 380 } ?? 0
        panel = min(wantedPanel, max(0, available - sidebar))
    }
}
