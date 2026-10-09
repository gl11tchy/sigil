import Darwin
import Foundation

/// A folder/time candidate is never proof. Process evidence and a fresh
/// validated native envelope must agree on one exact rollout file.
public enum CodexSessionBinding {
    public static func resolve(
        process: ChildProcessGeneration, historyRoot: URL,
        sessions: [GrokSession], workingDirectory: URL
    ) -> GrokSession? {
        guard let before = ProcessOpenFiles.snapshot(of: process, historyRoot: historyRoot),
            before.files.count == 1, let file = before.files.values.first,
            file.writable, file.bornAt >= process.startedAt
        else { return nil }
        let candidates = sessions.filter {
            $0.provider == .codex && !$0.isSubagent
                && GrokPaths.canonicalPath($0.directory.path) == file.identity.path
                && GrokPaths.canonicalPath($0.cwd) == GrokPaths.canonicalPath(workingDirectory.path)
        }
        guard candidates.count == 1, let candidate = candidates.first,
            let validated = validate(candidate, heldIdentity: file.identity),
            ProcessOpenFiles.snapshot(of: process, historyRoot: historyRoot) == before
        else { return nil }
        return validated
    }

    public static func validateForExplicitLink(_ session: GrokSession) -> GrokSession? {
        validate(session, heldIdentity: nil)
    }

    /// A cached row is not enough: replacement or an unrecognized rewrite may
    /// leave it in history. Match a fresh envelope and the descriptor's inode.
    private static func validate(_ session: GrokSession, heldIdentity: ProcessOpenFiles.FileIdentity?) -> GrokSession? {
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
        return session
    }
}
