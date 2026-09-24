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
    /// Ranked hits from every folder, including archived chats.
    case search
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

/// A folder added to Projects before it has a Grok chat: by the Projects
/// header's add button, or by starting another provider's CLI there.
struct AddedProject: Codable, Equatable, Sendable {
    var path: String
    var addedAt: Date
}

/// Pure grouping for the sidebar. Path identity is injected so tests do not
/// need POSIX `realpath`. Pins and archives share the same identity list.
enum SidebarOrganization {
    static let recentsID = "sigil:recents"
    static let archivedID = "sigil:archived"

    static func isSentinel(_ path: String) -> Bool {
        path == recentsID || path == archivedID
    }

    static func surface(focusedPath: String) -> SidebarSurface {
        if focusedPath == recentsID { return .recents }
        if focusedPath == archivedID { return .archived }
        if focusedPath.isEmpty { return .folders }
        return .project
    }

    /// Whitespace is not a query. Empty lists stay on the open folder.
    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func listKind(surface: SidebarSurface, isSearching: Bool) -> SidebarListKind {
        if isSearching { return .search }
        switch surface {
        case .recents: return .recents
        case .archived: return .archived
        case .project: return .projectChats
        case .folders: return .projectList
        }
    }

    /// Escape never clears the search query.
    enum EscapeAction: Equatable, Sendable {
        case cancelRename
        case leaveFolder
        case leaveList
    }

    static func escapeAction(isRenaming: Bool, surface: SidebarSurface) -> EscapeAction {
        if isRenaming { return .cancelRename }
        if surface != .folders { return .leaveFolder }
        return .leaveList
    }

    /// A non-empty query selects the top ranked row. An empty query leaves
    /// the current highlight alone.
    enum SearchSelection: Equatable, Sendable {
        case keep
        case row(String?)
    }

    static func selectionAfterQueryChange(query: String, topRowID: String?) -> SearchSelection {
        guard isSearching(query) else { return .keep }
        return .row(topRowID)
    }

    static func folderListRowIDs(pinnedIDs: [String], restIDs: [String]) -> [String] {
        pinnedIDs + restIDs
    }

    /// The inclusive anchor…target slice of `rowIDs`, for a ⇧-click or ⇧-arrow
    /// range. A missing end selects the target alone.
    static func selectionRange(from anchor: String, to target: String, in rowIDs: [String]) -> Set<String> {
        guard let a = rowIDs.firstIndex(of: anchor), let b = rowIDs.firstIndex(of: target)
        else { return [target] }
        return Set(rowIDs[min(a, b)...max(a, b)])
    }

    /// Recents and Archived are destinations, not folders.
    static func destinationRowIDs(recentsCount: Int, archivedCount: Int) -> [String] {
        var ids: [String] = []
        if recentsCount > 0 { ids.append(recentsID) }
        if archivedCount > 0 { ids.append(archivedID) }
        return ids
    }

    static func homeRowIDs(
        recentsCount: Int,
        archivedCount: Int,
        pinnedIDs: [String],
        restIDs: [String],
        openTabIDs: [String] = []
    ) -> [String] {
        // Recents and Archived are nav items above the lists, so the arrow
        // keys meet them first, in the order they are drawn.
        destinationRowIDs(recentsCount: recentsCount, archivedCount: archivedCount)
            + openTabIDs
            + folderListRowIDs(pinnedIDs: pinnedIDs, restIDs: restIDs)
    }

    /// Home lists every open tab above the folders, so the sessions in flight
    /// are one click away without opening a folder or reading the tab strip.
    static let openTabPrefix = "sigil:tab:"

    static func openTabRowID(_ id: UUID) -> String {
        openTabPrefix + id.uuidString
    }

    static func openTabID(fromRowID rowID: String) -> UUID? {
        guard rowID.hasPrefix(openTabPrefix) else { return nil }
        return UUID(uuidString: String(rowID.dropFirst(openTabPrefix.count)))
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
            let key = canonicalPath(session.projectPath)
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
                    ? sample.projectDisplayPath : sample.projectName,
                displayPath: sample.projectDisplayPath,
                cwd: sample.projectPath,
                sessions: list,
                updatedAt: list.first?.updatedAt ?? sample.updatedAt
            )
        }
    }

    /// Adds folders from `added` that have no project yet as empty projects,
    /// and lets a newer add date lift a folder that has one. Newest first.
    static func merging(
        added: [AddedProject],
        into projects: [SidebarProject],
        canonicalPath: (String) -> String
    ) -> [SidebarProject] {
        var result = projects
        for entry in added {
            let key = canonicalPath(entry.path)
            if let index = result.firstIndex(where: { $0.id == key }) {
                result[index].updatedAt = max(result[index].updatedAt, entry.addedAt)
                continue
            }
            let name = URL(fileURLWithPath: entry.path).lastPathComponent
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var displayPath = entry.path
            if entry.path == home {
                displayPath = "~"
            } else if entry.path.hasPrefix(home + "/") {
                displayPath = "~" + entry.path.dropFirst(home.count)
            }
            let taken = result.contains { $0.name == name }
            result.append(
                SidebarProject(
                    id: key,
                    name: name.isEmpty || taken ? displayPath : name,
                    displayPath: displayPath,
                    cwd: entry.path,
                    sessions: [],
                    updatedAt: entry.addedAt
                ))
        }
        return result.enumerated()
            .sorted { lhs, rhs in
                lhs.element.updatedAt != rhs.element.updatedAt
                    ? lhs.element.updatedAt > rhs.element.updatedAt
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
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
            add(session.projectDisplayPath)
            add(session.cwd)
        }
        return ordered
    }
}
