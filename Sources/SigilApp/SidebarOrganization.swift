import Foundation
import SigilKit

/// Recents is a time-ordered thread list. Projects is a folder list you open.
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

/// Which list the sidebar is showing. Home is always the folder list.
enum SidebarSurface: Equatable, Sendable {
    case folders
    case recents
    case archived
    case project
}

/// What the sidebar list is showing.
enum SidebarListKind: Equatable, Sendable {
    /// Time buckets of chats.
    case recents
    /// Working folders; click one to open it.
    case projectList
    /// Chats in the open folder.
    case projectChats
    /// Search hits grouped by folder.
    case projectSearch
    /// Archived chats, grouped by folder.
    case archived
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
    static let recentsID = "sigil:recents"
    static let archivedID = "sigil:archived"

    static func surface(focusedPath: String) -> SidebarSurface {
        if focusedPath == recentsID { return .recents }
        if focusedPath == archivedID { return .archived }
        if focusedPath.isEmpty { return .folders }
        return .project
    }

    static func listKind(surface: SidebarSurface, isSearching: Bool) -> SidebarListKind {
        switch surface {
        case .recents: return .recents
        case .archived: return .archived
        case .project: return .projectChats
        case .folders: return isSearching ? .projectSearch : .projectList
        }
    }

    static func folderListRowIDs(
        recentsCount: Int,
        archivedCount: Int,
        pinnedIDs: [String],
        restIDs: [String]
    ) -> [String] {
        var ids: [String] = []
        if recentsCount > 0 { ids.append(recentsID) }
        ids.append(contentsOf: pinnedIDs)
        ids.append(contentsOf: restIDs)
        if archivedCount > 0 { ids.append(archivedID) }
        return ids
    }

    static func activationKey(preferred: String?, in keys: [String]) -> String? {
        if let preferred, keys.contains(preferred) { return preferred }
        return keys.first
    }

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
        var nameCounts: [String: Int] = [:]
        for session in representative.values {
            nameCounts[session.projectName, default: 0] += 1
        }
        let duplicated = Set(nameCounts.filter { $0.value > 1 }.keys)
        return order.map { key in
            let list = grouped[key] ?? []
            let sample = representative[key] ?? list[0]
            return SidebarProject(
                id: key,
                name: duplicated.contains(sample.projectName)
                    ? sample.displayPath : sample.projectName,
                displayPath: sample.displayPath,
                cwd: sample.cwd,
                sessions: list,
                updatedAt: list.first?.updatedAt ?? sample.updatedAt
            )
        }
    }

    /// O(n) index so a row can find its project without walking every folder.
    static func indexByDirectory(_ projects: [SidebarProject]) -> [URL: SidebarProject] {
        var index: [URL: SidebarProject] = [:]
        index.reserveCapacity(projects.reduce(0) { $0 + $1.sessions.count })
        for project in projects {
            for session in project.sessions {
                index[session.directory] = project
            }
        }
        return index
    }

    /// Sessions from `project` that are also in `sessions`, in project order.
    static func listedRows(in project: SidebarProject, from sessions: [GrokSession]) -> [GrokSession] {
        let listed = Set(sessions.map(\.directory))
        return project.sessions.filter { listed.contains($0.directory) }
    }

    /// Unique name and path spellings for search paint, sample first, then each row.
    /// A canonical group can still list `/var/…` and `/private/var/…` together.
    static func pathHaystacks(
        name: String,
        displayPath: String,
        cwd: String,
        sessions: [GrokSession]
    ) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        func add(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            ordered.append(value)
        }
        add(name)
        add(displayPath)
        add(cwd)
        for session in sessions {
            add(session.projectName)
            add(session.displayPath)
            add(session.cwd)
        }
        return ordered
    }
}
