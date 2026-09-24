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

    enum Activity: Equatable {
        case starting
        /// The CLI is drawing — a turn is in flight.
        case working
        case idle
        case exited(code: Int32?)

        /// True only for a known nonzero exit code. A missing code is not a failure.
        var endedInFailure: Bool {
            guard case .exited(let code?) = self else { return false }
            return code != 0
        }

        /// The machine-readable name: the remote wire sends this, and a crash
        /// report lists it. A label meant for a person belongs in the view.
        var statusName: String {
            switch self {
            case .starting: return "starting"
            case .working: return "working"
            case .idle: return "idle"
            case .exited: return "exited"
            }
        }
    }

    let id: UUID
    let spec: GrokLaunchSpec
    let controller: TerminalController

    private(set) var activity: Activity = .starting {
        didSet {
            guard activity != oldValue else { return }
            workingSince = activity == .working ? Date() : nil
        }
    }
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

    private var isSelected: () -> Bool = { false }
    private let completionEventsURL: URL?
    private var completionWatchTask: Task<Void, Never>?
    private var idleFallbackTask: Task<Void, Never>?
    private var hasConfirmedJournalActivity = false

    /// Quiet period after the last submit or child output that returns a tab
    /// to idle when the journal never writes `turn_completed`.
    static let idleFallbackSilence: Duration = .milliseconds(1200)
    /// After the journal has confirmed work, wait this long with no further
    /// journal, title, or output activity before treating the turn as finished.
    var journalIdleFallbackSilence: Duration = .seconds(30)

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
            ?? spec.sessionDirectory?.appendingPathComponent("updates.jsonl")
    }

    /// The session this tab reads and writes, when it is known up front.
    var sessionID: String? {
        // Only Grok sessions participate in the sidebar, export, and restoration.
        guard spec.provider == .grokBuild else { return nil }
        switch spec.mode {
        case .new(let uuid): return uuid.uuidString.lowercased()
        case .resume(let id): return id
        case .continueLatest: return nil
        }
    }

    var workingDirectory: URL { spec.workingDirectory }

    var title: String {
        if let sessionTitle, !sessionTitle.isEmpty { return sessionTitle }
        let name = workingDirectory.lastPathComponent
        let folder = workingDirectory.sigilWorktreeLabel ?? (name.isEmpty ? workingDirectory.path : name)
        // Two tabs of one provider must not share a title.
        if spec.provider != .grokBuild { return "\(spec.provider.name) · \(folder)" }
        return folder
    }

    var isRunning: Bool {
        if case .exited = activity { return false }
        return true
    }

    var canDeliverBridgePrompt: Bool {
        spec.provider == .grokBuild && activity == .idle && controller.isRunning
    }

    /// Other providers have no turn-completion integration. Conservatively
    /// warn whenever their process is running, including startup prompts.
    var shouldWarnBeforeStopping: Bool {
        if spec.provider != .grokBuild { return controller.isRunning }
        switch activity {
        case .starting, .working: return controller.isRunning
        case .idle, .exited: return false
        }
    }

    func start(isSelected: @escaping () -> Bool) {
        self.isSelected = isSelected
        controller.onUserSubmit = { [weak self] in
            // Other providers report turns through their title instead.
            guard let self, self.spec.provider == .grokBuild else { return }
            self.noteTurnStarted()
        }
        controller.onActivity = { [weak self] in
            self?.noteTerminalOutput()
        }
        controller.onTitleChange = { [weak self] title in
            self?.noteTerminalTitle(title)
        }
        controller.onTerminate = { [weak self] code in
            guard let self else { return }
            self.stopTurnTracking()
            let notify = self.activity == .working && !self.isSelected()
            self.activity = .exited(code: code)
            if notify { self.markUnseenTurnCompletion() }
        }
        controller.start(spec)
        if controller.isRunning {
            activity = .idle
        } else if case .starting = activity {
            activity = .exited(code: nil)
        }
    }

    /// A user submission is a real turn boundary. The journal is authoritative
    /// when it writes `turn_completed`; output silence is the fallback when
    /// that event never arrives (empty Return, missing journal).
    func noteTurnStarted() {
        if case .exited = activity { return }
        let needsWatcher = completionWatchTask == nil
        activity = .working
        armIdleFallback()
        if needsWatcher {
            hasConfirmedJournalActivity = false
            watchForTurnCompletion()
        }
    }

    /// Child output resets the silence fallback so a turn that is still
    /// drawing never goes idle. Output never starts a turn on its own.
    func noteTerminalOutput() {
        if case .exited = activity { return }
        guard activity == .working else { return }
        armIdleFallback()
    }

    /// Busy spinner titles can reveal work that did not start through this
    /// view's input path. Titles never mark a turn complete; they only start
    /// a turn or keep the silence fallback from firing during a wait.
    func noteTerminalTitle(_ title: String) {
        guard spec.provider == .grokBuild else {
            noteProviderTitle(title)
            return
        }
        guard Self.isBusyTerminalTitle(title) else { return }
        if activity == .working {
            armIdleFallback()
            return
        }
        noteTurnStarted()
    }

    /// Claude Code and Codex have no journal, so their title is the only
    /// turn signal: a spinner leads it while a turn runs and is gone once it
    /// ends. Cursor, Devin and Kimi Code never show a spinner there, so they
    /// never show Working.
    private func noteProviderTitle(_ title: String) {
        if case .exited = activity { return }
        switch Self.titleShowsWork(title, provider: spec.provider) {
        case true?: activity = .working
        case false?: noteTurnCompleted()
        case nil: break
        }
    }

    /// `true` for a busy title, `false` for an idle one, `nil` when the
    /// title says nothing. Claude Code idles on `✳` and spins `◐◓◑◒`; Codex
    /// spins a braille glyph and drops it when idle.
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

    /// Grok 1.0.5 keeps its terminal title at `grok`, including while idle. Its
    /// append-only event journal is the authoritative turn boundary when the
    /// file exists. A missing `updates.jsonl` is still watched so a later
    /// create can complete the turn; silence covers the case where it never
    /// writes `turn_completed`.
    private func watchForTurnCompletion() {
        guard completionWatchTask == nil else { return }
        guard let completionEventsURL else { return }
        var offset = Self.fileSize(at: completionEventsURL) ?? 0
        completionWatchTask = Task { [weak self] in
            var remainder = Data()
            var discardingOversizedLine = false
            while !Task.isCancelled {
                guard self != nil else { return }
                let scanOffset = offset
                let scanRemainder = remainder
                let scanDiscardingOversizedLine = discardingOversizedLine
                let scan = await Task.detached(priority: .utility) {
                    Self.scanCompletionEvents(
                        at: completionEventsURL,
                        offset: scanOffset,
                        remainder: scanRemainder,
                        discardingOversizedLine: scanDiscardingOversizedLine
                    )
                }.value
                guard !Task.isCancelled else { return }
                offset = scan.offset
                remainder = scan.remainder
                discardingOversizedLine = scan.discardingOversizedLine
                if scan.didObserveWork {
                    self?.hasConfirmedJournalActivity = true
                    self?.armIdleFallback()
                }
                if scan.didCompleteTurn {
                    self?.noteTurnCompleted()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func noteTurnCompleted() {
        guard activity == .working else { return }
        stopTurnTracking()
        activity = .idle
        if !isSelected() { markUnseenTurnCompletion() }
        onSettle?()
    }

    private func armIdleFallback() {
        // Output silence is not completion for providers without a journal.
        // Keep their submitted work active until the process actually exits.
        guard spec.provider == .grokBuild else { return }
        idleFallbackTask?.cancel()
        let silence =
            hasConfirmedJournalActivity
            ? journalIdleFallbackSilence : Self.idleFallbackSilence
        idleFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: silence)
            guard !Task.isCancelled, let self else { return }
            self.noteTurnCompleted()
        }
    }

    private func stopTurnTracking() {
        idleFallbackTask?.cancel()
        idleFallbackTask = nil
        completionWatchTask?.cancel()
        completionWatchTask = nil
        hasConfirmedJournalActivity = false
    }

    private struct CompletionScan: Sendable {
        let offset: UInt64
        let remainder: Data
        let discardingOversizedLine: Bool
        let didCompleteTurn: Bool
        var didObserveWork = false
    }

    private struct JournalEnvelope: Decodable {
        struct Parameters: Decodable {
            struct Update: Decodable { let sessionUpdate: String? }
            let update: Update?
        }
        let params: Parameters?
    }

    nonisolated private static func fileSize(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.uint64Value
    }

    nonisolated private static func scanCompletionEvents(
        at url: URL,
        offset: UInt64,
        remainder: Data,
        discardingOversizedLine: Bool
    ) -> CompletionScan {
        guard let size = fileSize(at: url) else {
            return CompletionScan(
                offset: offset,
                remainder: remainder,
                discardingOversizedLine: discardingOversizedLine,
                didCompleteTurn: false
            )
        }
        // A replaced or truncated journal starts a new baseline. Reading from
        // zero could mistake an old completed turn for this one.
        guard size >= offset else {
            return CompletionScan(
                offset: size,
                remainder: Data(),
                discardingOversizedLine: false,
                didCompleteTurn: false
            )
        }
        guard size > offset,
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return CompletionScan(
                offset: offset,
                remainder: remainder,
                discardingOversizedLine: discardingOversizedLine,
                didCompleteTurn: false
            )
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: 256 * 1024) ?? Data()
            var buffer = remainder
            buffer.append(data)
            var discarding = discardingOversizedLine
            var completed = false
            var observedWork = false

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if discarding {
                    discarding = false
                } else if line.count <= 1_048_576,
                    let event = try? JSONDecoder().decode(JournalEnvelope.self, from: line)
                {
                    switch event.params?.update?.sessionUpdate {
                    case "turn_completed":
                        completed = true
                    case "agent_message_chunk", "agent_thought_chunk", "tool_call",
                        "tool_call_update":
                        observedWork = true
                    default:
                        break
                    }
                    if completed { break }
                }
            }
            if buffer.count > 1_048_576 {
                buffer.removeAll(keepingCapacity: false)
                discarding = true
            }
            return CompletionScan(
                offset: offset + UInt64(data.count),
                remainder: buffer,
                discardingOversizedLine: discarding,
                didCompleteTurn: completed,
                didObserveWork: observedWork
            )
        } catch {
            return CompletionScan(
                offset: offset,
                remainder: remainder,
                discardingOversizedLine: discardingOversizedLine,
                didCompleteTurn: false
            )
        }
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
        stopTurnTracking()
        controller.terminate()
    }

    /// Used when the app is quitting: returns only once the child is gone.
    func terminateAndWait(timeout: Duration = .milliseconds(1500)) {
        stopTurnTracking()
        controller.terminateAndWait(timeout: timeout)
    }

}
