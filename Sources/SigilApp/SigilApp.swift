import AppKit
import Observation
import SigilKit
import SwiftUI

@main
struct SigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var launch: AppLaunch

    init() {
        // Inter and JetBrains Mono, before the first view or terminal asks for them.
        Typeface.registerBundledFonts()
        // A launch without GROK_HOME reads it from the login shell while the
        // window shows. The model is built once it is adopted.
        _launch = State(initialValue: AppLaunch())
    }

    var body: some Scene {
        WindowGroup {
            Self.mainWindow(launch: launch) {
                launch.whenReady { model in
                    delegate.model = model
                    delegate.startRemoteIdleSleep(model)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { GrokCommands(launch: launch) }

        Settings {
            if let model = launch.model {
                SettingsView(model: model)
            }
        }
    }

    /// The window's content. SwiftUI names the window it saves and restores
    /// after this type, so a new modifier here strands the window an earlier
    /// build saved, and the app launches with none. Add modifiers in
    /// `RootView` instead.
    @MainActor static func mainWindow(
        launch: AppLaunch, onAppear: @escaping () -> Void
    ) -> some View {
        RootView(launch: launch)
            .frame(
                minWidth: WindowColumns.minimumWidth(
                    sidebarVisible: launch.model?.isSidebarVisible ?? true,
                    panelVisible: launch.model?.panel.isVisible ?? false
                ),
                minHeight: 460
            )
            .onAppear(perform: onAppear)
    }
}

/// Makes sure no `grok` child process outlives the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?
    @MainActor private var remoteIdleSleep: RemoteIdleSleepWatch?

    override init() {
        super.init()
        // The adaptor builds this delegate before the App's other stored
        // properties, so a crash while the app model itself is being
        // constructed still lands in a report. applicationDidFinishLaunching
        // runs after all of that and would already be too late.
        CrashReporter.install()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.turnOffWindowTabbing()
    }

    /// Every window would share one model, and a terminal view lives in only
    /// one window. A native window tab would take the terminals from the first.
    @MainActor static func turnOffWindowTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { model?.appDidBecomeActive() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model,
                let prompt = StopWorkingPrompt(
                    action: .quit, stopping: model.tabs,
                    panelJob: model.panel.shellHasForegroundJob)
            else { return .terminateNow }
            return prompt.runModal() ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.closeAllTabsAndWait() }
    }

    @MainActor func startRemoteIdleSleep(_ model: AppModel) {
        if remoteIdleSleep == nil {
            remoteIdleSleep = RemoteIdleSleepWatch()
        }
        remoteIdleSleep?.start(model)
    }
}

/// Forwards `RemoteControl.status` for as long as the app delegate lives.
@MainActor
private final class RemoteIdleSleepWatch {
    private let sleep = RemoteIdleSleep()
    private var started = false

    func start(_ model: AppModel) {
        guard !started else { return }
        started = true
        track(model)
    }

    private func track(_ model: AppModel) {
        let status = withObservationTracking {
            model.remoteControl.status
        } onChange: { [weak self, weak model] in
            Task { @MainActor [weak self, weak model] in
                guard let model else { return }
                self?.track(model)
            }
        }
        sleep.apply(status: status)
    }
}

/// Menu bar commands. Everything here is also reachable from the UI.
/// Before the model exists, an action waits for it, and an item that needs
/// a tab or a match stays disabled.
struct GrokCommands: Commands {
    @Bindable var launch: AppLaunch
    private var model: AppModel? { launch.model }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { launch.whenReady { $0.requestNewSession() } }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Session in Folder…") {
                launch.whenReady { model in
                    model.requestNewSessionInFolder { model.pickDirectory() }
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Button("Close Tab") { launch.whenReady(Self.closeTabOrKeyWindow) }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model?.tabs.isEmpty ?? true)
            Divider()
            Button("Export Transcript…") {
                launch.whenReady { $0.exportSelectedTranscript() }
            }
            .disabled(!(model?.canExportSelectedTranscript ?? false))
            Button("Rename Conversation") {
                launch.whenReady { model in
                    if let session = model.sessionForSelectedTab() {
                        model.beginRename(session, returnFocus: .terminal)
                    }
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model?.sessionForSelectedTab() == nil)
            Button(model?.archiveCommandTitle ?? "Archive Conversation") {
                launch.whenReady { $0.performArchiveCommand() }
            }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(!(model?.canArchiveCommand ?? false))
            Button(model?.pinCommandTitle ?? "Pin Conversation") {
                launch.whenReady { $0.performPinCommand() }
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
            .disabled(!(model?.canPinCommand ?? false))
            Divider()
            Button("Deliver Tab Message") { launch.whenReady { $0.deliverSelectedTabMessage() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(model?.canDeliverSelectedTabMessage ?? false))
            Button("Dismiss Tab Message") { launch.whenReady { $0.dismissSelectedTabMessage() } }
                .disabled(!(model?.canDismissSelectedTabMessage ?? false))
            Button("Restart Session") { launch.whenReady { $0.restartSelectedTab() } }
                .disabled(!(model?.canRestartSelectedTab ?? false))
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
            Button("Find") { launch.whenReady { $0.showFindBar() } }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model?.selectedTab == nil)
            Button("Find Next") { launch.whenReady { $0.findNextInTerminal() } }
                .keyboardShortcut("g", modifiers: .command)
                .disabled((model?.findMatchCount ?? 0) == 0)
            Button("Find Previous") { launch.whenReady { $0.findPreviousInTerminal() } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled((model?.findMatchCount ?? 0) == 0)
            Button("Find Conversations") { launch.whenReady { $0.focusSidebarSearch() } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button(model?.isSidebarVisible ?? true ? "Hide Sidebar" : "Show Sidebar") {
                launch.whenReady { model in
                    Self.animateColumn { model.isSidebarVisible.toggle() }
                }
            }
            .keyboardShortcut("b", modifiers: .command)
            Button(model?.panel.isVisible ?? false ? "Hide Panel" : "Show Panel") {
                launch.whenReady { model in
                    Self.animateColumn { model.togglePanel() }
                }
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            Menu("Panel") {
                Button("Terminal") { launch.whenReady { $0.showPanel(.shell) } }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Notes") { launch.whenReady { $0.showPanel(.notes) } }
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
            Divider()
            Button("Increase Font Size") { launch.whenReady { $0.adjustFontSize(by: 1) } }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!(model?.canIncreaseFontSize ?? false))
            Button("Decrease Font Size") { launch.whenReady { $0.adjustFontSize(by: -1) } }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!(model?.canDecreaseFontSize ?? false))
            Button("Actual Size") { launch.whenReady { $0.resetFontSize() } }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!(model?.canResetFontSize ?? false))
            Divider()
            Button("Reload Conversations") {
                launch.whenReady { model in Task { await model.store.reload() } }
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        CommandGroup(after: .windowList) {
            Button("Next Tab") { launch.whenReady { $0.cycleTab(by: 1) } }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((model?.tabs.count ?? 0) < 2)
            Button("Previous Tab") { launch.whenReady { $0.cycleTab(by: -1) } }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((model?.tabs.count ?? 0) < 2)
            Button("Show Tab List…") { launch.whenReady { $0.isShowingTabList.toggle() } }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(!TabListRows.isShown(tabCount: model?.tabs.count ?? 0))
            Divider()
            ForEach(1...9, id: \.self) { index in
                Button("Tab \(index)") { launch.whenReady { $0.select(index: index - 1) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .disabled((model?.tabs.count ?? 0) < index)
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                NSWorkspace.shared.open(
                    URL(string: "https://github.com/gl11tchy/sigil/releases/latest")!)
            }
        }

        // Sigil has no help book, so the default Help item would only say so.
        CommandGroup(replacing: .help) {
            Button("Reveal Crash Logs") { launch.whenReady { $0.revealCrashLogs() } }
        }
    }

    /// The same motion as the toolbar buttons, so ⌘B does not snap.
    private static func animateColumn(_ change: () -> Void) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16), change)
    }

    /// ⌘W belongs to the window in front. Settings and About get the system
    /// Close action, a sheet blocks it, and only the tab window closes a tab.
    private static func closeTabOrKeyWindow(_ model: AppModel) {
        guard let key = NSApp.keyWindow else { return }
        if model.tabs.contains(where: { $0.controller.view.window === key }) {
            model.closeSelectedTab()
        } else if key.sheetParent == nil {
            key.performClose(nil)
        } else {
            NSSound.beep()
        }
    }

    /// The field editor of a focused text field is an `NSTextView`. Forward to
    /// it so these shortcuts do not steal from search, sheets, or Settings.
    @discardableResult
    private static func performTextAction(_ selector: Selector) -> Bool {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
