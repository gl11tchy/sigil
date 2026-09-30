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

        /// A path can be two rows: `git rm --cached` lists it as deleted and
        /// as untracked. Git lists each tracked path once and each untracked
        /// path once, so the side and the path name a row, and a tracked
        /// file keeps its row when its status changes.
        public struct ID: Hashable, Sendable {
            public let path: String
            public let isUntracked: Bool
        }

        public var id: ID { ID(path: path, isUntracked: status == .untracked) }

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

        let entries = parseStatus(status.data)
        let files = join(entries, parseNumstat(numstat.data)).prefix(fileLimit)
        return .changes(WorkspaceChanges(head: head, files: Array(files), isTruncated: entries.count > fileLimit))
    }

    /// Gives each numstat count to exactly one status entry. A tracked entry
    /// takes its own path's count. A rename or copy also takes its old
    /// path's count when no tracked entry owns that path: status pairs a
    /// staged rename against the index, but numstat compares HEAD with the
    /// working tree and reports a deletion and an addition once the file no
    /// longer resembles its original. A work-tree rename (` R`) of a path with
    /// staged changes also lists that path, which keeps its own count.
    /// Untracked entries take nothing, as Git counts nothing for them, even
    /// when a deleted path is back on disk.
    static func join(
        _ entries: [StatusEntry], _ counts: [String: (added: Int?, removed: Int?)]
    ) -> [WorkspaceChanges.File] {
        var owned = Set(entries.filter { $0.status != .untracked }.map(\.path))
        return entries.map { entry in
            var count = entry.status == .untracked ? nil : counts[entry.path]
            if let oldPath = entry.oldPath, owned.insert(oldPath).inserted, let old = counts[oldPath] {
                count = count.map { (sum($0.added, old.added), sum($0.removed, old.removed)) } ?? old
            }
            return WorkspaceChanges.File(
                path: entry.path, oldPath: entry.oldPath, status: entry.status,
                added: count?.added, removed: count?.removed)
        }
    }

    /// Nil only when neither side has a count, as for a binary file.
    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0)
    }

    struct StatusEntry: Equatable {
        let path: String
        let oldPath: String?
        let status: WorkspaceChanges.Status
    }

    /// `git status --porcelain=v1 -z`: `XY path`, and for a rename or copy a
    /// second field with the old path. Either column can name the rename:
    /// Git pairs a work-tree deletion with an intent-to-add path as ` R`.
    /// The prefix is read as bytes: a path that starts with a combining mark
    /// would join the separator space into one `Character`.
    static func parseStatus(_ data: Data) -> [StatusEntry] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        var entries: [StatusEntry] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard field.count > 3 else { continue }
            let x = Character(Unicode.Scalar(field[field.startIndex]))
            let y = Character(Unicode.Scalar(field[field.startIndex + 1]))
            let path = String(decoding: field.dropFirst(3), as: UTF8.self)
            if x == "!" { continue }
            var oldPath: String?
            if [x, y].contains(where: { $0 == "R" || $0 == "C" }), index < fields.count {
                oldPath = String(decoding: fields[index], as: UTF8.self)
                index += 1
            }
            entries.append(StatusEntry(path: path, oldPath: oldPath, status: status(x: x, y: y)))
        }
        return entries
    }

    /// Outside a conflict, Git puts `A` in the work-tree column only for an
    /// intent-to-add path. ` A` is new, as numstat counts it. `DA` is a path
    /// HEAD still has, removed from the index and added back with -N, so
    /// against HEAD it is modified.
    static func status(x: Character, y: Character) -> WorkspaceChanges.Status {
        if x == "?" { return .untracked }
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { return .conflicted }
        if x == "R" || y == "R" { return .renamed }
        if x == "C" || y == "C" { return .copied }
        if x == "D" && y == "A" { return .modified }
        if x == "A" || y == "A" { return .added }
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

/// One bounded Git run: both pipes drained while it runs, one deadline for
/// the exit and the drain, and an environment that cannot point it at
/// another repository or prompt.
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

    /// Nil when Git cannot start, or when it has not both exited and closed
    /// its pipes by the deadline. A child Git started can hold the pipes open
    /// after Git exits, so a successful exit alone is not an answer.
    static func run(git: URL, arguments: [String], timeout: Duration) -> GitOutput? {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let deadline = DispatchTime.now() + seconds
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
        // Closing the read ends releases them on every path. A child still
        // writing then gets EPIPE instead of blocking.
        defer {
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
        }
        do { try process.run() } catch { return nil }

        let drained = drain(
            [output.fileHandleForReading.fileDescriptor, error.fileHandleForReading.fileDescriptor],
            until: deadline)
        guard let drained, exited.wait(timeout: deadline) == .success else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        return GitOutput(
            status: process.terminationStatus, data: drained[0], error: String(decoding: drained[1], as: UTF8.self))
    }

    /// Reads every descriptor to end of file on this thread, keeping at most
    /// `byteLimit` bytes of each. Nil when the deadline passes first; no
    /// reader is left blocked, because the descriptors are non-blocking.
    private static func drain(_ descriptors: [Int32], until deadline: DispatchTime) -> [Data]? {
        var collected = descriptors.map { _ in Data() }
        var open = descriptors.map { fd in fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 }
        guard !open.contains(false) else { return nil }
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while open.contains(true) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { return nil }
            let milliseconds = Int32(clamping: (deadline.uptimeNanoseconds - now + 999_999) / 1_000_000)
            var polled = descriptors.indices.filter { open[$0] }.map {
                pollfd(fd: descriptors[$0], events: Int16(POLLIN), revents: 0)
            }
            let ready = poll(&polled, nfds_t(polled.count), milliseconds)
            if ready < 0, errno != EINTR { return nil }
            guard ready > 0 else { continue }
            // One read per ready stream, so a child that never stops writing
            // still meets the deadline check above.
            for entry in polled where entry.revents != 0 {
                guard let index = descriptors.firstIndex(of: entry.fd) else { continue }
                let count = read(entry.fd, &buffer, buffer.count)
                if count > 0 {
                    let room = max(0, byteLimit - collected[index].count)
                    collected[index].append(contentsOf: buffer.prefix(min(count, room)))
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    open[index] = false
                }
            }
        }
        return collected
    }
}
