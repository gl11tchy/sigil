import CoreServices
import Foundation
import os

/// Recursive FSEvents watcher. `stop()` is safe from any isolation, including `deinit`.
final class SessionDirectoryWatcher: Sendable {
    enum Contents: Sendable {
        case grokSummaries
        /// Native transcripts are under `root`; Codex's title index is beside it.
        case nativeHistory(root: URL, titleIndex: URL?)
        /// Markdown notes, including atomic replacements and deleted parents.
        case notes(root: URL)
        /// Only project identity and Git markers affect the sidebar's grouping/filter.
        case sidebarPaths(Set<String>)
    }

    /// `FSEventStreamRef` is not Sendable; keep the handle as a bit pattern under the lock.
    private struct StreamState: Sendable {
        var generation: UInt64 = 0
        var streamBits: UInt = 0
        var sink: EventSink?
    }

    private let state = OSAllocatedUnfairLock(initialState: StreamState())

    @discardableResult
    func start(
        path: String,
        latency: CFTimeInterval = 1.0,
        contents: Contents = .grokSummaries,
        handler: @escaping @Sendable (_ requiresRestart: Bool) -> Void
    ) -> Bool {
        start(paths: [path], latency: latency, contents: contents, handler: handler)
    }

    @discardableResult
    func start(
        paths: [String], latency: CFTimeInterval,
        contents: Contents, handler: @escaping @Sendable (Bool) -> Void
    ) -> Bool {
        let replacement = state.withLock { current -> (UInt64, UInt, EventSink?) in
            current.generation &+= 1
            let old = (current.generation, current.streamBits, current.sink)
            current.streamBits = 0
            current.sink = nil
            return old
        }
        dispose(streamBits: replacement.1, sink: replacement.2)

        let roots = Set(
            paths.compactMap { path -> String? in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { return nil }
                return Self.canonicalURL(URL(fileURLWithPath: path)).path
            })
        guard !roots.isEmpty else { return false }

        let sink = EventSink(contents: contents, handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventSink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventSink>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard
            let stream = FSEventStreamCreate(
                nil,
                sessionFSEventCallback,
                &context,
                Array(roots) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        else {
            return false
        }

        FSEventStreamSetDispatchQueue(
            stream,
            DispatchQueue(label: "Sigil.SessionStore.FSEvents")
        )
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }

        let bits = UInt(bitPattern: stream)
        let installed = state.withLock { current -> Bool in
            guard current.generation == replacement.0, current.streamBits == 0 else {
                return false
            }
            current.streamBits = bits
            current.sink = sink
            return true
        }
        guard installed else {
            dispose(streamBits: bits, sink: sink)
            return false
        }
        return true
    }

    func stop() {
        let taken = state.withLock { current -> (UInt, EventSink?) in
            let old = (current.streamBits, current.sink)
            current.generation &+= 1
            current.streamBits = 0
            current.sink = nil
            return old
        }
        dispose(streamBits: taken.0, sink: taken.1)
    }

    private func dispose(streamBits: UInt, sink: EventSink?) {
        sink?.disarm()
        guard streamBits != 0, let stream = FSEventStreamRef(bitPattern: streamBits) else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }

    /// Grok summaries and native transcripts use distinct refresh policies.
    static func shouldScan(
        path: String, flags: FSEventStreamEventFlags, contents: Contents = .grokSummaries
    ) -> Bool {
        if requiresRestart(flags) { return true }
        let directoryEvent =
            flags
            & FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir) != 0
        switch contents {
        case .sidebarPaths(let paths):
            let event = URL(fileURLWithPath: path).path
            return paths.contains(event)
                || (directoryEvent && paths.contains { $0.hasPrefix(event + "/") })
        case .notes(let root):
            let event = canonicalURL(URL(fileURLWithPath: path)).path
            let root = canonicalURL(root).path
            if directoryEvent {
                return event == root || event.hasPrefix(root + "/") || root.hasPrefix(event + "/")
            }
            return event.hasPrefix(root + "/") && URL(fileURLWithPath: path).pathExtension == "md"
        case .grokSummaries:
            // Journals and lock files churn constantly; only summaries feed Grok history.
            return directoryEvent || URL(fileURLWithPath: path).lastPathComponent == "summary.json"
        case .nativeHistory(let root, let titleIndex):
            guard directoryEvent || URL(fileURLWithPath: path).pathExtension == "jsonl" else { return false }
            // FSEvents may report canonical paths even when the configured root is a symlink.
            let event = canonicalURL(URL(fileURLWithPath: path)).path
            let root = canonicalURL(root).path
            let index = titleIndex.map(canonicalURL)?.path
            if directoryEvent {
                // A coalesced ancestor can hide changes below it, but unrelated
                // Codex home directories must not trigger a history scan.
                return event == root || event.hasPrefix(root + "/") || root.hasPrefix(event + "/")
                    || index.map { $0.hasPrefix(event + "/") } == true
            }
            return event.hasPrefix(root + "/") || event == index
        }
    }

    static func decision(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        contents: Contents = .grokSummaries
    ) -> (scan: Bool, restart: Bool) {
        var scan = false
        var restart = false
        let count = min(paths.count, flags.count)
        for index in 0..<count {
            if requiresRestart(flags[index]) { restart = true }
            if shouldScan(path: paths[index], flags: flags[index], contents: contents) { scan = true }
        }
        if restart { scan = true }
        return (scan, restart)
    }

    static func requiresRestart(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & restartMask != 0
    }

    /// Resolving a deleted file directly leaves aliases such as /var unresolved.
    /// Resolve its nearest existing ancestor, then restore the missing suffix.
    static func canonicalURL(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }

    fileprivate static let restartMask =
        FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
}

private final class EventSink: Sendable {
    let contents: SessionDirectoryWatcher.Contents
    private let handler: OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>

    init(contents: SessionDirectoryWatcher.Contents, handler: @escaping @Sendable (Bool) -> Void) {
        self.contents = contents
        self.handler = OSAllocatedUnfairLock(initialState: handler)
    }

    func fire(requiresRestart: Bool) {
        handler.withLock { $0 }?(requiresRestart)
    }

    func disarm() {
        handler.withLock { $0 = nil }
    }
}

private let sessionFSEventCallback: FSEventStreamCallback = {
    _, info, eventCount, eventPaths, eventFlags, _ in
    guard let info else { return }
    let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
    let paths = fsEventPaths(eventPaths, count: eventCount)
    var flags: [FSEventStreamEventFlags] = []
    flags.reserveCapacity(eventCount)
    for index in 0..<eventCount {
        flags.append(eventFlags[index])
    }
    let decision: (scan: Bool, restart: Bool)
    if paths.count == eventCount {
        decision = SessionDirectoryWatcher.decision(paths: paths, flags: flags, contents: sink.contents)
    } else {
        // Path list missing: keep the old "any event scans" behavior.
        let restart = flags.contains { SessionDirectoryWatcher.requiresRestart($0) }
        decision = (true, restart)
    }
    guard decision.scan else { return }
    sink.fire(
        requiresRestart: decision.restart
    )
}

private func fsEventPaths(_ eventPaths: UnsafeMutableRawPointer, count: Int) -> [String] {
    let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    let paths = array.compactMap { $0 as? String }
    return paths.count == count ? paths : []
}
