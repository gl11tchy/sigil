import Darwin
import Foundation

/// Locations and name encodings used by the Grok Build CLI's on-disk state.
///
/// The CLI keeps every conversation under `~/.grok/sessions/<encoded-cwd>/<session-uuid>/`.
/// The directory name is the session's working directory, percent-encoded with the
/// RFC 3986 *unreserved* set left intact (`A-Z a-z 0-9 - . _ ~`); everything else,
/// including `/` and `+`, becomes `%XX`. Verified against grok 1.0.4 on 2026-08-17.
/// A name over 255 bytes is hashed instead; see `sessionFolderName(forCanonicalPath:)`.
public enum GrokPaths {

    /// Characters the CLI leaves untouched when encoding a working directory.
    public static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "A"..."Z")
        set.insert(charactersIn: "a"..."z")
        set.insert(charactersIn: "0"..."9")
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// `~/.grok`, honouring a `GROK_HOME` override when one is set.
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["GROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    /// `~/.grok/sessions` — one subdirectory per working directory.
    public static var sessionsRoot: URL { home.appendingPathComponent("sessions") }

    /// The CLI the app starts by default.
    ///
    /// `bin/grok-sigil` wins when it is there: it is the app's own build of the
    /// open-source CLI, which carries the `sigil-neon` TUI theme and honours
    /// `GROK_THEME`. Without it the app falls back to the installer's `bin/grok`,
    /// which runs exactly as before and ignores the theme variable.
    public static var defaultExecutable: URL {
        if FileManager.default.isExecutableFile(atPath: themedExecutable.path) {
            return themedExecutable
        }
        return installerExecutable
    }

    /// The app's own build of the CLI, which carries the `sigil-neon` theme.
    public static var themedExecutable: URL {
        home.appendingPathComponent("bin/grok-sigil")
    }

    /// The binary the Grok installer puts on disk.
    public static var installerExecutable: URL {
        home.appendingPathComponent("bin/grok")
    }

    /// Encodes an absolute path the way the CLI names its per-directory session folder.
    public static func encode(path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
    }

    /// Reverses `encode(path:)`. Returns `nil` for names that are not valid encodings.
    public static func decode(directoryName: String) -> String? {
        directoryName.removingPercentEncoding
    }

    /// The per-directory folder name the CLI uses (`encode_cwd_dirname` in
    /// xai-grok-config/src/paths.rs). A percent-encoded name over 255 bytes
    /// cannot exist on disk, so the CLI switches to `<slug of leaf>-<BLAKE3 hex16>`.
    public static func sessionFolderName(forCanonicalPath path: String) -> String {
        let encoded = encode(path: path)
        if encoded.utf8.count <= 255 { return encoded }
        let hash = BLAKE3.hexDigest(Array(path.utf8)).prefix(16)
        let components = path.split(separator: "/").filter { $0 != "." }
        let leaf = components.last.flatMap { $0 == ".." ? nil : String($0) } ?? "workspace"
        let slug = slugify(leaf, maximumLength: 40)
        return "\(slug.isEmpty ? "workspace" : slug)-\(hash)"
    }

    /// The CLI's `slugify`: lowercase, keep ASCII letters and digits, collapse
    /// every other run to one `-`, trim dashes, then cut to `maximumLength`.
    static func slugify(_ input: String, maximumLength: Int) -> String {
        var result = ""
        var previousDash = false
        for scalar in input.lowercased().unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousDash = false
            } else if !previousDash {
                result.append("-")
                previousDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(maximumLength))
    }

    /// The directory holding one session's transcript and metadata.
    ///
    /// `cwd` is resolved through `realpath` first, because the CLI records the
    /// resolved path (`/tmp/x` is stored as `/private/tmp/x`).
    public static func sessionDirectory(cwd: String, sessionID: String) -> URL {
        let resolved = canonicalPath(cwd)
        return
            sessionsRoot
            .appendingPathComponent(sessionFolderName(forCanonicalPath: resolved))
            .appendingPathComponent(sessionID)
    }

    /// Resolves a path through the same POSIX `realpath` behavior the CLI uses.
    /// Foundation does not resolve macOS firmlinks such as `/var` to `/private/var`.
    public static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.withCString { pointer in
            guard let resolved = Darwin.realpath(pointer, nil) else {
                return URL(fileURLWithPath: expanded).standardizedFileURL.path
            }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
    }
}
