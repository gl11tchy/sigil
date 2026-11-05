import AppKit

/// The installed bundle, rather than the current checkout, identifies this app.
struct AppBuildIdentity {
    static var current: Self { Self(info: Bundle.main.infoDictionary ?? [:]) }

    let version: String
    let build: String
    let commit: String

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        build = info["CFBundleVersion"] as? String ?? "unknown"
        commit = info["SigilCommit"] as? String ?? "unknown"
    }

    var shortCommit: String {
        let dirty = commit.hasSuffix("-dirty")
        let source = dirty ? String(commit.dropLast(6)) : commit
        guard source.count == 40 || source.count == 64,
            source.allSatisfy({ "0123456789abcdef".contains($0) })
        else { return "unknown" }
        return String(source.prefix(7)) + (dirty ? "-dirty" : "")
    }

    var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        [.applicationVersion: version, .version: "\(build), \(shortCommit)"]
    }
}

@MainActor
enum AppWindowCommands {
    static func showAboutPanel(identity: AppBuildIdentity = .current) {
        NSApp.orderFrontStandardAboutPanel(options: identity.aboutPanelOptions)
    }

    /// ⌘W belongs to the window in front. Settings and About get the system
    /// Close action, a sheet blocks it, and only the tab window closes a tab.
    static func closeTabOrKeyWindow(_ model: AppModel) {
        guard let key = NSApp.keyWindow else { return }
        if model.tabs.contains(where: { $0.controller.view.window === key }) {
            model.closeSelectedTab()
        } else if key.sheetParent == nil {
            key.performClose(nil)
        } else {
            NSSound.beep()
        }
    }

}
