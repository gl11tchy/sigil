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
/// need POSIX `realpath`. Pins and archives share the same identity list.
enum SidebarOrganization {
    static func entry(for session: GrokSession) -> OpenTabsSnapshot.Entry {
        OpenTabsSnapshot.Entry(sessionID: session.id, cwd: session.cwd)
    }

    static func contains(
        _ entries: [OpenTabsSnapshot.Entry],
        session: GrokSession,
        samePath: (String, String) -> Bool
    ) -> Bool {
        entries.contains { $0.sessionID == session.id && samePath($0.cwd, session.cwd) }
    }

    static func inserting(
        _ session: GrokSession,
        onto entries: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [OpenTabsSnapshot.Entry] {
        var next = removing(session, from: entries, samePath: samePath)
        next.insert(entry(for: session), at: 0)
        return next
    }

    static func removing(
        _ session: GrokSession,
        from entries: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [OpenTabsSnapshot.Entry] {
        entries.filter { !($0.sessionID == session.id && samePath($0.cwd, session.cwd)) }
    }

    /// Entries that still exist, in stored order.
    static func matching(
        sessions: [GrokSession],
        entries: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [GrokSession] {
        entries.compactMap { entry in
            sessions.first { $0.id == entry.sessionID && samePath($0.cwd, entry.cwd) }
        }
    }

    static func without(
        sessions: [GrokSession],
        entries: [OpenTabsSnapshot.Entry],
        samePath: (String, String) -> Bool
    ) -> [GrokSession] {
        sessions.filter { session in
            !contains(entries, session: session, samePath: samePath)
        }
    }

    static func contains(
        _ paths: [String],
        path: String,
        samePath: (String, String) -> Bool
    ) -> Bool {
        paths.contains { samePath($0, path) }
    }

    static func inserting(
        _ path: String,
        onto paths: [String],
        samePath: (String, String) -> Bool
    ) -> [String] {
        var next = removing(path, from: paths, samePath: samePath)
        next.insert(path, at: 0)
        return next
    }

    static func removing(
        _ path: String,
        from paths: [String],
        samePath: (String, String) -> Bool
    ) -> [String] {
        paths.filter { !samePath($0, path) }
    }

    /// Projects that still exist, in stored pin order.
    static func matching(
        projects: [SidebarProject],
        paths: [String],
        samePath: (String, String) -> Bool
    ) -> [SidebarProject] {
        paths.compactMap { path in
            projects.first { samePath($0.cwd, path) }
        }
    }

    static func without(
        projects: [SidebarProject],
        paths: [String],
        samePath: (String, String) -> Bool
    ) -> [SidebarProject] {
        projects.filter { project in
            !contains(paths, path: project.cwd, samePath: samePath)
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
