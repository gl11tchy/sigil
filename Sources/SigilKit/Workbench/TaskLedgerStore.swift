import CryptoKit
import Darwin
import Foundation

/// Cooperating app copies reread under a stable file lock before every mutation.
/// Primary, commit receipt and last-good backup are separate atomic replacements.
/// An interrupted or corrupt combination is read-only until explicit safe recovery.
public final class TaskLedgerStore: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sigil/tasks.json")
    }
    public enum CommitPhase: CaseIterable, Sendable { case prepared, primaryReplaced, receiptReplaced, backupReplaced }
    public struct Status: Sendable {
        public let ledger: TaskLedger
        public let problem: String?
        public let canRecover: Bool
    }

    private struct Envelope: Codable {
        var version = 1
        var revision: UInt64
        var ledger: TaskLedger
    }
    private struct Receipt: Codable {
        let revision: UInt64
        let sha256: String
    }
    private struct Loaded {
        let envelope: Envelope
        let files: [String: Data]
        let problem: String?
        let recovery: Envelope?
        var status: Status { .init(ledger: envelope.ledger, problem: problem, canRecover: recovery != nil) }
    }
    private let url: URL?
    private let mutex = NSLock()
    private let beforeCommit: (@Sendable (CommitPhase) throws -> Void)?
    private var cached = TaskLedger()
    private static let byteLimit = 16 * 1024 * 1024

    /// Nil is a fresh in-memory store, useful for isolated callers and tests.
    public init(url: URL? = nil, beforeCommit: (@Sendable (CommitPhase) throws -> Void)? = nil) {
        self.url = url
        self.beforeCommit = beforeCommit
    }

    public func read() -> Status {
        mutex.lock()
        defer { mutex.unlock() }
        guard let url else { return .init(ledger: cached, problem: nil, canRecover: false) }
        do {
            return try access(url) { parent in
                let loaded = try load(parent, name: url.lastPathComponent)
                cached = loaded.envelope.ledger
                return loaded.status
            }
        } catch {
            return .init(ledger: cached, problem: error.localizedDescription, canRecover: false)
        }
    }

    @discardableResult
    public func transaction<T>(_ change: (inout TaskLedger) throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        guard let url else {
            var next = cached
            let result = try change(&next)
            try next.validate()
            guard next.preserves(cached) else {
                throw TaskLedger.Failure("A task ledger update cannot discard saved identities.")
            }
            cached = next
            return result
        }
        return try access(url) { parent in
            let loaded = try load(parent, name: url.lastPathComponent)
            guard loaded.problem == nil else { throw TaskLedger.Failure(loaded.problem!) }
            var next = loaded.envelope.ledger
            let result = try change(&next)
            try next.validate()
            guard next.preserves(loaded.envelope.ledger) else {
                throw TaskLedger.Failure("A task ledger update cannot discard saved identities.")
            }
            if next != loaded.envelope.ledger {
                guard loaded.envelope.revision < UInt64.max else {
                    throw TaskLedger.Failure("Task ledger revision is exhausted.")
                }
                try commit(
                    .init(revision: loaded.envelope.revision + 1, ledger: next), parent: parent,
                    name: url.lastPathComponent)
            }
            cached = next
            return result
        }
    }

    /// This never rebuilds from legacy preferences. Original bytes are copied to
    /// private recovery files before replacing any of the three protocol files.
    public func recover() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard let url else { return }
        try access(url) { parent in
            let loaded = try load(parent, name: url.lastPathComponent)
            guard loaded.problem != nil else { return }
            guard let candidate = loaded.recovery else {
                throw TaskLedger.Failure(
                    "Safe task recovery is unavailable. Keep the files and repair them before retrying.")
            }
            let prefix = ".recovery-\(UUID().uuidString)-"
            for (name, data) in loaded.files.sorted(by: { $0.key < $1.key }) {
                try replace(data, parent: parent, name: prefix + name)
            }
            guard try files(parent, name: url.lastPathComponent) == loaded.files else {
                throw TaskLedger.Failure(
                    "The task ledger changed during recovery. Retry after the other writer finishes.")
            }
            try commit(candidate, parent: parent, name: url.lastPathComponent)
            cached = candidate.ledger
        }
    }

    private func load(_ parent: Int32, name: String) throws -> Loaded {
        let raw = try files(parent, name: name)
        let primaryData = raw[name]
        let backupData = raw[name + ".backup"]
        let primary = decode(primaryData)
        let backup = decode(backupData)
        let receipt = raw[name + ".receipt"].flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
        let empty = Envelope(revision: 0, ledger: TaskLedger())
        if raw.isEmpty {
            guard cached.entries.isEmpty && cached.legacyIDs.isEmpty else {
                return .init(
                    envelope: .init(revision: 0, ledger: cached), files: raw,
                    problem: "The saved task ledger disappeared. Existing records are read-only.", recovery: nil)
            }
            return .init(envelope: empty, files: raw, problem: nil, recovery: nil)
        }
        func anchored(_ envelope: Envelope?, _ data: Data?) -> Bool {
            guard let envelope, let data, let receipt else { return false }
            return envelope.revision == receipt.revision && digest(data) == receipt.sha256
        }
        let known = [primary, backup].compactMap { $0 }.max { $0.revision < $1.revision }
        let display = Envelope(
            revision: known?.revision ?? 0,
            ledger: cached.retainingKnownRecords(from: known?.ledger ?? TaskLedger())
                .retainingKnownRecords(from: primary?.ledger ?? TaskLedger())
                .retainingKnownRecords(from: backup?.ledger ?? TaskLedger()))
        if unsupported(primaryData) || unsupported(backupData) {
            return .init(
                envelope: display, files: raw,
                problem: "This task ledger requires a different Sigil version. It is read-only.", recovery: nil)
        }
        if let primary, primaryData == backupData, anchored(primary, primaryData), primary.ledger.preserves(cached) {
            return .init(envelope: primary, files: raw, problem: nil, recovery: nil)
        }
        var candidate: Envelope?
        if anchored(primary, primaryData) {
            candidate = primary
        } else if primary == nil, anchored(backup, backupData) {
            candidate = backup
        } else if let primary, let backup, primary.ledger.preserves(backup.ledger),
            primary.revision >= backup.revision,
            primaryData == backupData || (backup.revision < UInt64.max && primary.revision == backup.revision + 1),
            receipt == nil || anchored(backup, backupData)
        {
            candidate = primary
        } else if let primary, backupData == nil, raw[name + ".receipt"] == nil, primary.revision == 1 {
            candidate = primary
        }
        if let proposed = candidate {
            let preservesKnown = [primary, backup].compactMap { $0 }.allSatisfy {
                proposed.revision >= $0.revision && proposed.ledger.preserves($0.ledger)
            }
            if !preservesKnown || !proposed.ledger.preserves(cached) { candidate = nil }
        }
        return .init(
            envelope: display, files: raw,
            problem:
                "The task ledger is incomplete or unreadable. Saved records are read-only; no tasks were rebuilt from legacy preferences.",
            recovery: candidate)
    }

    private func decode(_ data: Data?) -> Envelope? {
        guard let data, let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.version == 1, envelope.revision > 0, (try? envelope.ledger.validate()) != nil
        else { return nil }
        return envelope
    }
    private func unsupported(_ data: Data?) -> Bool {
        struct Header: Decodable { let version: Int }
        guard let data, let header = try? JSONDecoder().decode(Header.self, from: data) else { return false }
        return header.version != 1
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func commit(_ envelope: Envelope, parent: Int32, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.byteLimit else {
            throw TaskLedger.Failure("The task ledger is too large to save safely.")
        }
        let receipt = try encoder.encode(Receipt(revision: envelope.revision, sha256: digest(data)))
        try beforeCommit?(.prepared)
        try replace(data, parent: parent, name: name)
        try beforeCommit?(.primaryReplaced)
        try replace(receipt, parent: parent, name: name + ".receipt")
        try beforeCommit?(.receiptReplaced)
        try replace(data, parent: parent, name: name + ".backup")
        try beforeCommit?(.backupReplaced)
        guard try readFile(parent, name: name) == data,
            try readFile(parent, name: name + ".receipt") == receipt,
            try readFile(parent, name: name + ".backup") == data
        else {
            throw TaskLedger.Failure("Could not confirm the saved task ledger. No new child was started.")
        }
    }

    private func files(_ parent: Int32, name: String) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in [name, name + ".backup", name + ".receipt"] {
            if let data = try readFile(parent, name: file) { result[file] = data }
        }
        return result
    }

    private func access<T>(_ url: URL, operation: (Int32) throws -> T) throws -> T {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
            !url.lastPathComponent.hasPrefix(".")
        else { throw TaskLedger.Failure("Invalid task ledger location.") }
        let parent = try openParent(url)
        defer { close(parent) }
        let lockName = url.lastPathComponent + ".lock"
        let fd = openat(parent, lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw posix("open lock", lockName) }
        defer { close(fd) }
        let info = try privateFile(fd)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN, ProcessInfo.processInfo.systemUptime < deadline else {
                throw TaskLedger.Failure("Another Sigil copy is updating the task ledger. Retry shortly.")
            }
            usleep(1_000)
        }
        defer { _ = flock(fd, LOCK_UN) }
        var current = stat()
        guard fstatat(parent, lockName, &current, AT_SYMLINK_NOFOLLOW) == 0, sameFile(info, current) else {
            throw TaskLedger.Failure("The task ledger lock changed. Saved records are read-only.")
        }
        let result = try operation(parent)
        let currentParent = try openParent(url, create: false)
        defer { close(currentParent) }
        var originalDirectory = stat()
        var currentDirectory = stat()
        guard fstat(parent, &originalDirectory) == 0, fstat(currentParent, &currentDirectory) == 0,
            originalDirectory.st_dev == currentDirectory.st_dev, originalDirectory.st_ino == currentDirectory.st_ino
        else {
            throw TaskLedger.Failure("The task ledger folder changed during the operation. No new child was started.")
        }
        return result
    }

    private func openParent(_ url: URL, create: Bool = true) throws -> Int32 {
        // Only the platform's system aliases are expanded. Other symlink path
        // components are rejected instead of following an unexpected destination.
        var path = url.deletingLastPathComponent().standardizedFileURL.path
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
            break
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posix("open parent root") }
        do {
            for component in path.split(separator: "/").map(String.init) {
                if create, mkdirat(fd, component, 0o700) != 0, errno != EEXIST {
                    throw posix("create parent component", component)
                }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posix("open parent component", component) }
                close(fd)
                fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
                throw TaskLedger.Failure(
                    "The task ledger folder must be owned by this user and protected from other writers.")
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func readFile(_ parent: Int32, name: String) throws -> Data? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw posix("open protocol file", name)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let before = try privateFile(fd)
        guard before.st_size >= 0, before.st_size <= Self.byteLimit else {
            throw TaskLedger.Failure("Invalid task ledger file size.")
        }
        var data = Data()
        while data.count < Int(before.st_size) {
            let chunk: Data
            do { chunk = try handle.read(upToCount: min(64 * 1024, Int(before.st_size) - data.count)) ?? Data() } catch
            { throw context(error, operation: "read protocol file", target: name) }
            guard !chunk.isEmpty else { throw TaskLedger.Failure("The task ledger file was truncated during reading.") }
            data.append(chunk)
        }
        let after = try privateFile(fd)
        var pathInfo = stat()
        guard sameFile(before, after), data.count == after.st_size,
            fstatat(parent, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0, sameFile(after, pathInfo)
        else {
            throw TaskLedger.Failure("The task ledger changed while it was read. Retry shortly.")
        }
        return data
    }

    private func replace(_ data: Data, parent: Int32, name: String) throws {
        let temporary = ".task-ledger-\(UUID().uuidString).tmp"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix("create temporary file", temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(parent, temporary, 0)
        }
        _ = try privateFile(fd)
        do { try handle.write(contentsOf: data) } catch {
            throw context(error, operation: "write temporary file", target: name)
        }
        guard fsync(fd) == 0 else { throw posix("sync temporary file", name) }
        let prepared = try privateFile(fd)
        var temporaryInfo = stat()
        var destination = stat()
        guard fstatat(parent, temporary, &temporaryInfo, AT_SYMLINK_NOFOLLOW) == 0, sameFile(prepared, temporaryInfo)
        else {
            throw TaskLedger.Failure("The prepared task ledger file changed.")
        }
        if fstatat(parent, name, &destination, AT_SYMLINK_NOFOLLOW) == 0 {
            guard destination.st_mode & S_IFMT == S_IFREG, destination.st_uid == geteuid(), destination.st_nlink == 1
            else {
                throw TaskLedger.Failure("The task ledger destination is not a private regular file.")
            }
        } else if errno != ENOENT {
            throw posix("inspect destination", name)
        }
        guard renameat(parent, temporary, parent, name) == 0 else { throw posix("replace protocol file", name) }
        guard fsync(parent) == 0 else { throw posix("sync parent directory", name) }
    }

    private func privateFile(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
            info.st_nlink == 1, info.st_mode & 0o777 == 0o600
        else {
            throw TaskLedger.Failure("The task ledger file must be a private regular file owned by this user.")
        }
        return info
    }
    private func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func posix(_ operation: StaticString, _ target: String = "") -> NSError {
        let code = errno
        return context(
            NSError(domain: NSPOSIXErrorDomain, code: Int(code)), operation: String(describing: operation),
            target: target)
    }
    private func context(_ error: Error, operation: String, target: String) -> NSError {
        let original = error as NSError
        var info = original.userInfo
        info[NSLocalizedDescriptionKey] =
            "\(operation)\(target.isEmpty ? "" : " (\(target))"): \(original.localizedDescription)"
        if let url { info[NSFilePathErrorKey] = url.path }
        return NSError(domain: original.domain, code: original.code, userInfo: info)
    }
}
