import Darwin
import Foundation
import os

/// True when `path` lives in a scratch location: temp dirs, agent worktrees,
/// and other folders that should not become the remembered default directory.
/// The sidebar hides these sessions unless the user turns them on.
public func isEphemeral(path: String) -> Bool {
    let identity = filesystemIdentity(path)
    if let cached = ephemeralPathCache.withLock({ $0[path] }),
        cached.device == identity.device,
        cached.inode == identity.inode,
        cached.modified == identity.modified
    {
        return cached.value
    }
    let value = computeIsEphemeral(path: path)
    ephemeralPathCache.withLock {
        $0[path] = EphemeralCacheEntry(
            value: value, device: identity.device, inode: identity.inode,
            modified: identity.modified)
    }
    return value
}

/// A sidebar freshness boundary also rechecks ancestor Git markers, whose
/// contents can change without modifying the chat directory itself.
public func invalidateEphemeralPathCache() {
    ephemeralPathCache.withLock { $0.removeAll(keepingCapacity: true) }
}

/// These lexical scratch markers remain ephemeral even if a symlink retargets.
/// Git classification is unnecessary for such paths; an ordinary alias into a
/// scratch folder still needs filesystem observation.
public func isEphemeralByPath(path: String) -> Bool {
    isTemporaryVariant(path) || hasScratchWorkspaceMarker(path)
}

private struct EphemeralCacheEntry {
    var value: Bool
    var device: UInt64?
    var inode: UInt64?
    var modified: Int?
}

private let ephemeralPathCache = OSAllocatedUnfairLock(
    initialState: [String: EphemeralCacheEntry]()
)

/// Follows symlinks so a retarget changes identity and misses the cache.
/// The modified time changes when `git worktree add` fills an existing folder.
private func filesystemIdentity(
    _ path: String
) -> (device: UInt64?, inode: UInt64?, modified: Int?) {
    var st = stat()
    guard stat(path, &st) == 0 else { return (nil, nil, nil) }
    let modified = st.st_mtimespec.tv_sec * 1_000_000_000 + st.st_mtimespec.tv_nsec
    return (UInt64(bitPattern: Int64(st.st_dev)), st.st_ino, modified)
}

private func computeIsEphemeral(path: String) -> Bool {
    let variants = pathVariants(path)
    if variants.contains(where: isTemporaryVariant) { return true }
    if variants.contains(where: hasScratchWorkspaceMarker) { return true }
    return isDeletedHomeFolder(path) || isLinkedGitWorktree(path)
}

/// A folder in the home folder that no longer exists, such as a removed
/// worktree. Folders elsewhere may sit on a volume that is only unmounted.
private func isDeletedHomeFolder(_ path: String) -> Bool {
    let home = GrokPaths.canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
    let folder = GrokPaths.canonicalPath(path)
    guard folder.hasPrefix(home + "/") else { return false }
    return !FileManager.default.fileExists(atPath: folder)
}

/// A checkout made by `git worktree add`, whatever tool made it: its `.git`
/// is a file that points into another repository's `worktrees` folder.
/// Sigil's own worktrees are left alone; they group under their project.
private func isLinkedGitWorktree(_ path: String) -> Bool {
    if SigilWorktree.projectPath(of: path) != nil { return false }
    var folder = URL(fileURLWithPath: GrokPaths.canonicalPath(path))
    while folder.path != "/" {
        let git = folder.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
            // A `.git` folder is a main checkout. A `.git` file that is not a
            // worktree (a submodule) may still sit inside one, so keep going.
            if isDirectory.boolValue { return false }
            if isWorktreeGitFile(git, in: folder) { return true }
        }
        folder.deleteLastPathComponent()
    }
    return false
}

/// True when `.git` points at `<common git dir>/worktrees/<id>`. Git writes a
/// `commondir` file only there, so a `--separate-git-dir` checkout that
/// happens to live in a folder named `worktrees` does not match.
private func isWorktreeGitFile(_ git: URL, in folder: URL) -> Bool {
    guard let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") else {
        return false
    }
    let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    let admin = URL(fileURLWithPath: target, relativeTo: folder).standardizedFileURL
    return admin.deletingLastPathComponent().lastPathComponent == "worktrees"
        && FileManager.default.fileExists(atPath: admin.appendingPathComponent("commondir").path)
}

private func isTemporaryVariant(_ path: String) -> Bool {
    temporaryPrefixes.contains { prefix in
        path == prefix || path.hasPrefix(prefix + "/")
    }
}

private let temporaryPrefixes: [String] = {
    var prefixes: Set<String> = ["/tmp", "/private/tmp", "/private/var/folders", "/var/folders"]
    prefixes.formUnion(pathVariants(FileManager.default.temporaryDirectory.path))
    return Array(prefixes)
}()

/// Folder names that always mean an agent worktree or scratch checkout.
private let scratchComponents: Set<String> = [
    ".worktrees", "scratchpad", "scratchpads", ".t3", ".codex",
]

/// Direct children of a dot-dir that hold implementer worktrees, not real projects.
private let scratchChildrenByRoot: [String: Set<String>] = [
    ".claude": ["worktrees", "projects", "scratch", "scratchpads", "tmp"],
    ".bb": ["worktrees", "thread-storage", "personal-workspaces"],
    ".cache": ["quick-grok"],
]

/// bb environment plugins whose host data holds per-thread checkouts.
private let scratchPlugins: Set<String> = [
    "environment-git-worktree", "environment-personal-workspace",
]

private func hasScratchWorkspaceMarker(_ path: String) -> Bool {
    let parts = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" && $0 != "." }
    if parts.contains(where: { scratchComponents.contains($0) }) {
        return true
    }
    // Check every occurrence: a worktree can sit under an earlier dot-dir.
    if zip(parts, parts.dropFirst()).contains(where: { scratchChildrenByRoot[$0]?.contains($1) == true }) {
        return true
    }
    let pluginChains = scratchPlugins.map { [".bb", "plugins", $0] }
    return parts.indices.contains { index in
        pluginChains.contains { parts[index...].starts(with: $0) }
    }
}

/// macOS presents the same directory as both `/tmp` and `/private/tmp` (and
/// `/var/folders` vs `/private/var/folders`). Compare every spelling so a
/// path that exists and one that does not still classify the same way.
private func pathVariants(_ path: String) -> [String] {
    let url = URL(fileURLWithPath: path)
    var result: Set<String> = []
    for raw in [path, url.path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path] {
        let trimmed = (raw.count > 1 && raw.hasSuffix("/")) ? String(raw.dropLast()) : raw
        result.insert(trimmed)
        if trimmed.hasPrefix("/private/") {
            result.insert(String(trimmed.dropFirst("/private".count)))
        } else if trimmed.hasPrefix("/") {
            result.insert("/private" + trimmed)
        }
    }
    return Array(result)
}
