import GrokBuildKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            detail
                .navigationTitle(model.selectedTab?.title ?? "GrokBuild")
                .navigationSubtitle(model.selectedTab?.workingDirectory.abbreviatedPath ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Session") { model.newTab(in: model.currentDirectory) }
                        .keyboardShortcut("t")
                    Button("New Session in Folder…") { model.isShowingNewSessionSheet = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                } label: {
                    Label("New Session", systemImage: "plus")
                } primaryAction: {
                    model.newTab(in: model.currentDirectory)
                }
                .help("New session in \(model.currentDirectory.abbreviatedPath)")
            }
        }
        .sheet(isPresented: $model.isShowingNewSessionSheet) {
            NewSessionSheet(model: model)
        }
        .task { model.onAppear() }
    }

    @ViewBuilder
    private var detail: some View {
        if !model.settings.executableExists {
            MissingCLIView(path: model.settings.executablePath)
        } else if model.tabs.isEmpty {
            ContentUnavailableView {
                Label("No open session", systemImage: "terminal")
            } description: {
                Text("Start a conversation, or pick one from the sidebar.")
            } actions: {
                Button("New Session") { model.newTab(in: model.currentDirectory) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 0) {
                if model.tabs.count > 1 {
                    TabStripView(model: model)
                }
                ZStack {
                    ForEach(model.tabs) { tab in
                        let isSelected = tab.id == model.selectedTab?.id
                        TerminalPane(tab: tab)
                            .opacity(isSelected ? 1 : 0)
                            .allowsHitTesting(isSelected)
                            .accessibilityHidden(!isSelected)
                    }
                }
                if let tab = model.selectedTab, case let .exited(code) = tab.activity {
                    ExitedBanner(code: code) { model.closeTab(tab.id) }
                }
            }
        }
    }
}

/// Shown when the wrapped CLI is not where the app expects it.
private struct MissingCLIView: View {
    let path: String

    var body: some View {
        ContentUnavailableView {
            Label("Grok Build CLI not found", systemImage: "exclamationmark.triangle")
        } description: {
            Text("GrokBuild runs the `grok` command line tool. It is not at:\n\(path)")
                .monospaced()
        } actions: {
            SettingsLink { Text("Set the path in Settings…") }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct ExitedBanner: View {
    let code: Int32?
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle")
            Text(
                (code ?? 0) == 0
                    ? "Session ended."
                    : "Session ended with code \(code.map(String.init) ?? "unknown")."
            )
            Spacer()
            Button("Close Tab", action: close)
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension URL {
    /// `~`-abbreviated path, for window subtitles and tooltips.
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
