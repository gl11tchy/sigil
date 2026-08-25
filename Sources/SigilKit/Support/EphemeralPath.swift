import Foundation

/// True when `path` lives in a scratch location: temp dirs, agent worktrees,
/// and other folders that should not become the remembered default directory.
/// The sidebar hides these sessions unless the user turns them on.
public func isEphemeral(path: String) -> Bool {
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

/// Direct children of `.claude` that hold implementer worktrees, not real projects.
private let claudeScratchChildren: Set<String> = [
    "worktrees", "projects", "scratch", "scratchpads", "tmp",
]

private func hasScratchWorkspaceMarker(_ path: String) -> Bool {
    let parts = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" && $0 != "." }
    if parts.contains(where: { scratchComponents.contains($0) }) {
        return true
    }
    if let index = parts.firstIndex(of: ".claude") {
        let next = parts.index(after: index)
        if next < parts.endIndex, claudeScratchChildren.contains(parts[next]) {
            return true
        }
    }
    if let index = parts.firstIndex(of: ".cache") {
        let next = parts.index(after: index)
        if next < parts.endIndex, parts[next] == "quick-grok" {
            return true
        }
    }
    return false
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
