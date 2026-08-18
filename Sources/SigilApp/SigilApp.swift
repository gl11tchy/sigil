import AppKit
import SigilKit
import SwiftUI

@main
struct SigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { GrokCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Makes sure no `grok` child process outlives the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.closeAllTabsAndWait() }
    }
}

/// Menu bar commands. Everything here is also reachable from the UI.
struct GrokCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { model.newTab(in: model.currentDirectory) }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Session in Folder…") { model.isShowingNewSessionSheet = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Button("Close Tab") { model.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.tabs.isEmpty)
            Divider()
            Button("Export Transcript…") {
                if let id = model.selectedTab?.sessionID,
                    let session = model.store.sessions.first(where: { $0.id == id })
                {
                    model.exportTranscript(session)
                }
            }
            .disabled(model.selectedTab?.sessionID == nil)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Copy") { model.selectedTab?.controller.copySelection() }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { model.selectedTab?.controller.paste() }
                .keyboardShortcut("v", modifiers: .command)
            Button("Select All") { model.selectedTab?.controller.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                model.isSidebarVisible.toggle()
            }
            .keyboardShortcut("b", modifiers: .command)
            Divider()
            Button("Increase Font Size") { model.adjustFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { model.adjustFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { model.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Reload Conversations") { Task { await model.store.reload() } }
                .keyboardShortcut("r", modifiers: .command)
        }

        CommandGroup(after: .windowList) {
            Button("Next Tab") { model.cycleTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.tabs.count < 2)
            Button("Previous Tab") { model.cycleTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.tabs.count < 2)
            Divider()
            ForEach(1...9, id: \.self) { index in
                Button("Tab \(index)") { model.select(index: index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
    }
}
