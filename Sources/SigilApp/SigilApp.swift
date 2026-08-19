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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model else { return .terminateNow }
            let working = model.tabs.filter { $0.activity == .working }.count
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
            Button("Cut") { Self.performTextAction(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") {
                if !Self.performTextAction(#selector(NSText.copy(_:))) {
                    model.selectedTab?.controller.copySelection()
                }
            }
            .keyboardShortcut("c", modifiers: .command)
            Button("Paste") {
                if !Self.performTextAction(#selector(NSText.paste(_:))) {
                    model.selectedTab?.controller.paste()
                }
            }
            .keyboardShortcut("v", modifiers: .command)
            Button("Select All") {
                if !Self.performTextAction(#selector(NSText.selectAll(_:))) {
                    model.selectedTab?.controller.selectAll()
                }
            }
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

    /// The field editor of a focused text field is an `NSTextView`. Forward to
    /// it so these shortcuts do not steal from search, sheets, or Settings.
    @discardableResult
    private static func performTextAction(_ selector: Selector) -> Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return text.tryToPerform(selector, with: nil)
    }
}
