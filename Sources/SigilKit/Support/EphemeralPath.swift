import Foundation

/// True when `path` lives in a scratch location that should not become the
/// remembered default directory. Quick-grok worktrees land in these folders.
public func isEphemeral(path: String) -> Bool {
    let variants = pathVariants(path)
    var prefixes = ["/tmp", "/private/tmp", "/private/var/folders", "/var/folders"]
    prefixes.append(contentsOf: pathVariants(FileManager.default.temporaryDirectory.path))
    return variants.contains { candidate in
        prefixes.contains { prefix in
            candidate == prefix || candidate.hasPrefix(prefix + "/")
        }
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
