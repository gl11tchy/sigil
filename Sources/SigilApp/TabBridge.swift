import Foundation
import SigilKit

/// App-side broker: answers `BridgeServer` requests and writes into a tab's pty.
@MainActor
final class TabBridge: BridgeServerDelegate {

    private weak var model: AppModel?
    private let server: BridgeServer
    let asks = PendingAskRegistry()

    init(model: AppModel, socketURL: URL = BridgePaths.configuredSocket) {
        self.model = model
        self.server = BridgeServer(socketURL: socketURL)
        self.server.delegate = self
    }

    var isListening: Bool { server.isListening }
    var socketURL: URL { server.socketURL }

    func start() throws {
        try server.start()
    }

    func stop() {
        asks.clearAll()
        server.stop()
    }

    func noteTabExited(id: TerminalTab.ID) {
        asks.failTarget(tabID: id.uuidString)
        asks.clearAskingTab(tabID: id.uuidString)
    }

    func noteTabClosed(id: TerminalTab.ID) {
        asks.clearTab(tabID: id.uuidString)
    }

    // MARK: - BridgeServerDelegate

    func bridgeListTabs(asking peer: BridgePeer) -> [BridgeTab] {
        let refs = snapshots()
        let callerID: String?
        if case .found(let caller) = BridgeRouting.matchPeer(peer, tabs: refs) {
            callerID = caller.tabID
        } else {
            callerID = nil
        }
        return refs.map { ref in
            BridgeTab(
                tabID: ref.tabID,
                title: ref.title,
                directory: ref.directory,
                status: ref.status,
                isSelf: ref.tabID == callerID
            )
        }
    }

    func bridgeSend(from peer: BridgePeer, to target: String, message: String) -> BridgeResponse {
        switch resolveDelivery(from: peer, to: target) {
        case .failure(let response):
            return response
        case .success(let caller, let dest, let tab):
            let prompt = BridgePrompt.send(
                fromTitle: caller.title, fromTabID: caller.tabID, message: message)
            return deliver(prompt, to: tab, dest: dest)
        }
    }

    func bridgeAsk(
        from peer: BridgePeer, to target: String, question: String, timeout: Double
    ) async -> BridgeResponse {
        switch resolveDelivery(from: peer, to: target) {
        case .failure(let response):
            return response
        case .success(let caller, let dest, let tab):
            let requestID = UUID().uuidString
            let prompt = BridgePrompt.ask(
                fromTitle: caller.title,
                fromTabID: caller.tabID,
                requestID: requestID,
                question: question
            )
            let delivered = deliver(prompt, to: tab, dest: dest, requestID: requestID)
            guard delivered.ok else { return delivered }

            let outcome = await asks.ask(
                id: requestID,
                askingTabID: caller.tabID,
                targetTabID: dest.tabID,
                timeout: timeout
            )
            // A reply consumes the item through the UI. Timeout, cancellation,
            // or either tab exiting must also remove the now-stale question.
            tab.removeBridgePrompt(requestID: requestID)
            switch outcome {
            case .answered(let answer):
                return BridgeResponse(
                    ok: true, answer: answer, requestID: requestID, note: "answered by \(dest.title)"
                )
            case .timedOut:
                return .failure(
                    "the other tab did not answer within \(formatSeconds(timeout)) seconds")
            case .targetExited:
                return .failure(
                    "tab \"\(dest.title)\" (\(dest.tabID)) exited before answering")
            case .tabClosed:
                return .failure("a tab closed before the question was answered")
            case .cancelled:
                return .failure("the question was dismissed before it was answered")
            }
        }
    }

    func bridgeReply(from peer: BridgePeer, requestID: String, answer: String) -> BridgeResponse {
        let refs = snapshots()
        guard case .found(let caller) = BridgeRouting.matchPeer(peer, tabs: refs) else {
            return .failure("could not match this client to an open tab")
        }
        guard
            asks.reply(
                id: requestID,
                answer: answer,
                respondingTabID: caller.tabID
            )
        else {
            return .failure(
                "this request is unknown, already answered, or belongs to another tab")
        }
        return BridgeResponse(ok: true, note: "accepted")
    }

    // MARK: - Routing + delivery

    private enum Delivery {
        case success(caller: BridgeTabRef, dest: BridgeTabRef, tab: TerminalTab)
        case failure(BridgeResponse)
    }

    private func resolveDelivery(from peer: BridgePeer, to target: String) -> Delivery {
        let refs = snapshots()
        guard case .found(let caller) = BridgeRouting.matchPeer(peer, tabs: refs) else {
            return .failure(.failure("could not match this client to an open tab"))
        }
        switch BridgeRouting.matchTarget(target, callerID: caller.tabID, tabs: refs) {
        case .notFound:
            return .failure(
                .failure(
                    "no open tab matches \"\(target)\". Call list_tabs and retry with a tab id."))
        case .selfTarget:
            return .failure(.failure("that target is this tab; pick a different tab"))
        case .ambiguous(let matches):
            let listed = matches.map { "\($0.tabID) (\($0.title))" }.joined(separator: ", ")
            return .failure(
                .failure(
                    "several tabs are named \"\(target)\": \(listed). Retry with a tab id."))
        case .found(let dest):
            guard let tab = tab(id: dest.tabID) else {
                return .failure(
                    .failure(
                        "no open tab matches \"\(target)\". Call list_tabs and retry with a tab id.")
                )
            }
            if case .exited = tab.activity {
                let title = model?.title(for: tab) ?? dest.title
                return .failure(
                    .failure("tab \"\(title)\" (\(tab.id.uuidString)) is not running"))
            }
            return .success(caller: caller, dest: dest, tab: tab)
        }
    }

    private func deliver(
        _ prompt: String,
        to tab: TerminalTab,
        dest: BridgeTabRef,
        requestID: String? = nil
    ) -> BridgeResponse {
        if case .exited = tab.activity {
            let title = model?.title(for: tab) ?? dest.title
            return .failure("tab \"\(title)\" (\(tab.id.uuidString)) is not running")
        }
        // Never inject unsolicited keystrokes. The tab shows a small inbox and
        // the user chooses when to submit the prompt.
        guard !prompt.isEmpty else { return .failure("message is empty") }
        tab.enqueueBridgePrompt(
            prompt,
            requestID: requestID,
            onDismiss: requestID.map { id in
                { [weak self] in self?.asks.cancel(id: id) }
            }
        )
        return BridgeResponse(ok: true, note: "queued for \(dest.title)")
    }

    private func snapshots() -> [BridgeTabRef] {
        guard let model else { return [] }
        return model.tabs.map { tab in
            BridgeTabRef(
                tabID: tab.id.uuidString,
                sessionID: tab.sessionID,
                title: model.title(for: tab),
                directory: tab.workingDirectory.path,
                status: status(of: tab),
                isRunning: tab.isRunning
            )
        }
    }

    private func tab(id: String) -> TerminalTab? {
        model?.tabs.first { $0.id.uuidString == id }
    }

    private func status(of tab: TerminalTab) -> String {
        switch tab.activity {
        case .working: return "working"
        case .exited: return "exited"
        case .idle, .starting: return "idle"
        }
    }

    private func formatSeconds(_ timeout: Double) -> String {
        timeout.rounded() == timeout ? String(Int(timeout)) : String(timeout)
    }
}
