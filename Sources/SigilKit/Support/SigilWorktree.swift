import Darwin
import Foundation

/// Worktrees Sigil makes for new sessions, at
/// `~/.sigil/worktrees/<encoded project folder>/<name>`. The encoded folder
/// keeps the project path, so a session there still groups under its project.
public enum SigilWorktree {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public let recovery: String?
        public var errorDescription: String? { [message, recovery].compactMap { $0 }.joined(separator: " ") }

        public init(message: String, recovery: String? = nil) {
            self.message = message
            self.recovery = recovery
        }
    }

    /// Only a successful creation can mint this receipt. It is not permission
    /// to remove a finished task's workspace: rollback is for unstarted attempts.
    public struct Creation: Sendable {
        public let repository: URL
        public let checkout: URL
        public let branch: String
        public let originalHead: String
        public let workingDirectory: URL
        fileprivate let checkoutIdentity: DirectoryIdentity
        fileprivate let gitDirectory: URL
        fileprivate let gitIdentity: DirectoryIdentity
        fileprivate let commonDirectory: URL
        fileprivate let commonIdentity: DirectoryIdentity
        fileprivate let parents: [OwnedDirectory]

        public var recovery: String {
            "Recovery: checkout \(checkout.path), branch \(branch) in \(repository.path). Inspect them on the Mac before cleanup."
        }
    }

    public enum Rollback: Equatable, Sendable {
        case removed
        case retained(String)

        public var recoveryMessage: String? {
            if case .retained(let message) = self { return message }
            return nil
        }
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
        nearestRepository(directory) != nil
    }

    /// A dotfiles repository at home remains a repository, but a launch must
    /// opt into a worktree there. Nested repositories keep the usual default.
    public static func shouldDefaultToWorktree(
        _ directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard let repository = nearestRepository(directory) else { return false }
        return repository != GrokPaths.canonicalPath(home.path)
    }

    private static func nearestRepository(_ directory: URL) -> String? {
        var path = GrokPaths.canonicalPath(directory.path)
        while true {
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                return path
            }
            guard path != "/", !path.isEmpty else { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// Adds a worktree on a new `sigil/<name>` branch from the repository's
    /// HEAD and returns the folder that matches `directory` inside it. Returns
    /// nil when `directory` is not in a git repository.
    public static func create(
        for directory: URL, root: URL = root, name: String = defaultName()
    ) async throws -> URL? {
        try await createAttempt(for: directory, root: root, name: name)?.workingDirectory
    }

    public static func createAttempt(
        for directory: URL, root: URL = root, name: String = defaultName()
    ) async throws -> Creation? {
        try Task.checkCancellation()
        let project = GrokPaths.canonicalPath(directory.path)
        let topLevel = try await git(["-C", project, "rev-parse", "--show-toplevel"])
        guard topLevel.status == 0 else { return nil }
        let repository = GrokPaths.canonicalPath(topLevel.output)

        let head = try await git(["-C", repository, "rev-parse", "--verify", "HEAD^{commit}"])
        guard head.status == 0 else {
            throw Failure(message: "The repository for \(project) has no commit to start a worktree from.")
        }
        guard project == repository || project.hasPrefix(repository + "/") else {
            throw Failure(message: "The chosen folder \(project) is outside its repository.")
        }
        let relative = project == repository ? "" : String(project.dropFirst(repository.count + 1))
        if !relative.isEmpty {
            let tree = try await git(["-C", repository, "cat-file", "-t", "\(head.output):\(relative)"])
            guard tree.status == 0, tree.output == "tree" else {
                throw Failure(
                    message: "The chosen folder \(project) is not in HEAD. Commit it first, or choose Project folder.")
            }
        }
        guard !name.isEmpty, name.utf8.count <= 64,
            name.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            })
        else { throw Failure(message: "Choose a worktree name using letters, numbers, hyphens or underscores.") }

        let folder = GrokPaths.encode(path: project)
        guard folder.utf8.count <= 255 else {
            throw Failure(message: "The folder path is too long for a worktree.")
        }
        let canonicalRoot = canonicalFutureDirectory(root)
        let parent = canonicalRoot.appendingPathComponent(folder, isDirectory: true)
        let checkout = parent.appendingPathComponent(name, isDirectory: true)
        let branch = "sigil/\(name)"
        let ref = "refs/heads/\(branch)"
        let existing = try await git(["-C", repository, "show-ref", "--verify", "--quiet", ref])
        guard existing.status == 1,
            (try? FileManager.default.attributesOfItem(atPath: checkout.path)) == nil
        else {
            throw Failure(message: "A worktree folder or branch named \(name) already exists. Choose another name.")
        }
        try Task.checkCancellation()
        let common = try await git(["-C", repository, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard common.status == 0 else { throw Failure(message: "Could not verify the repository for \(project).") }
        let commonDirectory = URL(fileURLWithPath: common.output, isDirectory: true)
        let commonIdentity = try DirectoryIdentity(commonDirectory)
        let parents = try makeParents(parent)
        guard mkdir(checkout.path, 0o755) == 0 else {
            removeEmptyParents(parents)
            throw Failure(message: "Could not create \(checkout.path).")
        }
        let checkoutIdentity: DirectoryIdentity
        do {
            checkoutIdentity = try DirectoryIdentity(checkout)
        } catch {
            throw Failure(message: error.localizedDescription, recovery: "Recovery: \(checkout.path).")
        }
        // Compare-and-create proves this attempt owns the ref; a name collision
        // never changes an existing branch. Always branch from the validated SHA.
        let created: GitResult
        do {
            created = try await git([
                "-C", repository, "update-ref", "--no-deref", ref, head.output,
                String(repeating: "0", count: head.output.count),
            ])
        } catch {
            throw Failure(
                message: error.localizedDescription,
                recovery: "Recovery: \(checkout.path) (branch \(branch)) in \(repository).")
        }
        guard created.status == 0 else {
            if (try? DirectoryIdentity(checkout)) == checkoutIdentity { _ = rmdir(checkout.path) }
            removeEmptyParents(parents)
            throw Failure(
                message: "Could not create branch \(branch) in \(repository). \(created.error)",
                recovery: FileManager.default.fileExists(atPath: checkout.path) ? "Recovery: \(checkout.path)." : nil)
        }
        let target = relative.isEmpty ? checkout : checkout.appendingPathComponent(relative, isDirectory: true)
        let receipt: Creation
        do {
            let added = try await git(["-C", repository, "worktree", "add", checkout.path, branch])
            guard added.status == 0 else { throw Failure(message: "git worktree add failed. \(added.error)") }
            let admin = try await git(["-C", checkout.path, "rev-parse", "--absolute-git-dir"])
            guard admin.status == 0 else { throw Failure(message: "Could not verify the worktree.") }
            let gitDirectory = URL(fileURLWithPath: admin.output, isDirectory: true)
            receipt = try Creation(
                repository: URL(fileURLWithPath: repository), checkout: checkout, branch: branch,
                originalHead: head.output, workingDirectory: target, checkoutIdentity: checkoutIdentity,
                gitDirectory: gitDirectory, gitIdentity: DirectoryIdentity(gitDirectory),
                commonDirectory: commonDirectory, commonIdentity: commonIdentity, parents: parents)
        } catch {
            // A failed Git command can have made partial resources. Without a
            // complete checkout receipt, preserve them instead of guessing.
            throw Failure(
                message: error.localizedDescription,
                recovery: "Recovery: \(checkout.path) (branch \(branch)) in \(repository).")
        }
        do {
            let checkoutHead = try await git(["-C", checkout.path, "rev-parse", "HEAD"])
            let checkoutBranch = try await git(["-C", checkout.path, "symbolic-ref", "HEAD"])
            guard checkoutHead.status == 0, checkoutHead.output == receipt.originalHead,
                checkoutBranch.status == 0, checkoutBranch.output == ref
            else { throw Failure(message: "The worktree changed before launch.") }
        } catch {
            throw Failure(message: error.localizedDescription, recovery: receipt.recovery)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue,
            GrokPaths.canonicalPath(target.path) == target.path
        else {
            let result = await rollback(receipt, processMayHaveStarted: false)
            throw Failure(
                message: "The chosen folder \(project) is unavailable in the worktree.",
                recovery: result.recoveryMessage)
        }
        return receipt
    }

    /// Call only when the launch path knows it never dispatched a process.
    /// Once dispatch may have happened, a late/cancelled reply cannot authorize
    /// deletion. Git removal is non-force; compare-and-delete preserves moved refs.
    public static func rollback(_ receipt: Creation, processMayHaveStarted: Bool) async -> Rollback {
        func retained(_ reason: String) -> Rollback { .retained("\(reason) \(receipt.recovery)") }
        guard !processMayHaveStarted else { return retained("A process may have started.") }
        var checkoutRemoved = false
        do {
            guard try DirectoryIdentity(receipt.checkout) == receipt.checkoutIdentity,
                try DirectoryIdentity(receipt.gitDirectory) == receipt.gitIdentity,
                try DirectoryIdentity(receipt.commonDirectory) == receipt.commonIdentity
            else { return retained("The worktree's identity changed.") }
            let path = receipt.checkout.path
            let admin = try await git(["-C", path, "rev-parse", "--absolute-git-dir"])
            let common = try await git(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
            let repositoryCommon = try await git([
                "-C", receipt.repository.path, "rev-parse", "--path-format=absolute", "--git-common-dir",
            ])
            let head = try await git(["-C", path, "rev-parse", "HEAD"])
            let branch = try await git(["-C", path, "symbolic-ref", "HEAD"])
            let ref = "refs/heads/\(receipt.branch)"
            let saved = try await git(["-C", receipt.repository.path, "rev-parse", "--verify", ref])
            guard admin.status == 0, admin.output == receipt.gitDirectory.path,
                common.status == 0, common.output == receipt.commonDirectory.path,
                repositoryCommon.status == 0, repositoryCommon.output == receipt.commonDirectory.path,
                head.status == 0, head.output == receipt.originalHead,
                branch.status == 0, branch.output == ref,
                saved.status == 0, saved.output == receipt.originalHead
            else { return retained("The worktree or branch changed.") }
            let status = try await git([
                "-C", path, "status", "--porcelain=v1", "--untracked-files=all", "--ignored",
                "--ignore-submodules=none",
            ])
            guard status.status == 0, status.output.isEmpty else {
                return retained("The worktree is not verified pristine.")
            }
            guard try await branchCheckouts(ref, in: receipt.repository) == [path] else {
                return retained("The branch's worktree ownership is uncertain.")
            }
            let removed = try await git(["-C", receipt.repository.path, "worktree", "remove", path])
            guard removed.status == 0 else {
                return retained("Git could not remove the unused worktree: \(removed.error)")
            }
            checkoutRemoved = true
            guard try await branchCheckouts(ref, in: receipt.repository).isEmpty else {
                return .retained(
                    "The unused checkout was removed, but branch \(receipt.branch) is in use in \(receipt.repository.path)."
                )
            }
            let deleted = try await git([
                "-C", receipt.repository.path, "update-ref", "--no-deref", "-d", ref, receipt.originalHead,
            ])
            guard deleted.status == 0 else {
                return .retained(
                    "The unused checkout was removed, but branch \(receipt.branch) remains in \(receipt.repository.path). \(deleted.error)"
                )
            }
            removeEmptyParents(receipt.parents)
            return .removed
        } catch {
            if checkoutRemoved {
                return .retained(
                    "The unused checkout was removed, but branch \(receipt.branch) could not be verified in \(receipt.repository.path). \(error.localizedDescription)"
                )
            }
            return retained("Could not verify cleanup: \(error.localizedDescription)")
        }
    }

    private static func branchCheckouts(_ ref: String, in repository: URL) async throws -> [String] {
        let listed = try await git(["-C", repository.path, "worktree", "list", "--porcelain", "-z"])
        guard listed.status == 0 else { throw Failure(message: "Could not verify registered worktrees.") }
        var path: String?
        var paths: [String] = []
        for field in listed.output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
            if field == "branch \(ref)", let path { paths.append(path) }
        }
        return paths
    }

    fileprivate struct DirectoryIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        init(_ directory: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                let device = attributes[.systemNumber] as? NSNumber,
                let inode = attributes[.systemFileNumber] as? NSNumber
            else { throw Failure(message: "Could not verify folder identity at \(directory.path).") }
            self.device = device.uint64Value
            self.inode = inode.uint64Value
        }
    }

    fileprivate struct OwnedDirectory: Sendable {
        let url: URL
        let identity: DirectoryIdentity
    }

    /// realpath needs an existing path. Resolve the existing ancestor first so
    /// a new root below a symlink or firmlink has the same identity Git reports.
    private static func canonicalFutureDirectory(_ directory: URL) -> URL {
        var ancestor = directory.standardizedFileURL
        var components: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            components.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var result = URL(fileURLWithPath: GrokPaths.canonicalPath(ancestor.path), isDirectory: true)
        for component in components.reversed() { result.appendPathComponent(component, isDirectory: true) }
        return result
    }

    private static func makeParents(_ directory: URL) throws -> [OwnedDirectory] {
        var missing: [URL] = []
        var next = directory
        while !FileManager.default.fileExists(atPath: next.path) {
            missing.append(next)
            next.deleteLastPathComponent()
        }
        var made: [OwnedDirectory] = []
        do {
            for path in missing.reversed() {
                if mkdir(path.path, 0o755) == 0 {
                    made.append(try OwnedDirectory(url: path, identity: DirectoryIdentity(path)))
                } else if errno != EEXIST {
                    throw Failure(message: "Could not create \(path.path).")
                }
            }
            return made
        } catch {
            removeEmptyParents(made)
            throw error
        }
    }

    private static func removeEmptyParents(_ parents: [OwnedDirectory]) {
        for parent in parents.reversed() {
            if (try? DirectoryIdentity(parent.url)) == parent.identity {
                // rmdir refuses nonempty folders, including changes after a check.
                _ = rmdir(parent.url.path)
            }
        }
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
        try await Task.detached { try runGit(arguments) }.value
    }

    private static func runGit(_ arguments: [String]) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure(message: "Could not run git.")
        }
        // Drain both pipes while git runs, so a chatty hook cannot fill one and stall it.
        let errorData = DataBox()
        let drained = DispatchGroup()
        DispatchQueue.global().async(group: drained) {
            errorData.value = error.fileHandleForReading.readDataToEndOfFile()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        var text = String(decoding: out, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return GitResult(
            status: process.terminationStatus,
            output: text,
            // Drain all hook output, but bound diagnostics separately from recovery paths.
            error: String(decoding: errorData.value.prefix(1_024), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }
}
