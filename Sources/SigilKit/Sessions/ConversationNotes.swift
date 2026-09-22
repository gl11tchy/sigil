import Foundation
import os

/// One Markdown scratch pad per conversation, stored as
/// `notes/<encoded-cwd>/<session-id>.md` under Application Support — the same
/// identity (session ID + working directory) and on-disk layout the CLI uses.
///
/// Files keep the notes readable outside the app and unbounded by what a
/// plist value can hold. Typing mutates the in-memory cache immediately, so
/// the editor never waits on the disk; a coalesced writer persists the latest
/// text after a short quiet period, and `flushNow()` finishes the rest on the
/// quit path, where no run loop survives to finish async work.
@MainActor
public final class ConversationNotesStore {
    public let root: URL
    /// Current text per file, including writes the disk has not seen yet.
    private var cache: [String: String] = [:]
    /// Pending persistence per file: a text to write, or nil to delete.
    private var dirty: [String: String?] = [:]
    private var flushTask: Task<Void, Never>?

    private nonisolated static let log = Logger(subsystem: "com.gl11tchy.sigil", category: "notes")
    /// Keystrokes coalesce into one write per quiet window of this length.
    static let flushDelay: Duration = .milliseconds(300)

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
    }

    public static var defaultRoot: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Sigil/notes", isDirectory: true)
    }

    public func note(for sessionID: String, cwd: String) -> String {
        guard let url = fileURL(for: sessionID, cwd: cwd) else { return "" }
        if let cached = cache[url.path] { return cached }
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        cache[url.path] = text
        return text
    }

    public func setNote(_ text: String, for sessionID: String, cwd: String) {
        guard let url = fileURL(for: sessionID, cwd: cwd) else { return }
        if text.isEmpty {
            deleteNote(for: sessionID, cwd: cwd)
            return
        }
        cache[url.path] = text
        dirty[url.path] = text
        scheduleFlush()
    }

    public func deleteNote(for sessionID: String, cwd: String) {
        guard let url = fileURL(for: sessionID, cwd: cwd) else { return }
        cache.removeValue(forKey: url.path)
        // `.some(nil)`: a plain nil assignment removes the entry instead of
        // recording the delete.
        dirty[url.path] = .some(nil)
        scheduleFlush()
    }

    /// Writes and deletes everything outstanding, synchronously. Called on the
    /// quit path; the debounced writer keeps using detached I/O.
    public func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        persist(takePending(), detached: false)
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled, let self else { return }
            self.persist(self.takePending(), detached: true)
        }
    }

    private func takePending() -> (writes: [(url: URL, data: Data)], deletes: [URL]) {
        var writes: [(URL, Data)] = []
        var deletes: [URL] = []
        for (path, text) in dirty {
            let url = URL(fileURLWithPath: path)
            if let text {
                writes.append((url, Data(text.utf8)))
            } else {
                deletes.append(url)
            }
        }
        dirty.removeAll()
        return (writes, deletes)
    }

    private func persist(_ pending: (writes: [(url: URL, data: Data)], deletes: [URL]), detached: Bool) {
        guard !pending.writes.isEmpty || !pending.deletes.isEmpty else { return }
        let write: @Sendable () -> Void = {
            let fm = FileManager.default
            for (url, data) in pending.writes {
                do {
                    try fm.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    Self.log.error(
                        "note write failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            for url in pending.deletes {
                do { try fm.removeItem(at: url) } catch CocoaError.fileNoSuchFile {} catch {
                    Self.log.error(
                        "note delete failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        if detached {
            Task.detached(priority: .utility, operation: write)
        } else {
            write()
        }
    }

    /// `notes/<encoded-cwd>/<session-id>.md`, mirroring the CLI's own layout.
    /// Session IDs are UUIDs; refuse anything that could escape the folder or
    /// trip Unicode filename normalization.
    private func fileURL(for sessionID: String, cwd: String) -> URL? {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !sessionID.isEmpty,
            sessionID.rangeOfCharacter(from: allowed.inverted) == nil,
            !cwd.isEmpty
        else { return nil }
        return
            root
            .appendingPathComponent(GrokPaths.encode(path: GrokPaths.canonicalPath(cwd)))
            .appendingPathComponent(sessionID + ".md")
    }
}
