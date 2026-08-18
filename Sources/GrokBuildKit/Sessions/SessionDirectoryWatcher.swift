import CoreServices
import Foundation
import os

/// Recursive FSEvents watcher. `stop()` is safe from any isolation, including `deinit`.
final class SessionDirectoryWatcher: Sendable {
    /// `FSEventStreamRef` is not Sendable; keep the handle as a bit pattern under the lock.
    private struct StreamState: Sendable {
        var streamBits: UInt = 0
        var sink: EventSink?
    }

    private let state = OSAllocatedUnfairLock(initialState: StreamState())

    func start(path: String, latency: CFTimeInterval = 1.0, handler: @escaping @Sendable () -> Void)
    {
        stop()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return
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
            return
        }

        FSEventStreamSetDispatchQueue(
            stream,
            DispatchQueue(label: "GrokBuild.SessionStore.FSEvents")
        )
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }

        let bits = UInt(bitPattern: stream)
        state.withLock {
            $0.streamBits = bits
            $0.sink = sink
        }
    }

    func stop() {
        let taken = state.withLock { current -> (UInt, EventSink?) in
            let old = (current.streamBits, current.sink)
            current = StreamState()
            return old
        }
        taken.1?.disarm()
        guard taken.0 != 0, let stream = FSEventStreamRef(bitPattern: taken.0) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }
}

private final class EventSink: Sendable {
    private let handler: OSAllocatedUnfairLock<(@Sendable () -> Void)?>

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = OSAllocatedUnfairLock(initialState: handler)
    }

    func fire() {
        handler.withLock { $0 }?()
    }

    func disarm() {
        handler.withLock { $0 = nil }
    }
}

private let sessionFSEventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
    guard let info else { return }
    Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue().fire()
}
