import Foundation

/// Worktrees Sigil makes for new sessions, at
/// `~/.sigil/worktrees/<encoded project folder>/<name>`. The encoded folder
/// keeps the project path, so a session there still groups under its project.
public enum SigilWorktree {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static let root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".sigil/worktrees", isDirectory: true)

    /// The project folder that `path` is a Sigil worktree of, or nil for any other path.
    public static func projectPath(of path: String, root: URL = root) -> String? {
        for prefix in Set([root.path, GrokPaths.canonicalPath(root.path)]) {
            guard path.hasPrefix(prefix + "/") else { continue }
            let rest = path.dropFirst(prefix.count + 1).split(separator: "/")
            guard rest.count >= 2, let project = GrokPaths.decode(directoryName: String(rest[0])),
                project.hasPrefix("/")
            else { return nil }
            return project
        }
        return nil
    }

    /// True when `directory` or a folder above it holds a `.git` entry.
    public static func isInRepository(_ directory: URL) -> Bool {
        var path = directory.standardizedFileURL.path
        while true {
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                return true
            }
            guard path != "/", !path.isEmpty else { return false }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// Adds a worktree on a new `sigil/<name>` branch from the repository's
    /// HEAD and returns the folder that matches `directory` inside it. Returns
    /// nil when `directory` is not in a git repository.
    public static func create(
        for directory: URL, root: URL = root, name: String = defaultName()
    ) async throws -> URL? {
        let project = GrokPaths.canonicalPath(directory.path)
        let topLevel = try await git(["-C", project, "rev-parse", "--show-toplevel"])
        guard topLevel.status == 0 else { return nil }
        let repository = GrokPaths.canonicalPath(topLevel.output)

        let folder = GrokPaths.encode(path: project)
        guard folder.utf8.count <= 255 else {
            throw Failure(message: "The folder path is too long for a worktree.")
        }
        let parent = root.appendingPathComponent(folder, isDirectory: true)
        let checkout = parent.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let added = try await git([
            "-C", repository, "worktree", "add", "-b", "sigil/\(name)", checkout.path, "HEAD",
        ])
        guard added.status == 0 else {
            throw Failure(message: added.error.isEmpty ? "git worktree add failed." : added.error)
        }

        // Start in the same subfolder the user chose, when the checkout has it.
        let relative = project == repository ? "" : String(project.dropFirst(repository.count + 1))
        let target = relative.isEmpty ? checkout : checkout.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
        let chosen = exists && isDirectory.boolValue ? target : checkout
        return URL(fileURLWithPath: GrokPaths.canonicalPath(chosen.path), isDirectory: true)
    }

    public static func defaultName() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private struct GitResult {
        var status: Int32
        var output: String
        var error: String
    }

    private static func git(_ arguments: [String]) async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = error.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: GitResult(
                        status: finished.terminationStatus,
                        output: String(decoding: out, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        error: String(decoding: err, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure(message: "Could not run git."))
            }
        }
    }
}
