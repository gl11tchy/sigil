import Foundation
import SigilKit

struct RemoteState: Codable, Sendable {
    struct Tab: Codable, Sendable {
        let id: String
        let title: String
        let status: String
    }
    let tabs: [Tab]
    let selectedTabID: String?
    let terminal: String
}

struct RemoteReply: Codable, Sendable {
    let challenge: String
    let sequence: Int
    var ok = true
    var error: String?
    var state: RemoteState?
}

@MainActor
enum RemoteCommands {
    static func execute(_ request: RemoteRequest, model: AppModel) -> RemoteReply {
        var reply = RemoteReply(challenge: request.challenge, sequence: request.sequence)
        let tab = model.tabs.first { $0.id.uuidString == request.tabID }
        switch request.action {
        case "pair", "state": break
        case "select":
            guard let tab else { return failure(request, "This tab is closed.") }
            model.select(tab.id)
        case "new":
            guard model.settings.executableExists,
                model.newTab(in: model.currentDirectory) != nil
            else {
                return failure(request, "Could not start a session. Check Sigil on your Mac.")
            }
        case "input":
            guard let tab, tab.controller.isRunning else { return failure(request, "This session is not running.") }
            guard let text = request.text, !text.isEmpty, text.utf8.count <= 8_192,
                text.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
                })
            else { return failure(request, "Enter plain text, up to 8 KB.") }
            guard tab.controller.pasteRemoteText(text) else {
                return failure(request, "This prompt does not support multiline paste.")
            }
        case "key":
            guard let tab, tab.controller.isRunning else { return failure(request, "This session is not running.") }
            guard let key = request.text, tab.controller.sendRemoteKey(key) else {
                return failure(request, "Unknown key.")
            }
        default: return failure(request, "Unknown action.")
        }
        reply.state = snapshot(model)
        return reply
    }

    static func snapshot(_ model: AppModel) -> RemoteState {
        RemoteState(
            tabs: model.tabs.prefix(100).map { tab in
                let status: String
                switch tab.activity {
                case .starting: status = "starting"
                case .working: status = "working"
                case .idle: status = "idle"
                case .exited: status = "exited"
                }
                return RemoteState.Tab(
                    id: tab.id.uuidString, title: bounded(model.title(for: tab), bytes: 96), status: status)
            },
            selectedTabID: model.selectedTab?.id.uuidString,
            terminal: String(
                decoding: (model.selectedTab?.controller.remoteSnapshot() ?? "").utf8.suffix(12_000), as: UTF8.self)
        )
    }

    private static func bounded(_ text: String, bytes: Int) -> String {
        String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
    }

    private static func failure(_ request: RemoteRequest, _ message: String) -> RemoteReply {
        RemoteReply(challenge: request.challenge, sequence: request.sequence, ok: false, error: message)
    }
}
