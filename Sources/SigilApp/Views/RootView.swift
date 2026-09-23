import SigilKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage("window.sidebarWidth") private var sidebarWidth: Double = 272
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: Palette { Palette(theme: model.settings.theme) }

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
                        onFocusChange: { model.isSidebarDividerFocused = $0 }
                    )
                }
                detail
                if model.panel.isVisible {
                    PanelDivider(
                        width: Binding(
                            get: { columns.panel },
                            set: { model.panel.width = $0 }
                        )
                    )
                    RightPanelView(model: model, availableWidth: columns.panel)
                        .frame(width: columns.panel)
                }
            }
        }
        .background(palette.ground)
        .tint(palette.accent)
        .environment(\.palette, palette)
        .background(WindowChrome(background: palette.groundNSColor))
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
            if !shown { model.focusSelectedTerminal() }
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

    // MARK: - Detail column

    private var detail: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            Rectangle().fill(palette.hairline).frame(height: 1)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.tabs.isEmpty {
            EmptyDetailView { model.requestNewSession() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    ForEach(model.tabs) { tab in
                        let isSelected = tab.id == model.selectedTab?.id
                        TerminalScreen(tab: tab, isSelected: isSelected)
                            .opacity(isSelected ? 1 : 0)
                            .allowsHitTesting(isSelected)
                            .accessibilityHidden(!isSelected)
                    }
                    if model.isFindBarVisible, model.selectedTab != nil {
                        TerminalFindBar(
                            query: Bindable(model).findQuery,
                            matchIndex: model.findMatchIndex,
                            matchCount: model.findMatchCount,
                            focusToken: model.findFocusToken,
                            findNext: { model.findNextInTerminal() },
                            findPrevious: { model.findPreviousInTerminal() },
                            dismiss: { model.dismissFindBar() }
                        )
                        .padding(8)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .offset(y: -6))
                        )
                        .zIndex(1)
                    }
                }
                .animation(
                    .easeOut(duration: 0.16),
                    value: model.isFindBarVisible
                )
                .onChange(of: model.findQuery) { _, query in
                    model.applyFindQuery()
                    announce(ScreenAnnouncement.findMatches(query: query, count: model.findMatchCount))
                }
                if let tab = model.selectedTab, let item = tab.bridgeInbox.first {
                    BridgeInboxBanner(
                        prompt: item.prompt,
                        pendingCount: tab.bridgeInbox.count,
                        canDeliver: tab.canDeliverBridgePrompt,
                        deliver: {
                            tab.deliverNextBridgePrompt()
                            tab.controller.focus()
                        },
                        dismiss: { tab.dismissNextBridgePrompt() }
                    )
                }
                if let tab = model.selectedTab, case .exited = tab.activity {
                    ExitedBanner(
                        activity: tab.activity,
                        close: { model.closeTab(tab.id) },
                        restart: { model.restartTab(id: tab.id) }
                    )
                }
            }
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
        case .starting, .working: return nil
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

/// The one piece of window chrome: a 38pt band holding the sidebar toggle, what the
/// current session is, and the new-session button. It replaces the title bar entirely.
private struct TopBar: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            // Room for the traffic lights when the sidebar is not holding them.
            if !model.isSidebarVisible {
                Color.clear.frame(width: 68)
            }

            IconButton(
                systemImage: "sidebar.leading",
                help: model.isSidebarVisible ? "Hide Sidebar (⌘B)" : "Show Sidebar (⌘B)",
                isOn: model.isSidebarVisible
            ) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    model.isSidebarVisible.toggle()
                }
            }
            .padding(.leading, model.isSidebarVisible ? 8 : 0)

            if model.tabs.count > 1 {
                TabStripView(model: model)
                selectedFolder
                if TabListRows.isShown(tabCount: model.tabs.count) {
                    TabListView(model: model)
                }
            } else {
                label
                Spacer(minLength: 8)
            }

            IconButton(
                systemImage: "sidebar.trailing",
                help: model.panel.isVisible ? "Hide Panel (⌥⌘B)" : "Show Panel (⌥⌘B)",
                isOn: model.panel.isVisible
            ) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { model.togglePanel() }
            }

            IconButton(systemImage: "plus", help: "New Session… (⌘T)") {
                model.requestNewSession()
            }
            Menu {
                Button("New Session in Folder…") { model.requestNewSession() }
                Divider()
                SettingsLink { Text("Settings…") }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .foregroundStyle(palette.textDim)
            .padding(.trailing, 10)
            .accessibilityLabel("Session actions")
        }
        .frame(height: 36)
        .background(palette.ground)
    }

    @ViewBuilder
    private var selectedFolder: some View {
        if let tab = model.selectedTab,
            let folder = SelectedSessionFolder.text(
                tabCount: model.tabs.count,
                folder: SelectedSessionFolder.breadcrumb(of: tab.workingDirectory)
            )
        {
            folderText(folder, help: tab.workingDirectory.abbreviatedPath)
                .layoutPriority(1)
                .padding(.leading, 6)
                .accessibilityLabel("Folder \(folder)")
        }
    }

    @ViewBuilder
    private var label: some View {
        if let tab = model.selectedTab {
            HStack(spacing: 6) {
                StatusDot(activity: tab.activity)
                Text(model.title(for: tab))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                if let folder = SelectedSessionFolder.text(
                    tabCount: model.tabs.count,
                    folder: SelectedSessionFolder.breadcrumb(of: tab.workingDirectory)
                ) {
                    folderText(folder, help: tab.workingDirectory.abbreviatedPath)
                }
            }
            .padding(.leading, 10)
        }
    }

    private func folderText(_ folder: String, help: String) -> some View {
        Text(folder)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(palette.textFaint)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(help)
    }
}

/// A 20pt square borderless button. Every icon control in the chrome is one of these.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var isOn = false
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? palette.selected : (isHovering ? palette.raised : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn || isHovering ? palette.text : palette.textDim)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The draggable seam between the two columns.
private struct SplitDivider: View {
    @Binding var width: Double
    let onFocusChange: (Bool) -> Void
    @Environment(\.palette) private var palette
    @State private var widthAtDragStart: Double?
    @FocusState private var isFocused: Bool

    var body: some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(width: 1)
            .overlay {
                if isFocused {
                    Rectangle()
                        .fill(palette.accent)
                        .frame(width: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = widthAtDragStart ?? width
                                widthAtDragStart = base
                                width = min(430, max(200, base + value.translation.width))
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
            }
            .focusable(interactions: .activate)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
            .onDisappear { onFocusChange(false) }
            .onKeyPress(.leftArrow) {
                width = max(200, width - 20)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                width = min(430, width + 20)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(430, width + 20)
                case .decrement: width = max(200, width - 20)
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

private struct BridgeInboxBanner: View {
    let prompt: String
    let pendingCount: Int
    let canDeliver: Bool
    let deliver: () -> Void
    let dismiss: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 96)
            HStack {
                if pendingCount > 1 {
                    Text("\(pendingCount) queued")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(palette.textFaint)
                }
                Spacer(minLength: 0)
                Button("Dismiss", action: dismiss)
                Button("Deliver", action: deliver)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canDeliver)
            }
        }
        .padding(10)
        .background(palette.raised)
        .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Incoming tab message")
    }
}

/// Hides the title bar and paints the window itself, so no system grey shows through
/// behind the content during a resize.
private struct WindowChrome: NSViewRepresentable {
    let background: NSColor

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let color = background
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = color
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

private struct EmptyDetailView: View {
    let newSession: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 7) {
            Text("No open session")
                .font(.system(size: 12))
                .foregroundStyle(palette.textDim)
            HStack(spacing: 5) {
                Text("Press")
                KbdChip(label: "⌘T", palette: palette)
                Text("to start one, or pick a conversation.")
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.textFaint)
            Button("New Session", action: newSession)
                .controlSize(.small)
                .padding(.top, 4)
        }
    }
}

private struct ExitedBanner: View {
    let activity: TerminalTab.Activity
    let close: () -> Void
    let restart: () -> Void
    @Environment(\.palette) private var palette

    private var code: Int32? {
        if case .exited(let code) = activity { return code }
        return nil
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(activity.endedInFailure ? palette.error : palette.textFaint)
                .frame(width: 6, height: 6)
            Text(
                activity.endedInFailure
                    ? "Session ended with code \(code.map(String.init) ?? "unknown")."
                    : "Session ended."
            )
            .font(.system(size: 11))
            .foregroundStyle(palette.textDim)
            Spacer()
            Button("Restart", action: restart)
                .controlSize(.small)
            Button("Close Tab", action: close)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(palette.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
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

    /// Last two path components, e.g. `scratchpad/wt-pr-a`. The home folder
    /// keeps its `~`, which is shorter than its own two components.
    var breadcrumbPath: String {
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
