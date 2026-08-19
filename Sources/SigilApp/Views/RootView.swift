import SigilKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage("window.sidebarWidth") private var sidebarWidth: Double = 272

    private var palette: Palette { Palette(theme: model.settings.theme) }

    var body: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                SidebarView(model: model)
                    .frame(width: sidebarWidth)
                SplitDivider(width: $sidebarWidth)
            }
            detail
        }
        .background(palette.ground)
        .environment(\.palette, palette)
        .background(WindowChrome(background: palette.groundNSColor))
        .sheet(isPresented: $model.isShowingNewSessionSheet) {
            NewSessionSheet(model: model)
        }
        .task { model.onAppear() }
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
        if !model.settings.executableExists {
            MissingCLIView(path: model.settings.executablePath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.tabs.isEmpty {
            EmptyDetailView { model.newTab(in: model.currentDirectory) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    ForEach(model.tabs) { tab in
                        let isSelected = tab.id == model.selectedTab?.id
                        TerminalPane(tab: tab, background: palette.groundNSColor)
                            .opacity(isSelected ? 1 : 0)
                            .allowsHitTesting(isSelected)
                            .accessibilityHidden(!isSelected)
                    }
                    if model.isFindBarVisible, model.selectedTab != nil {
                        TerminalFindBar(
                            query: Bindable(model).findQuery,
                            matchIndex: model.findMatchIndex,
                            matchCount: model.findMatchCount,
                            findNext: { model.findNextInTerminal() },
                            findPrevious: { model.findPreviousInTerminal() },
                            dismiss: { model.dismissFindBar() }
                        )
                        .padding(8)
                    }
                }
                .onChange(of: model.findQuery) { _, _ in
                    model.applyFindQuery()
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

/// The one piece of window chrome: a 38pt band holding the sidebar toggle, what the
/// current session is, and the new-session button. It replaces the title bar entirely.
private struct TopBar: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            // Room for the traffic lights when the sidebar is not holding them.
            if !model.isSidebarVisible {
                Color.clear.frame(width: 68)
            }

            IconButton(
                systemImage: "sidebar.leading",
                help: model.isSidebarVisible ? "Hide Sidebar (⌘B)" : "Show Sidebar (⌘B)"
            ) {
                withAnimation(.easeOut(duration: 0.14)) { model.isSidebarVisible.toggle() }
            }
            .padding(.leading, model.isSidebarVisible ? 8 : 0)

            if model.tabs.count > 1 {
                TabStripView(model: model)
            } else {
                label
                Spacer(minLength: 8)
            }

            IconButton(systemImage: "plus", help: "New Session in \(model.currentDirectory.abbreviatedPath) (⌘T)") {
                model.newTab(in: model.currentDirectory)
            }
            Menu {
                Button("New Session in Folder…") { model.isShowingNewSessionSheet = true }
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
        }
        .frame(height: 36)
        .background(palette.ground)
    }

    @ViewBuilder
    private var label: some View {
        if let tab = model.selectedTab {
            HStack(spacing: 6) {
                StatusDot(activity: tab.activity)
                Text(model.title(for: tab))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(tab.workingDirectory.breadcrumbPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tab.workingDirectory.abbreviatedPath)
            }
            .padding(.leading, 10)
        }
    }
}

/// A 20pt square borderless button. Every icon control in the chrome is one of these.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
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
                        .fill(isHovering ? palette.raised : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? palette.text : palette.textDim)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The draggable seam between the two columns.
private struct SplitDivider: View {
    @Binding var width: Double
    @Environment(\.palette) private var palette
    @State private var widthAtDragStart: Double?

    var body: some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(width: 1)
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

/// Shown when the wrapped CLI is not where the app expects it.
private struct MissingCLIView: View {
    let path: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(palette.textFaint)
            Text("Grok Build CLI not found")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.text)
            Text(path)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(palette.textFaint)
            SettingsLink { Text("Set the path…") }
                .controlSize(.small)
                .padding(.top, 4)
        }
    }
}

private struct EmptyDetailView: View {
    let newSession: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            Text("No open session")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textDim)
            Text("Press ⌘T to start one, or pick a conversation.")
                .font(.system(size: 11))
                .foregroundStyle(palette.textFaint)
            Button("New Session", action: newSession)
                .controlSize(.small)
                .padding(.top, 2)
        }
    }
}

private struct ExitedBanner: View {
    let activity: TerminalTab.Activity
    let close: () -> Void
    let restart: () -> Void
    @Environment(\.palette) private var palette

    private var code: Int32? {
        if case let .exited(code) = activity { return code }
        return nil
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(activity.endedInFailure ? Color.red.opacity(0.8) : palette.textFaint)
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
