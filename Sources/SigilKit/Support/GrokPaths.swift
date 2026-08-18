import Foundation

/// Locations and name encodings used by the Grok Build CLI's on-disk state.
///
/// The CLI keeps every conversation under `~/.grok/sessions/<encoded-cwd>/<session-uuid>/`.
/// The directory name is the session's working directory, percent-encoded with the
/// RFC 3986 *unreserved* set left intact (`A-Z a-z 0-9 - . _ ~`); everything else,
/// including `/` and `+`, becomes `%XX`. Verified against grok 1.0.4 on 2026-08-17.
public enum GrokPaths {

    /// Characters the CLI leaves untouched when encoding a working directory.
    public static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "A" ... "Z")
        set.insert(charactersIn: "a" ... "z")
        set.insert(charactersIn: "0" ... "9")
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

    /// The bundled CLI binary shipped by the Grok installer.
    public static var defaultExecutable: URL { home.appendingPathComponent("bin/grok") }

    /// Encodes an absolute path the way the CLI names its per-directory session folder.
    public static func encode(path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
    }

    /// Reverses `encode(path:)`. Returns `nil` for names that are not valid encodings.
    public static func decode(directoryName: String) -> String? {
        directoryName.removingPercentEncoding
    }

    /// The directory holding one session's transcript and metadata.
    ///
    /// `cwd` is resolved through `realpath` first, because the CLI records the
    /// resolved path (`/tmp/x` is stored as `/private/tmp/x`).
    public static func sessionDirectory(cwd: String, sessionID: String) -> URL {
        let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        return sessionsRoot
            .appendingPathComponent(encode(path: resolved))
            .appendingPathComponent(sessionID)
    }
}
