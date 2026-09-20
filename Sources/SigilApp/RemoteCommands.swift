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
    var capabilities: [String] = ["restart"]
    var tabsTruncated = false
}

struct RemoteReply: Codable, Sendable {
    let challenge: String
    let sequence: Int
    var ok = true
    var error: String?
    var state: RemoteState?
    var ticket: String?
    var restartedTabID: String?
}

@MainActor
enum RemoteCommands {
    static var uploads = RemoteUpload.Inbox()

    static func execute(_ request: RemoteRequest, model: AppModel) -> RemoteReply {
        uploads.prune()
        var reply = RemoteReply(challenge: request.challenge, sequence: request.sequence)
        let tab = model.tabs.first { $0.id.uuidString == request.tabID }
        switch request.action {
        case "pair", "state": break
        case "select":
            guard let tab else { return failure(request, "This tab is closed.") }
            model.select(tab.id)
        case "new":
            guard model.settings.executableExists,
                model.newTab(in: model.newSessionDirectory) != nil
            else {
                return failure(request, "Could not start a session. Check Sigil on your Mac.")
            }
        case "restart":
            guard let tab, let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else {
                return failure(request, "This tab is closed.")
            }
            guard case .exited = tab.activity, !tab.controller.isRunning else {
                return failure(request, "Only ended sessions can be restarted.")
            }
            guard model.settings.executableExists,
                (try? tab.workingDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return failure(request, "Restore the folder or Grok CLI on your Mac, then try again.") }
            model.restartTab(id: tab.id)
            guard index < model.tabs.count, model.tabs[index].id != tab.id else {
                return failure(request, "Could not restart this session. Check Sigil on your Mac.")
            }
            reply.restartedTabID = model.tabs[index].id.uuidString
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
        case "file":
            guard let tab, tab.controller.isRunning else { return failure(request, "This session is not running.") }
            guard let transfer = request.transfer, let name = request.name, let index = request.index,
                let count = request.count, let text = request.text
            else { return failure(request, "That file could not be sent.") }
            do {
                if let url = try uploads.receive(
                    transfer: transfer, name: name, index: index, count: count, base64: text,
                    directory: TerminalDrop.cacheDirectory())
                {
                    let paste = TerminalDrop.pasteText(for: [url.path]) + " "
                    guard tab.controller.pasteRemoteText(paste) else {
                        return failure(request, "This prompt does not support file paste.")
                    }
                }
            } catch TerminalDrop.Error.tooLarge {
                return failure(request, "Keep files under 4 MB.")
            } catch {
                return failure(request, "That file could not be sent.")
            }
        default: return failure(request, "Unknown action.")
        }
        reply.state = snapshot(model)
        return reply
    }

    static func snapshot(_ model: AppModel) -> RemoteState {
        let tabs = model.tabs.map { tab in
            let status = tab.activity.statusName
            return RemoteState.Tab(
                id: tab.id.uuidString, title: bounded(model.title(for: tab), bytes: 96), status: status)
        }
        return RemoteState(
            tabs: visibleTabs(tabs, selectedID: model.selectedTab?.id.uuidString),
            selectedTabID: model.selectedTab?.id.uuidString,
            terminal: boundedSuffix(model.selectedTab?.controller.remoteSnapshot() ?? "", bytes: 12_000),
            tabsTruncated: tabs.count > 100
        )
    }

    static func visibleTabs(_ tabs: [RemoteState.Tab], selectedID: String?) -> [RemoteState.Tab] {
        var visible = Array(tabs.prefix(100))
        if let selectedID, !visible.contains(where: { $0.id == selectedID }),
            let selected = tabs.first(where: { $0.id == selectedID }), !visible.isEmpty
        {
            visible[visible.count - 1] = selected
        }
        return visible
    }

    static func bounded(_ text: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        var cut = Array(text.utf8.prefix(bytes))
        while String(bytes: cut, encoding: .utf8) == nil { cut.removeLast() }
        return String(bytes: cut, encoding: .utf8) ?? ""
    }

    static func boundedSuffix(_ text: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        var cut = Array(text.utf8.suffix(bytes))
        while String(bytes: cut, encoding: .utf8) == nil { cut.removeFirst() }
        return String(bytes: cut, encoding: .utf8) ?? ""
    }

    private static func failure(_ request: RemoteRequest, _ message: String) -> RemoteReply {
        RemoteReply(challenge: request.challenge, sequence: request.sequence, ok: false, error: message)
    }
}
