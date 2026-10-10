import Foundation
import Darwin

func refuse(_ check: String) -> Never {
    fputs("Foundation path preflight refused: \(check).\n", stderr)
    exit(2)
}

guard CommandLine.arguments.count == 3 else { refuse("argument-count") }
func lexicalPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
    let parts = path.split(separator: "/")
    // Do not collapse parent traversal across a possible symbolic link.
    guard !parts.contains("."), !parts.contains("..") else { return nil }
    return "/" + parts.joined(separator: "/")
}
func canonicalPath(_ path: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    return path.withCString { name in
        buffer.withUnsafeMutableBufferPointer { bytes in
            guard let base = bytes.baseAddress, realpath(name, base) != nil else { return nil }
            return String(cString: base)
        }
    }
}
func inside(_ path: String, _ directory: String) -> Bool {
    path == directory || path.hasPrefix(directory + "/")
}
guard let argumentRoot = lexicalPath(CommandLine.arguments[1]),
      let root = canonicalPath(argumentRoot) else { refuse("generated-root-realpath") }

// Only derive alternate spellings of this complete generated root. Prove both
// the fixed system alias and the generated directory's physical identity first.
var generatedRoots: Set<String> = [root]
for (alias, physical) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
    guard inside(root, alias) || inside(root, physical),
          let aliasBase = canonicalPath(alias), let physicalBase = canonicalPath(physical),
          aliasBase == physicalBase else { continue }
    for (from, to) in [(alias, physical), (physical, alias)] {
        guard inside(root, from) else { continue }
        let alternate = to + String(root.dropFirst(from.count))
        guard canonicalPath(alternate) == root else { continue }
        generatedRoots.insert(alternate)
    }
}
print("Foundation generated-root alias proof: proved=\(generatedRoots.count > 1)")
let environment = ProcessInfo.processInfo.environment
func confined(_ rawPath: String, _ check: String, exactRoot: Bool = false) -> Bool {
    guard let path = lexicalPath(rawPath) else {
        print("Foundation path check \(check): lexical=false provedAlias=false canonicalChecked=false confined=false")
        return false
    }
    let lexical = exactRoot ? path == root : inside(path, root)
    let provedAlias = !lexical && generatedRoots.contains {
        exactRoot ? path == $0 : inside(path, $0)
    }
    // Never resolve an unrelated system temporary directory or original home.
    let checked = lexical || provedAlias
    let resolved = checked ? canonicalPath(path) : nil
    let accepted = resolved.map { exactRoot ? $0 == root : inside($0, root) } ?? false
    print("Foundation path check \(check): lexical=\(lexical) provedAlias=\(provedAlias) canonicalChecked=\(checked) confined=\(accepted)")
    return accepted
}

for key in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "ZDOTDIR", "GROK_HOME",
            "CODEX_HOME", "CLAUDE_CONFIG_DIR", "KIMI_CODE_HOME", "XDG_CONFIG_HOME",
            "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "SIGIL_CRASH_LOG_DIR"] {
    let check = "environment-\(key)"
    guard let path = environment[key], confined(path, check) else { refuse(check) }
}
guard confined(FileManager.default.homeDirectoryForCurrentUser.path,
               "FileManager.homeDirectoryForCurrentUser", exactRoot: true) else {
    refuse("FileManager.homeDirectoryForCurrentUser")
}
guard confined(NSHomeDirectory(), "NSHomeDirectory", exactRoot: true) else { refuse("NSHomeDirectory") }
guard confined(("~" as NSString).expandingTildeInPath,
               "NSString.expandingTildeInPath", exactRoot: true) else { refuse("NSString.expandingTildeInPath") }
guard confined(NSTemporaryDirectory(), "NSTemporaryDirectory") else { refuse("NSTemporaryDirectory") }
guard confined(FileManager.default.temporaryDirectory.path,
               "FileManager.temporaryDirectory") else { refuse("FileManager.temporaryDirectory") }
guard CommandLine.arguments[2].contains(".xctest/") else { refuse("test-bundle-argument") }
let directories: [(FileManager.SearchPathDirectory, String)] = [
    (.applicationSupportDirectory, "FileManager.applicationSupportDirectory"),
    (.cachesDirectory, "FileManager.cachesDirectory"),
    (.documentDirectory, "FileManager.documentDirectory"),
]
for (directory, check) in directories {
    guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first,
          confined(url.path, check) else { refuse(check) }
}
// No directory enumeration, history/config reads, Keychain or networking.
print("Foundation path preflight passed; generated roots only.")
