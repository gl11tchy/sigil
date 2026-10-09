import AppKit
import Foundation
import Observation
import SigilKit

/// One terminal tab: a provider CLI, its view, and the state the UI shows about it.
@MainActor
@Observable
final class TerminalTab: Identifiable {

    struct BridgeInboxItem: Identifiable {
        let id = UUID()
        let prompt: String
        let requestID: String?
        fileprivate let onDismiss: (() -> Void)?
    }

    typealias Activity = SessionLifecycleState

    let id: UUID
    let spec: GrokLaunchSpec
    let controller: TerminalController
    let remoteInteraction = RemoteInteraction()

    private(set) var activity: Activity = .starting {
        didSet {
            guard activity != oldValue else { return }
            workingSince = activity == .working ? Date() : nil
            onActivityChange?()
        }
    }
    /// Called after `activity` changes, so the phone stream can send the new status.
    var onActivityChange: (() -> Void)?
    /// When the turn in flight started, for the elapsed time beside "Working".
    private(set) var workingSince: Date?
    /// Set when a turn finishes while this tab is in the background.
    private(set) var hasUnseenActivity = false
    private(set) var bridgeInbox: [BridgeInboxItem] = []
    var onUnseenActivityChange: (() -> Void)?
    /// Called when a turn ends or the inbox empties, so work held back until
    /// then can run.
    var onSettle: (() -> Void)?
    private var hasUnseenTurnCompletion = false
    private var unseenBridgeItemIDs: Set<UUID> = []

    /// Preferred label. The session summary wins once the sidebar knows one.
    var sessionTitle: String?
    /// Color for a tab that is not a saved Grok conversation. Saved
    /// conversations keep their color in settings, keyed by session id.
    var markColor: TabColor?

    private var isSelected: () -> Bool = { false }
    private let completionEventsURL: URL?
    private var completionWatchTask: Task<Void, Never>?

    init(
        id: UUID = UUID(),
        spec: GrokLaunchSpec,
        settings: AppSettings,
        completionEventsURL: URL? = nil
    ) {
        self.id = id
        self.spec = spec
        self.controller = TerminalController(theme: settings.theme, fontSize: settings.fontSize)
        controller.optionAsMetaKey = settings.optionAsMetaKey
        self.completionEventsURL =
            completionEventsURL
            ?? (spec.provider == .grokBuild
                ? spec.sessionDirectory?.appendingPathComponent("updates.jsonl") : spec.sessionFile)
    }

    /// A native identity established by exact process/file evidence or an
    /// explicit user link. Discovering a file in the same folder is insufficient.
    var learnedSessionReference: ProviderSessionReference?
    /// Automatic live bindings are rechecked. An explicit user link has no
    /// process proof to inherit or silently change.
    var codexBindingGeneration: ChildProcessGeneration?

    /// No native ID is fabricated for providers that allocate one internally.
    var sessionReference: ProviderSessionReference? {
        if let learnedSessionReference { return learnedSessionReference }
        switch spec.mode {
        case .new(let uuid) where spec.provider == .grokBuild || spec.provider == .claudeCode:
            return ProviderSessionReference(
                provider: spec.provider, sessionID: uuid.uuidString.lowercased(), cwd: workingDirectory.path)
        case .resume(let id) where spec.provider.capabilities.resume:
            return ProviderSessionReference(provider: spec.provider, sessionID: id, cwd: workingDirectory.path)
        default: return nil
        }
    }

    var sessionID: String? { sessionReference?.sidebarID }
    var nativeSessionID: String? { sessionReference?.sessionID }
    var capabilities: ProviderCapabilities {
        spec.provider.capabilities.forSession(
            hasIdentity: sessionReference != nil,
            hasLifecycleJournal: completionEventsURL != nil && sessionReference != nil)
    }

    var workingDirectory: URL { spec.workingDirectory }

    /// The label before a person renames the tab. Two tabs of one provider
    /// must not share a title, so other agents include the folder.
    var automaticTitle: String {
        let name = workingDirectory.lastPathComponent
        let folder = workingDirectory.sigilWorktreeLabel ?? (name.isEmpty ? workingDirectory.path : name)
        if spec.provider != .grokBuild { return "\(spec.provider.name) · \(folder)" }
        return folder
    }

    var title: String {
        if let sessionTitle, !sessionTitle.isEmpty { return sessionTitle }
        return automaticTitle
    }

    var isRunning: Bool {
        if case .exited = activity { return false }
        return true
    }

    var canDeliverBridgePrompt: Bool {
        spec.provider == .grokBuild && activity == .idle && controller.isRunning
    }

    /// Uncertain work is never silently closed as if it had completed.
    var shouldWarnBeforeStopping: Bool {
        guard controller.isRunning else { return false }
        switch activity {
        case .idle, .exited: return false
        default: return true
        }
    }

    func start(isSelected: @escaping () -> Bool) {
        self.isSelected = isSelected
        controller.onUserSubmit = { [weak self] in self?.noteTurnStarted() }
        controller.onActivity = { [weak self] in self?.noteTerminalOutput() }
        controller.onTitleChange = { [weak self] title in self?.noteTerminalTitle(title) }
        controller.onTerminate = { [weak self] code in
            guard let self else { return }
            self.stopTurnTracking()
            self.remoteInteraction.invalidate()
            self.activity = .exited(code: code)
            // A process exit is not a successfully completed turn.
        }
        controller.start(spec)
        if controller.isRunning {
            activity = .unknown
        } else if case .starting = activity {
            activity = .exited(code: nil)
        }
    }

    /// Return means input was submitted, not accepted or completed.
    func noteTurnStarted() {
        if case .exited = activity { return }
        stopTurnTracking()
        activity = .working
        watchForTurnCompletion()
    }

    func noteTerminalOutput() {
        // Drawing and silence have no completion semantics.
    }

    func noteTerminalTitle(_ title: String) {
        // Titles are presentation only. They do not establish lifecycle truth.
    }

    func noteInterrupted() {
        stopTurnTracking()
        activity = .interrupted
        remoteInteraction.invalidate()
    }

    func noteWaitingForApproval() {
        guard controller.isRunning else { return }
        activity = .waitingForApproval
    }

    func noteDisconnected() {
        stopTurnTracking()
        activity = .disconnected
    }

    /// Kept only as a presentation parser; never drives state or notifications.
    static func titleShowsWork(_ title: String, provider: CLIProvider) -> Bool? {
        guard let first = title.unicodeScalars.first else { return nil }
        let braille = (0x2800...0x28FF).contains(first.value)
        switch provider {
        case .claudeCode:
            if braille || "◐◑◒◓".unicodeScalars.contains(first) { return true }
            return first == "✳" ? false : nil
        case .codex:
            return braille
        case .cursor, .devin, .kimi, .grokBuild:
            return nil
        }
    }

    static func isBusyTerminalTitle(_ title: String) -> Bool {
        let components = title.lowercased().split(separator: "-").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard components.last == "grok",
            components.count >= 3,
            let spinner = components.first?.unicodeScalars.first,
            (0x2800...0x28FF).contains(spinner.value)
        else { return false }
        switch components[components.count - 2] {
        case "waiting for response…", "waiting for response...", "thinking", "responding":
            return true
        default:
            return false
        }
    }

    private func watchForTurnCompletion() {
        guard completionWatchTask == nil, let completionEventsURL, let nativeSessionID else { return }
        var journal = ProviderLifecycleJournal(
            url: completionEventsURL, provider: spec.provider, sessionID: nativeSessionID)
        completionWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = journal
                let result = await Task.detached(priority: .utility) {
                    var next = snapshot
                    let events = next.poll()
                    return (next, events)
                }.value
                guard !Task.isCancelled else { return }
                journal = result.0
                guard let self else { return }
                for state in result.1 {
                    if state == .idle { self.noteTurnCompleted() } else { self.activity = state }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func noteTurnCompleted() {
        guard activity == .working || activity == .waitingForApproval else { return }
        activity = .idle
        if !isSelected() { markUnseenTurnCompletion() }
        onSettle?()
    }

    private func stopTurnTracking() {
        completionWatchTask?.cancel()
        completionWatchTask = nil
    }

    func enqueueBridgePrompt(
        _ prompt: String,
        requestID: String? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        let item = BridgeInboxItem(prompt: prompt, requestID: requestID, onDismiss: onDismiss)
        bridgeInbox.append(item)
        if !isSelected() {
            unseenBridgeItemIDs.insert(item.id)
            refreshUnseenActivity(requestAttention: true)
        }
    }

    func deliverNextBridgePrompt() {
        guard canDeliverBridgePrompt, !bridgeInbox.isEmpty else { return }
        let item = bridgeInbox.removeFirst()
        removeUnseenBridgeItem(item.id)
        noteTurnStarted()
        controller.send(text: item.prompt + "\r")
    }

    func dismissNextBridgePrompt() {
        guard !bridgeInbox.isEmpty else { return }
        let item = bridgeInbox.removeFirst()
        removeUnseenBridgeItem(item.id)
        item.onDismiss?()
        if bridgeInbox.isEmpty { onSettle?() }
    }

    /// Drops a question that already timed out or was cancelled. This is not a
    /// user dismissal, so it must not try to cancel the same ask again.
    func removeBridgePrompt(requestID: String) {
        guard let index = bridgeInbox.firstIndex(where: { $0.requestID == requestID }) else {
            return
        }
        let item = bridgeInbox.remove(at: index)
        removeUnseenBridgeItem(item.id)
        if bridgeInbox.isEmpty { onSettle?() }
    }

    func clearUnseenActivity() {
        guard hasUnseenActivity else { return }
        hasUnseenTurnCompletion = false
        unseenBridgeItemIDs.removeAll()
        refreshUnseenActivity()
    }

    /// Carries what a replaced tab still owes the user: its queued messages and
    /// an unread finished turn. Questions stay behind, because closing the old
    /// tab has already answered them. The replacement already owns its callback.
    func restoreUnseenActivity(from previous: TerminalTab) {
        let carried = previous.bridgeInbox.filter { item in
            item.requestID == nil && !bridgeInbox.contains { $0.id == item.id }
        }
        bridgeInbox.append(contentsOf: carried)
        unseenBridgeItemIDs.formUnion(
            carried.map(\.id).filter { previous.unseenBridgeItemIDs.contains($0) })
        if previous.hasUnseenTurnCompletion { hasUnseenTurnCompletion = true }
        refreshUnseenActivity()
    }

    private func markUnseenTurnCompletion() {
        hasUnseenTurnCompletion = true
        refreshUnseenActivity(requestAttention: true)
    }

    private func removeUnseenBridgeItem(_ id: UUID) {
        guard unseenBridgeItemIDs.remove(id) != nil else { return }
        refreshUnseenActivity()
    }

    private func refreshUnseenActivity(requestAttention: Bool = false) {
        let unseen = hasUnseenTurnCompletion || !unseenBridgeItemIDs.isEmpty
        guard unseen != hasUnseenActivity else { return }
        hasUnseenActivity = unseen
        onUnseenActivityChange?()
        if unseen, requestAttention {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func terminate() {
        noteInterrupted()
        controller.terminate()
    }

    /// Used when the app is quitting: returns only once the child is gone.
    func terminateAndWait(timeout: Duration = .milliseconds(1500)) {
        noteInterrupted()
        controller.terminateAndWait(timeout: timeout)
    }

}
