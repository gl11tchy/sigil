import Foundation

/// One open tab, as the broker sees it. Independent of `TerminalTab` so routing
/// and the pending-ask registry can be tested without a live pty.
public struct BridgeTabRef: Equatable, Sendable, Hashable {
    public var tabID: String
    public var sessionID: String?
    public var title: String
    public var directory: String
    /// `working`, `idle`, or `exited`.
    public var status: String
    public var isRunning: Bool

    public init(
        tabID: String,
        sessionID: String? = nil,
        title: String,
        directory: String,
        status: String,
        isRunning: Bool
    ) {
        self.tabID = tabID
        self.sessionID = sessionID
        self.title = title
        self.directory = directory
        self.status = status
        self.isRunning = isRunning
    }
}

public enum BridgePeerMatch: Equatable, Sendable {
    case found(BridgeTabRef)
    case notFound
}

public enum BridgeTargetMatch: Equatable, Sendable {
    case found(BridgeTabRef)
    case notFound
    case selfTarget(BridgeTabRef)
    case ambiguous([BridgeTabRef])
}

/// Resolves a calling peer and a send/ask target against a fixed tab list.
public enum BridgeRouting {

    /// A supplied tab id is authoritative. Only fall back to the session id
    /// when no tab id was supplied; a stale helper must not impersonate a new tab.
    public static func matchPeer(_ peer: BridgePeer, tabs: [BridgeTabRef]) -> BridgePeerMatch {
        if let tabID = peer.tabID?.nilIfBlank {
            guard let tab = tabs.first(where: { $0.tabID == tabID }) else {
                return .notFound
            }
            return .found(tab)
        }
        if let sessionID = peer.sessionID?.nilIfBlank,
            let tab = tabs.first(where: { $0.sessionID == sessionID })
        {
            return .found(tab)
        }
        return .notFound
    }

    /// Match `target` as a tab id first (exact), then as a title (case-insensitive).
    /// Several title hits are ambiguous; the caller's own tab is never a valid dest.
    public static func matchTarget(
        _ target: String, callerID: String, tabs: [BridgeTabRef]
    ) -> BridgeTargetMatch {
        let needle = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return .notFound }

        if let exact = tabs.first(where: { $0.tabID == needle }) {
            if exact.tabID == callerID { return .selfTarget(exact) }
            return .found(exact)
        }

        let titles = tabs.filter {
            $0.title.compare(needle, options: .caseInsensitive) == .orderedSame
        }
        if titles.isEmpty { return .notFound }
        if titles.count > 1 { return .ambiguous(titles) }
        let hit = titles[0]
        if hit.tabID == callerID { return .selfTarget(hit) }
        return .found(hit)
    }
}

/// Shapes untrusted text into a single-line prompt the receiving pty can submit.
public enum BridgePrompt {

    public static func send(fromTitle: String, fromTabID: String, message: String) -> String {
        let title = displayTitle(fromTitle, fallback: fromTabID)
        let body = sanitize(message)
        return
            "\(marker) Message from tab \"\(title)\" (\(fromTabID)). No reply is expected. Message: \(body)"
    }

    public static func ask(
        fromTitle: String, fromTabID: String, requestID: String, question: String
    ) -> String {
        let title = displayTitle(fromTitle, fallback: fromTabID)
        let body = sanitize(question)
        return
            "\(marker) Question from tab \"\(title)\" (\(fromTabID)). Request id: \(requestID). Answer by calling the reply_to tool with request_id \(requestID). Question: \(body)"
    }

    /// The prefix every delivered prompt opens with. Removed from untrusted
    /// bodies so a message cannot forge a second frame that looks like Sigil.
    public static let marker = "[Sigil]"

    /// Drops control characters and flattens newlines so a payload cannot close
    /// this frame and open a forged one.
    public static func sanitize(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" {
                scalars.append("\n")
                continue
            }
            if scalar == "\t" {
                scalars.append(" ")
                continue
            }
            // A dropped control character must leave a gap, or it silently
            // welds the words on either side of it together.
            if scalar.value == 0x7F {
                scalars.append(" ")
                continue
            }
            if scalar.properties.generalCategory == .control {
                scalars.append(" ")
                continue
            }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(
                of: marker, with: "Sigil", options: .caseInsensitive)
    }

    private static func displayTitle(_ title: String, fallback: String) -> String {
        let cleaned = sanitize(title)
        return cleaned.isEmpty ? fallback : cleaned
    }
}

/// In-flight `ask_tab` questions. Every resume path (reply, timeout, target exit,
/// tab close) goes through one gate so the continuation runs exactly once.
@MainActor
public final class PendingAskRegistry: @unchecked Sendable {

    public enum Outcome: Equatable, Sendable {
        case answered(String)
        case timedOut
        case targetExited
        case tabClosed
        case cancelled
    }

    private struct Slot {
        let askingTabID: String
        let targetTabID: String
        let continuation: CheckedContinuation<Outcome, Never>
        let timeoutTask: Task<Void, Never>
    }

    private var slots: [String: Slot] = [:]
    /// How many times a timeout actually resumed a slot. Tests use this to prove
    /// the timeout task was cancelled after a reply, not merely ignored later.
    public private(set) var timeoutResumeCount = 0

    public init() {}

    public func isPending(_ id: String) -> Bool { slots[id] != nil }

    public func ask(
        id: String,
        askingTabID: String,
        targetTabID: String,
        timeout: Double
    ) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, slots[id] == nil else {
                    continuation.resume(returning: .tabClosed)
                    return
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    let seconds = max(timeout, 0)
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    self?.resumeTimeout(id)
                }
                slots[id] = Slot(
                    askingTabID: askingTabID,
                    targetTabID: targetTabID,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: { @Sendable [weak self, id] in
            Task { @MainActor [weak self, id] in
                self?.cancel(id: id)
            }
        }
    }

    /// Completes a pending ask only when the replying tab is its intended target.
    /// Returns false for a wrong responder, unknown id, or completed ask.
    @discardableResult
    public func reply(id: String, answer: String, respondingTabID: String) -> Bool {
        guard slots[id]?.targetTabID == respondingTabID else { return false }
        return resume(id, .answered(answer))
    }

    public func failTarget(tabID: String) {
        let ids = slots.compactMap { $0.value.targetTabID == tabID ? $0.key : nil }
        for id in ids { resume(id, .targetExited) }
    }

    public func clearTab(tabID: String) {
        let ids = slots.compactMap { entry in
            (entry.value.askingTabID == tabID || entry.value.targetTabID == tabID)
                ? entry.key : nil
        }
        for id in ids { resume(id, .tabClosed) }
    }

    /// Clears questions originated by a tab whose client or process went away.
    public func clearAskingTab(tabID: String) {
        let ids = slots.compactMap { $0.value.askingTabID == tabID ? $0.key : nil }
        for id in ids { resume(id, .tabClosed) }
    }

    public func clearAll() {
        for id in Array(slots.keys) { resume(id, .tabClosed) }
    }

    @discardableResult
    private func resume(_ id: String, _ outcome: Outcome) -> Bool {
        guard let slot = slots.removeValue(forKey: id) else { return false }
        slot.timeoutTask.cancel()
        slot.continuation.resume(returning: outcome)
        return true
    }

    private func resumeTimeout(_ id: String) {
        guard resume(id, .timedOut) else { return }
        timeoutResumeCount += 1
    }

    /// Cancels one pending ask, for example when delivery is declined.
    @discardableResult
    public func cancel(id: String) -> Bool {
        resume(id, .cancelled)
    }
}
