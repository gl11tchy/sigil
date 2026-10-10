import Foundation

/// Automatic discovery follows the user's installed `grok`; a custom path is
/// a deliberate choice, even when its file is missing or its version is old.
public enum GrokExecutableSelection: Sendable, Equatable {
    case installed
    case custom(String)

    public static func restoring(
        storedPath: String?, wasChosen: Bool, installer: URL, themed: URL
    ) -> GrokExecutableSelection {
        guard let storedPath else { return .installed }
        if wasChosen { return .custom(storedPath) }
        let path = (storedPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        // Only known old defaults migrate. Older custom paths without a choice
        // marker stay custom; file existence is not evidence of user intent.
        if path.isEmpty || path == installer.path || path == themed.path { return .installed }
        return .custom(storedPath)
    }
}
