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
                .frame(
                    minWidth: WindowColumns.minimumWidth(
                        sidebarVisible: model.isSidebarVisible,
                        panelVisible: model.panel.isVisible
                    ),
                    minHeight: 460
                )
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

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { model?.appDidBecomeActive() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model else { return .terminateNow }
            let working = model.tabs.filter(\.shouldWarnBeforeStopping).count
            guard working > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText =
                working == 1
                ? "A session is still working. Quit anyway?"
                : "\(working) sessions are still working. Quit anyway?"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.closeAllTabsAndWait() }
    }
}

/// Menu bar commands. Everything here is also reachable from the UI.
struct GrokCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { model.newTab(in: model.newSessionDirectory) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!model.settings.executableExists)
            Button("New Session in Folder…") { model.isShowingNewSessionSheet = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.settings.executableExists)
        }

        CommandGroup(after: .newItem) {
            Button("Close Tab") { model.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.tabs.isEmpty)
            Divider()
            Button("Export Transcript…") {
                model.exportSelectedTranscript()
            }
            .disabled(!model.canExportSelectedTranscript)
            Button("Rename Conversation") {
                if let session = model.sessionForSelectedTab() {
                    model.beginRename(session)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.sessionForSelectedTab() == nil)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { Self.performTextAction(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") { Self.performTextAction(#selector(NSText.copy(_:))) }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { Self.performTextAction(#selector(NSText.paste(_:))) }
                .keyboardShortcut("v", modifiers: .command)
            Button("Select All") { Self.performTextAction(#selector(NSText.selectAll(_:))) }
                .keyboardShortcut("a", modifiers: .command)
        }

        CommandGroup(after: .pasteboard) {
            Button("Find") { model.toggleFindBar() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.selectedTab == nil)
            Button("Find Conversations") { model.focusSidebarSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                model.isSidebarVisible.toggle()
            }
            .keyboardShortcut("b", modifiers: .command)
            Button(model.panel.isVisible ? "Hide Panel" : "Show Panel") {
                model.togglePanel()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            Menu("Panel") {
                Button("Terminal") { model.showPanel(.shell) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Notes") { model.showPanel(.notes) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
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
                    .disabled(model.tabs.count < index)
            }
        }

        CommandGroup(after: .help) {
            Button("Check for Updates…") {
                NSWorkspace.shared.open(
                    URL(string: "https://github.com/gl11tchy/sigil/releases/latest")!)
            }
        }
    }

    /// The field editor of a focused text field is an `NSTextView`. Forward to
    /// it so these shortcuts do not steal from search, sheets, or Settings.
    @discardableResult
    private static func performTextAction(_ selector: Selector) -> Bool {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
