import Foundation
import Darwin

func refuse(_ check: String) -> Never {
    fputs("Foundation path preflight refused: \(check).\n", stderr)
    exit(2)
}

guard CommandLine.arguments.count == 3 else { refuse("argument-count") }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    .resolvingSymlinksInPath().path
let environment = ProcessInfo.processInfo.environment
func confined(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    // Reject outside paths before resolving their symlinks or inspecting them.
    guard url.path == root || url.path.hasPrefix(root + "/") else { return false }
    let resolved = url.resolvingSymlinksInPath().path
    return resolved == root || resolved.hasPrefix(root + "/")
}

for key in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "ZDOTDIR", "GROK_HOME",
            "CODEX_HOME", "CLAUDE_CONFIG_DIR", "KIMI_CODE_HOME", "XDG_CONFIG_HOME",
            "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "SIGIL_CRASH_LOG_DIR"] {
    guard let path = environment[key], confined(path) else { refuse("environment-\(key)") }
}
guard FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == root else {
    refuse("FileManager.homeDirectoryForCurrentUser")
}
guard NSHomeDirectory() == root else { refuse("NSHomeDirectory") }
guard ("~" as NSString).expandingTildeInPath == root else { refuse("NSString.expandingTildeInPath") }
guard confined(NSTemporaryDirectory()) else { refuse("NSTemporaryDirectory") }
guard confined(FileManager.default.temporaryDirectory.path) else { refuse("FileManager.temporaryDirectory") }
guard CommandLine.arguments[2].contains(".xctest/") else { refuse("test-bundle-argument") }
let directories: [(FileManager.SearchPathDirectory, String)] = [
    (.applicationSupportDirectory, "FileManager.applicationSupportDirectory"),
    (.cachesDirectory, "FileManager.cachesDirectory"),
    (.documentDirectory, "FileManager.documentDirectory"),
]
for (directory, check) in directories {
    guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first,
          confined(url.path) else { refuse(check) }
}
// No directory enumeration, history/config reads, Keychain or networking.
print("Foundation path preflight passed; generated roots only.")
