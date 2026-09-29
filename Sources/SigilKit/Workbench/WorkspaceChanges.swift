import Darwin
import Foundation

/// What changed in a task's workspace, read from Git.
public struct WorkspaceChanges: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case typeChanged = "T"
        case untracked = "?"
        case conflicted = "U"

        public var name: String {
            switch self {
            case .modified: "Modified"
            case .added: "Added"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .copied: "Copied"
            case .typeChanged: "Type changed"
            case .untracked: "Untracked"
            case .conflicted: "Conflicted"
            }
        }
    }

    public struct File: Identifiable, Equatable, Sendable {
        public let path: String
        /// The previous path of a rename or copy.
        public let oldPath: String?
        public let status: Status
        /// Nil for binary and untracked files, which Git does not count.
        public let added: Int?
        public let removed: Int?

        public var id: String { path }

        public init(path: String, oldPath: String? = nil, status: Status, added: Int?, removed: Int?) {
            self.path = path
            self.oldPath = oldPath
            self.status = status
            self.added = added
            self.removed = removed
        }
    }

    /// The branch, or `detached at <sha>`. Nil when Git named neither.
    public let head: String?
    public let files: [File]
    /// True when there were more files than the reader keeps.
    public let isTruncated: Bool

    public init(head: String?, files: [File], isTruncated: Bool = false) {
        self.head = head
        self.files = files
        self.isTruncated = isTruncated
    }

    public var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    public var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
}

/// A read of a workspace: its changes, or why there are none to show.
public enum WorkspaceChangesReading: Equatable, Sendable {
    case changes(WorkspaceChanges)
    case notRepository
    case missingFolder
    case failed(String)
}

/// Reads `git status` and `git diff --numstat` for one folder. Read-only: it
/// runs with optional locks off, so it never takes the index lock an agent
/// working in the same checkout may need.
public enum WorkspaceChangesReader {
    public static let fileLimit = 500
    /// Git's empty tree, for a repository with no commit yet.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    public static func read(
        _ directory: URL, git: URL = URL(fileURLWithPath: "/usr/bin/git"), timeout: Duration = .seconds(5)
    ) async -> WorkspaceChangesReading {
        await Task.detached(priority: .utility) {
            readNow(directory, git: git, timeout: timeout)
        }.value
    }

    static func readNow(_ directory: URL, git: URL, timeout: Duration) -> WorkspaceChangesReading {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return .missingFolder }

        func run(_ arguments: [String]) -> GitOutput? {
            GitOutput.run(git: git, arguments: ["-C", directory.path] + arguments, timeout: timeout)
        }

        guard let inside = run(["rev-parse", "--is-inside-work-tree"]) else {
            return .failed("Git did not answer.")
        }
        guard inside.status == 0, inside.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .notRepository
        }
        guard let status = run(["status", "--porcelain=v1", "-z", "--untracked-files=all"]) else {
            return .failed("Git did not answer.")
        }
        guard status.status == 0 else { return .failed(status.errorSummary) }

        let hasCommit = run(["rev-parse", "--verify", "--quiet", "HEAD"])?.status == 0
        guard let numstat = run(["diff", hasCommit ? "HEAD" : emptyTree, "--numstat", "-z", "-M"]) else {
            return .failed("Git did not answer.")
        }
        guard numstat.status == 0 else { return .failed(numstat.errorSummary) }

        var head: String?
        if let branch = run(["symbolic-ref", "--short", "-q", "HEAD"]), branch.status == 0 {
            head = branch.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        } else if let sha = run(["rev-parse", "--short", "HEAD"]), sha.status == 0,
            let short = sha.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        {
            head = "detached at \(short)"
        }

        let counts = parseNumstat(numstat.data)
        let entries = parseStatus(status.data)
        let files = entries.prefix(fileLimit).map { entry in
            let count = counts[entry.path]
            return WorkspaceChanges.File(
                path: entry.path, oldPath: entry.oldPath, status: entry.status,
                added: count?.added, removed: count?.removed)
        }
        return .changes(WorkspaceChanges(head: head, files: files, isTruncated: entries.count > fileLimit))
    }

    struct StatusEntry: Equatable {
        let path: String
        let oldPath: String?
        let status: WorkspaceChanges.Status
    }

    /// `git status --porcelain=v1 -z`: `XY path`, and for a rename or copy a
    /// second field with the old path.
    static func parseStatus(_ data: Data) -> [StatusEntry] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        if fields.last == "" { fields.removeLast() }
        var entries: [StatusEntry] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard field.count > 3 else { continue }
            let x = field[field.startIndex]
            let y = field[field.index(after: field.startIndex)]
            let path = String(field.dropFirst(3))
            if x == "!" { continue }
            var oldPath: String?
            if x == "R" || x == "C", index < fields.count {
                oldPath = fields[index]
                index += 1
            }
            entries.append(StatusEntry(path: path, oldPath: oldPath, status: status(x: x, y: y)))
        }
        return entries
    }

    static func status(x: Character, y: Character) -> WorkspaceChanges.Status {
        if x == "?" { return .untracked }
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { return .conflicted }
        if x == "R" { return .renamed }
        if x == "C" { return .copied }
        if x == "A" { return .added }
        if x == "D" || y == "D" { return .deleted }
        if x == "T" || y == "T" { return .typeChanged }
        return .modified
    }

    /// `git diff --numstat -z`: `added<TAB>removed<TAB>path`, or for a rename
    /// `added<TAB>removed<TAB>` followed by the old and new paths as fields.
    /// Binary files count as `-`.
    static func parseNumstat(_ data: Data) -> [String: (added: Int?, removed: Int?)] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        if fields.last == "" { fields.removeLast() }
        var counts: [String: (added: Int?, removed: Int?)] = [:]
        var index = 0
        while index < fields.count {
            let parts = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            index += 1
            guard parts.count == 3 else { continue }
            let added = Int(parts[0])
            let removed = Int(parts[1])
            var path = String(parts[2])
            if path.isEmpty, index + 1 < fields.count {
                path = fields[index + 1]
                index += 2
            }
            counts[path] = (added, removed)
        }
        return counts
    }
}

/// One bounded Git run: both pipes drained while it runs, a deadline, and
/// an environment that cannot point it at another repository or prompt.
struct GitOutput {
    static let byteLimit = 4 << 20

    let status: Int32
    let data: Data
    let error: String

    var text: String { String(decoding: data, as: UTF8.self) }

    var errorSummary: String {
        let line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "Git exited with status \(status)." : line
    }

    static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"] {
            env.removeValue(forKey: key)
        }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        return env
    }

    static func run(git: URL, arguments: [String], timeout: Duration) -> GitOutput? {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let out = Collected()
        let err = Collected()
        let drained = DispatchGroup()
        for (pipe, box) in [(output, out), (error, err)] {
            DispatchQueue.global(qos: .utility).async(group: drained) {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    box.append(chunk, limit: byteLimit)
                }
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if exited.wait(timeout: .now() + seconds) == .timedOut {
            // Not waiting for the pipes: a child Git started could hold them open.
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        drained.wait()
        return GitOutput(
            status: process.terminationStatus, data: out.data,
            error: String(decoding: err.data, as: UTF8.self))
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()

        func append(_ chunk: Data, limit: Int) {
            lock.lock()
            defer { lock.unlock() }
            let room = max(0, limit - stored.count)
            stored.append(chunk.prefix(room))
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
