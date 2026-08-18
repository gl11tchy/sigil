import AppKit
import Foundation
import SigilKit
import Observation

/// One terminal tab: a `grok` process, its view, and the state the UI shows about it.
@MainActor
@Observable
final class TerminalTab: Identifiable {

    enum Activity: Equatable {
        case starting
        /// The CLI is drawing — a turn is in flight.
        case working
        case idle
        case exited(code: Int32?)
    }

    let id = UUID()
    let spec: GrokLaunchSpec
    let controller: TerminalController

    private(set) var activity: Activity = .starting
    /// Set when a turn finishes while this tab is in the background.
    var hasUnseenActivity = false

    /// Preferred label. The session summary wins once the sidebar knows one.
    var sessionTitle: String?

    private var idleTask: Task<Void, Never>?

    init(spec: GrokLaunchSpec, settings: AppSettings) {
        self.spec = spec
        self.controller = TerminalController(theme: settings.theme, fontSize: settings.fontSize)
    }

    /// The session this tab reads and writes, when it is known up front.
    var sessionID: String? {
        switch spec.mode {
        case let .new(uuid): return uuid.uuidString.lowercased()
        case let .resume(id): return id
        case .continueLatest: return nil
        }
    }

    var workingDirectory: URL { spec.workingDirectory }

    var title: String {
        if let sessionTitle, !sessionTitle.isEmpty { return sessionTitle }
        let name = workingDirectory.lastPathComponent
        return name.isEmpty ? workingDirectory.path : name
    }

    var isRunning: Bool {
        if case .exited = activity { return false }
        return true
    }

    func start(isSelected: @escaping () -> Bool) {
        controller.onActivity = { [weak self] in
            self?.noteActivity(isSelected: isSelected())
        }
        controller.onTerminate = { [weak self] code in
            guard let self else { return }
            self.idleTask?.cancel()
            self.activity = .exited(code: code)
        }
        controller.start(spec)
        activity = .idle
    }

    /// Output arrived. Hold "working" until the CLI has been quiet for a beat.
    private func noteActivity(isSelected: Bool) {
        if case .exited = activity { return }
        activity = .working
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            if case .exited = self.activity { return }
            self.activity = .idle
            if !isSelected {
                self.hasUnseenActivity = true
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    func terminate() {
        idleTask?.cancel()
        idleTask = nil
        controller.terminate()
    }

    /// Used when the app is quitting: returns only once the child is gone.
    func terminateAndWait() {
        idleTask?.cancel()
        idleTask = nil
        controller.terminateAndWait()
    }

}
