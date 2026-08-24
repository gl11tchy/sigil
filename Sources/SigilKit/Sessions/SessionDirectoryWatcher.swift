import CoreServices
import Foundation
import os

/// Recursive FSEvents watcher. `stop()` is safe from any isolation, including `deinit`.
final class SessionDirectoryWatcher: Sendable {
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
        handler: @escaping @Sendable (_ requiresRestart: Bool) -> Void
    ) -> Bool {
        let replacement = state.withLock { current -> (UInt64, UInt, EventSink?) in
            current.generation &+= 1
            let old = (current.generation, current.streamBits, current.sink)
            current.streamBits = 0
            current.sink = nil
            return old
        }
        dispose(streamBits: replacement.1, sink: replacement.2)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return false
        }

        let sink = EventSink(handler: handler)
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
                [path] as CFArray,
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
}

private final class EventSink: Sendable {
    private let handler: OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>

    init(handler: @escaping @Sendable (Bool) -> Void) {
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
    _, info, eventCount, _, eventFlags, _ in
    guard let info else { return }
    let restartMask =
        FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
    var requiresRestart = false
    for index in 0..<eventCount where eventFlags[index] & restartMask != 0 {
        requiresRestart = true
        break
    }
    Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue().fire(
        requiresRestart: requiresRestart
    )
}
