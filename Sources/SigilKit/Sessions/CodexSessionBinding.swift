import Darwin
import Foundation

/// A folder/time candidate is never proof. Process evidence and a fresh
/// validated native envelope must agree on one exact rollout file.
public enum CodexSessionBinding {
    /// A fresh envelope and exact file identity. Only the binding boundary can
    /// create this receipt; a cached row or URL cannot certify live ownership.
    public struct Transcript: Sendable {
        public let session: GrokSession
        public let processGeneration: ChildProcessGeneration?
        let fileIdentity: ProcessOpenFiles.FileIdentity
        let bornAt: TimeInterval
        private let historyRoot: URL?
        private let snapshot: (@Sendable (ChildProcessGeneration, URL) -> ProcessOpenFiles.Snapshot?)?

        fileprivate init(
            session: GrokSession, processGeneration: ChildProcessGeneration?,
            fileIdentity: ProcessOpenFiles.FileIdentity, bornAt: TimeInterval, historyRoot: URL?,
            snapshot: (@Sendable (ChildProcessGeneration, URL) -> ProcessOpenFiles.Snapshot?)?
        ) {
            self.session = session
            self.processGeneration = processGeneration
            self.fileIdentity = fileIdentity
            self.bornAt = bornAt
            self.historyRoot = historyRoot
            self.snapshot = snapshot
        }

        public var processStartedAt: Date? {
            processGeneration.map { Date(timeIntervalSince1970: $0.startedAt) }
        }

        public var canReadFromBeginning: Bool {
            processGeneration.map { bornAt >= $0.startedAt } == true
        }

        enum Lease: Equatable, Sendable {
            case explicit
            case owned(ProcessOpenFiles.Snapshot)
        }

        /// The journal compares leases before and after reading. `/new`, an
        /// extra held file, a reused child or a changing tree loses authority.
        func lease() -> Lease? {
            guard let processGeneration else { return .explicit }
            guard let historyRoot, let snapshot,
                let current = snapshot(processGeneration, historyRoot), current.files.count == 1,
                let file = current.files.values.first, file.identity == fileIdentity,
                file.writable, file.bornAt >= processGeneration.startedAt
            else { return nil }
            return .owned(current)
        }
    }

    public static func resolve(
        process: ChildProcessGeneration, historyRoot: URL,
        sessions: [GrokSession], workingDirectory: URL
    ) -> GrokSession? {
        resolveTranscript(
            process: process, historyRoot: historyRoot, sessions: sessions, workingDirectory: workingDirectory)?
            .session
    }

    public static func resolveTranscript(
        process: ChildProcessGeneration, historyRoot: URL,
        sessions: [GrokSession], workingDirectory: URL
    ) -> Transcript? {
        resolveTranscript(
            process: process, historyRoot: historyRoot, sessions: sessions, workingDirectory: workingDirectory,
            snapshot: { ProcessOpenFiles.snapshot(of: $0, historyRoot: $1) })
    }

    /// Synthetic CI kernel observations use the same exact validation path.
    static func resolveTranscript(
        process: ChildProcessGeneration, historyRoot: URL, sessions: [GrokSession], workingDirectory: URL,
        snapshot: @escaping @Sendable (ChildProcessGeneration, URL) -> ProcessOpenFiles.Snapshot?
    ) -> Transcript? {
        guard let before = snapshot(process, historyRoot),
            before.files.count == 1, let file = before.files.values.first,
            file.writable, file.bornAt >= process.startedAt
        else { return nil }
        let candidates = sessions.filter {
            $0.provider == .codex && !$0.isSubagent
                && GrokPaths.canonicalPath($0.directory.path) == file.identity.path
                && GrokPaths.canonicalPath($0.cwd) == GrokPaths.canonicalPath(workingDirectory.path)
        }
        guard candidates.count == 1, let candidate = candidates.first,
            let validated = validate(
                candidate, heldIdentity: file.identity, process: process, historyRoot: historyRoot, snapshot: snapshot),
            snapshot(process, historyRoot) == before
        else { return nil }
        return validated
    }

    public static func validateForExplicitLink(_ session: GrokSession) -> GrokSession? {
        transcriptForExplicitLink(session)?.session
    }

    public static func transcriptForExplicitLink(_ session: GrokSession) -> Transcript? {
        validate(session, heldIdentity: nil, process: nil, historyRoot: nil, snapshot: nil)
    }

    /// A cached row is not enough: replacement or an unrecognized rewrite may
    /// leave it in history. Match a fresh envelope and the descriptor's inode.
    private static func validate(
        _ session: GrokSession, heldIdentity: ProcessOpenFiles.FileIdentity?, process: ChildProcessGeneration?,
        historyRoot: URL?, snapshot: (@Sendable (ChildProcessGeneration, URL) -> ProcessOpenFiles.Snapshot?)?
    ) -> Transcript? {
        guard session.provider == .codex, !session.isSubagent else { return nil }
        let file = URL(fileURLWithPath: GrokPaths.canonicalPath(session.directory.path))
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else {
            return nil
        }
        let identity = ProcessOpenFiles.FileIdentity(
            path: file.path, device: UInt32(bitPattern: before.st_dev), inode: UInt64(before.st_ino))
        guard heldIdentity == nil || heldIdentity == identity,
            let data = try? NativeSessionScanner.boundedContents(handle, size: UInt64(before.st_size)),
            let parsed = NativeSessionScanner.parse(
                provider: .codex, data: data, file: file,
                modified: Date(timeIntervalSince1970: Double(before.st_mtimespec.tv_sec))),
            parsed.nativeSessionID == session.nativeSessionID,
            GrokPaths.canonicalPath(parsed.cwd) == GrokPaths.canonicalPath(session.cwd), !parsed.isSubagent
        else { return nil }
        var after = stat()
        guard lstat(file.path, &after) == 0, after.st_mode & S_IFMT == S_IFREG,
            after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_size == before.st_size,
            after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
            after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
            after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        else { return nil }
        return Transcript(
            session: session.validatingHistory(), processGeneration: process, fileIdentity: identity,
            bornAt: Double(before.st_birthtimespec.tv_sec) + Double(before.st_birthtimespec.tv_nsec) / 1_000_000_000,
            historyRoot: historyRoot, snapshot: snapshot)
    }
}
