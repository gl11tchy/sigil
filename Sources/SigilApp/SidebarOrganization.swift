import Foundation
import SigilKit

/// Recents is a time-ordered thread list. Projects is that same list grouped by folder.
enum SidebarMode: String, CaseIterable, Identifiable, Sendable {
    case recents
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recents: return "Recents"
        case .projects: return "Projects"
        }
    }
}

/// One working folder and the conversations started in it, newest first.
struct SidebarProject: Identifiable, Equatable, Sendable {
    /// Canonical path of `cwd`.
    var id: String
    var name: String
    var displayPath: String
    var cwd: String
    var sessions: [GrokSession]
    var updatedAt: Date

    var count: Int { sessions.count }
}

/// Pure grouping for the sidebar. Path identity is injected so tests do not
/// need POSIX `realpath`.
enum SidebarOrganization {
    static func pinEntry(for session: GrokSession) -> OpenTabsSnapshot.Entry {
        OpenTabsSnapshot.Entry(sessionID: session.id, cwd: session.cwd)
    }

    static func containsPin(
        _ pins: [OpenTabsSnapshot.Entry],
        session: GrokSession,
        samePath: (String, String) -> Bool
    ) -> Bool {
        pins.contains { $0.sessionID == session.id && samePath($0.cwd, session.cwd) }
    }

    static func pinning(
        _ session: GrokSession,
        onto pins: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [OpenTabsSnapshot.Entry] {
        var next = unpinning(session, from: pins, samePath: samePath)
        next.insert(pinEntry(for: session), at: 0)
        return next
    }

    static func unpinning(
        _ session: GrokSession,
        from pins: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [OpenTabsSnapshot.Entry] {
        pins.filter { !($0.sessionID == session.id && samePath($0.cwd, session.cwd)) }
    }

    /// Pins that still exist, in pin order.
    static func matchingPins(
        sessions: [GrokSession],
        pins: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [GrokSession] {
        pins.compactMap { pin in
            sessions.first { $0.id == pin.sessionID && samePath($0.cwd, pin.cwd) }
        }
    }

    static func withoutPins(
        sessions: [GrokSession],
        pins: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [GrokSession] {
        sessions.filter { session in
            !containsPin(pins, session: session, samePath: samePath)
        }
    }

    /// Groups already-newest-first `sessions` by canonical working directory.
    /// Group order follows the newest session in each folder.
    static func projects(
        from sessions: [GrokSession],
        canonicalPath: (String) -> String
    ) -> [SidebarProject] {
        var order: [String] = []
        var grouped: [String: [GrokSession]] = [:]
        var representative: [String: GrokSession] = [:]
        for session in sessions {
            let key = canonicalPath(session.cwd)
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = [session]
                representative[key] = session
            } else {
                grouped[key]?.append(session)
            }
        }
        return order.map { key in
            let list = grouped[key] ?? []
            let sample = representative[key] ?? list[0]
            return SidebarProject(
                id: key,
                name: sample.projectName,
                displayPath: sample.displayPath,
                cwd: sample.cwd,
                sessions: list,
                updatedAt: list.first?.updatedAt ?? sample.updatedAt
            )
        }
    }
}
