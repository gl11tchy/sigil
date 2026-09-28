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
        cached.inode == identity.inode
    {
        return cached.value
    }
    let value = computeIsEphemeral(path: path)
    ephemeralPathCache.withLock {
        $0[path] = EphemeralCacheEntry(
            value: value, device: identity.device, inode: identity.inode)
    }
    return value
}

private struct EphemeralCacheEntry {
    var value: Bool
    var device: UInt64?
    var inode: UInt64?
}

private let ephemeralPathCache = OSAllocatedUnfairLock(
    initialState: [String: EphemeralCacheEntry]()
)

/// Follows symlinks so a retarget changes identity and misses the cache.
private func filesystemIdentity(_ path: String) -> (device: UInt64?, inode: UInt64?) {
    var st = stat()
    guard stat(path, &st) == 0 else { return (nil, nil) }
    return (UInt64(bitPattern: Int64(st.st_dev)), st.st_ino)
}

private func computeIsEphemeral(path: String) -> Bool {
    let variants = pathVariants(path)
    if variants.contains(where: isTemporaryVariant) { return true }
    return variants.contains(where: hasScratchWorkspaceMarker)
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
