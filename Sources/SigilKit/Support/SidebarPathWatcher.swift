import Foundation

/// One passive stream for the visible sidebar. Ordinary source-file changes
/// do not invalidate its snapshot; folder identity, aliases and Git markers do.
public final class SidebarPathWatcher: Sendable {
    public enum Coverage: Equatable, Sendable {
        case complete, partial, unavailable
    }
    private let watcher = SessionDirectoryWatcher()

    public init() {}

    @discardableResult
    public func start(paths: [String], changed: @escaping @Sendable () -> Void) -> Coverage {
        let plan = Self.plan(paths: paths)
        let started = watcher.start(
            paths: plan.roots, latency: 0.25, contents: .sidebarPaths(plan.identities)
        ) { _ in changed() }
        guard started else { return .unavailable }
        let allRootsAvailable = plan.roots.allSatisfy { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return plan.needsFallback || !allRootsAvailable ? .partial : .complete
    }

    public func stop() { watcher.stop() }

    /// Observe missing roots through an existing ancestor without deleting any
    /// saved reference. Watch alias parents so retargeting a symlink is visible.
    static func plan(paths: [String]) -> (roots: [String], identities: Set<String>, needsFallback: Bool) {
        var roots: Set<String> = []
        var identities: Set<String> = []
        var examined: Set<String> = []
        var needsFallback = false
        for path in Set(paths) {
            // Foundation's standardizedFileURL may resolve an existing alias
            // when a descendant is missing. Preserve the alias spelling too.
            let lexical = URL(fileURLWithPath: path)
            for spelling in Set([lexical, SessionDirectoryWatcher.canonicalURL(lexical)]) {
                var folder = spelling
                var existingParent = spelling.deletingLastPathComponent()
                while !FileManager.default.fileExists(atPath: existingParent.path), existingParent.path != "/" {
                    existingParent.deleteLastPathComponent()
                }
                if existingParent.path != "/" { roots.insert(existingParent.path) } else { needsFallback = true }
                while folder.path != "/" {
                    guard examined.insert(folder.path).inserted else { break }
                    identities.insert(folder.path)
                    identities.insert(folder.appendingPathComponent(".git").path)
                    let parent = folder.deletingLastPathComponent()
                    if parent.path != "/",
                        (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) != nil
                    {
                        roots.insert(parent.path)
                    }
                    let git = folder.appendingPathComponent(".git")
                    if FileManager.default.fileExists(atPath: git.path) {
                        roots.insert(folder.path)
                        // Worktree classification also depends on this one
                        // admin marker; ordinary Git index writes stay ignored.
                        if let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") {
                            let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                            let admin = URL(fileURLWithPath: target, relativeTo: folder).standardizedFileURL
                            if admin.deletingLastPathComponent().lastPathComponent == "worktrees" {
                                let marker = SessionDirectoryWatcher.canonicalURL(
                                    admin.appendingPathComponent("commondir"))
                                identities.insert(marker.path)
                                var parent = admin.deletingLastPathComponent()
                                while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
                                    parent.deleteLastPathComponent()
                                }
                                if parent.path != "/" { roots.insert(parent.path) } else { needsFallback = true }
                            }
                        }
                    }
                    folder = parent
                }
            }
        }
        return (roots.sorted(), identities, needsFallback)
    }
}
