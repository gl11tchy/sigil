import Foundation
import Observation
import SigilKit
import SwiftUI
import WebKit

/// The tool the right panel is showing.
enum RightPanelMode: String, CaseIterable, Identifiable, Sendable {
    case shell
    case web
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shell: return "Terminal"
        case .web: return "Browser"
        case .notes: return "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .shell: return "terminal"
        case .web: return "globe"
        case .notes: return "square.and.pencil"
        }
    }
}

/// State for the right-hand utility panel: a scratch shell, a dev-server browser,
/// and a per-folder notes pad.
///
/// The panel is deliberately independent of the tabs on the left. It follows the
/// current tab's working folder when it opens, and then stays where the user put it.
@MainActor
@Observable
final class RightPanel: NSObject {
    private enum Key {
        static let isVisible = "panel.visible"
        static let mode = "panel.mode"
        static let width = "panel.width"
        static let homeURL = "panel.homeURL"
        static let notes = "panel.notes"
    }

    /// Kept in step with the window so a resize cannot squeeze the terminal away.
    static let minWidth: Double = 280
    static let maxWidth: Double = 900

    private let defaults: UserDefaults

    var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Key.isVisible) }
    }
    var mode: RightPanelMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    var width: Double {
        didSet { defaults.set(width, forKey: Key.width) }
    }
    /// What the browser loads when the panel first opens, and what Home returns to.
    var homeURL: String {
        didSet { defaults.set(homeURL, forKey: Key.homeURL) }
    }
    /// What is in the address field right now. Committing it navigates.
    var addressField: String
    /// The address the web view has been asked to load.
    private(set) var requestedURL: URL?
    /// Bumped to force a reload of the same address.
    private(set) var reloadToken = 0

    @ObservationIgnored private var browser: WKWebView?
    @ObservationIgnored var isEditingAddress = false
    private(set) var isLoadingPage = false
    private(set) var addressError: String?
    private(set) var pageError: String?

    /// The scratch shell, created on first use so a hidden panel costs nothing.
    private(set) var shell: TerminalController?
    private(set) var shellDirectory: URL?

    /// Notes text, keyed by folder path.
    private var notesByPath: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isVisible = defaults.bool(forKey: Key.isVisible)
        if let raw = defaults.string(forKey: Key.mode), let stored = RightPanelMode(rawValue: raw) {
            mode = stored
        } else {
            mode = .shell
        }
        let storedWidth = defaults.double(forKey: Key.width)
        width = storedWidth > 0 ? min(max(storedWidth, Self.minWidth), Self.maxWidth) : 380
        let storedHome = defaults.string(forKey: Key.homeURL) ?? "http://localhost:3000"
        homeURL = storedHome
        addressField = storedHome
        if let data = defaults.data(forKey: Key.notes),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            notesByPath = decoded
        } else {
            notesByPath = [:]
        }
        super.init()
    }

    // MARK: - Visibility

    /// Opens the panel on `mode`, or closes it when that tool is already showing.
    func toggle(_ requested: RightPanelMode? = nil, in directory: URL) {
        if let requested, isVisible, requested != mode {
            mode = requested
            prepare(in: directory)
            return
        }
        isVisible.toggle()
        if let requested { mode = requested }
        if isVisible { prepare(in: directory) }
    }

    /// Starts whatever the visible tool needs and has not got yet.
    func prepare(in directory: URL) {
        switch mode {
        case .shell:
            break
        case .web:
            if requestedURL == nil { navigate(to: addressField) }
        case .notes:
            break
        }
    }

    // MARK: - Shell

    /// Creates and starts the scratch shell in `directory`. A shell that is already
    /// running is left alone, even if the selected tab has since moved folder.
    func startShellIfNeeded(in directory: URL, theme: TerminalTheme = .grokNight, fontSize: CGFloat = 13) {
        if let shell, shell.isRunning { return }
        shell?.terminateAndWait()
        let controller = TerminalController(theme: theme, fontSize: fontSize)
        shell = controller
        shellDirectory = directory
        controller.startShell(ShellLaunchSpec(workingDirectory: directory))
    }

    /// Kills the shell and starts a fresh one in `directory`.
    func restartShell(in directory: URL, theme: TerminalTheme = .grokNight, fontSize: CGFloat = 13) {
        shell?.terminateAndWait()
        shell = TerminalController(theme: theme, fontSize: fontSize)
        shellDirectory = directory
        shell?.startShell(ShellLaunchSpec(workingDirectory: directory))
    }

    func closeShellAndWait() {
        shell?.terminateAndWait()
        shell = nil
        shellDirectory = nil
    }

    // MARK: - Browser

    /// Turns whatever is in the address field into a URL and asks the web view for it.
    /// A bare host or `:port` is treated as `http://localhost`, which is what a dev
    /// server needs and what a person types.
    func navigate(to text: String) {
        guard let url = Self.resolve(text) else {
            addressError = "Enter a web address or a port from 1 to 65535."
            return
        }
        isEditingAddress = false
        addressError = nil
        pageError = nil
        addressField = url.absoluteString
        requestedURL = url
        isLoadingPage = true
        browser?.load(URLRequest(url: url))
    }

    func finishEditingAddress() {
        isEditingAddress = false
        if let url = browser?.url ?? requestedURL {
            requestedURL = url
            addressField = url.absoluteString
        }
    }

    func browserView() -> WKWebView {
        if let browser { return browser }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        browser = view
        if let requestedURL {
            view.load(URLRequest(url: requestedURL))
        }
        return view
    }

    func reload() {
        reloadToken += 1
        let hadError = pageError != nil
        pageError = nil
        guard let browser else { return }
        if hadError, let requestedURL {
            isLoadingPage = true
            browser.load(URLRequest(url: requestedURL))
        } else {
            isLoadingPage = true
            browser.reload()
        }
    }

    func goHome() {
        addressField = homeURL
        navigate(to: homeURL)
    }

    /// Makes the current address the one the panel opens on.
    func setHomeToCurrentAddress() {
        guard let requestedURL else { return }
        homeURL = requestedURL.absoluteString
    }

    static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }),
            !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        if trimmed.hasPrefix(":") || trimmed.allSatisfy(\.isNumber) {
            let raw = trimmed.hasPrefix(":") ? String(trimmed.dropFirst()) : trimmed
            guard let port = Int(raw), (1...65535).contains(port) else { return nil }
            return URL(string: "http://localhost:\(port)")
        }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let parts = URLComponents(string: candidate),
            let scheme = parts.scheme?.lowercased(), ["http", "https", "file"].contains(scheme),
            parts.user == nil, parts.password == nil,
            parts.port.map({ (1...65535).contains($0) }) ?? true,
            let url = parts.url
        else { return nil }
        if scheme == "file" { return url.isFileURL && parts.path.hasPrefix("/") ? url : nil }
        guard let host = parts.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: - Notes

    func notes(for directory: URL) -> String {
        notesByPath[directory.path] ?? ""
    }

    func setNotes(_ text: String, for directory: URL) {
        if text.isEmpty {
            notesByPath.removeValue(forKey: directory.path)
        } else {
            notesByPath[directory.path] = text
        }
        if let data = try? JSONEncoder().encode(notesByPath) {
            defaults.set(data, forKey: Key.notes)
        }
    }
}

extension RightPanel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        isLoadingPage = true
        pageError = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        syncAddress(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoadingPage = false
        syncAddress(from: webView)
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        notePageFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        notePageFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoadingPage = false
        pageError = "The page stopped. Reload to try again."
    }

    private func syncAddress(from webView: WKWebView) {
        guard let url = webView.url else { return }
        requestedURL = url
        if !isEditingAddress { addressField = url.absoluteString }
    }

    private func notePageFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        isLoadingPage = false
        pageError = error.localizedDescription
    }
}
