import Darwin
import Foundation
import os

/// Child process host. Prefers a posix PTY; falls back to pipes when the
/// sandbox refuses the slave device. The child is spawned with `POSIX_SPAWN_SETSID`
/// so terminate can SIGTERM the whole process group.
final class HostedProcess {
    private(set) var pid: pid_t = 0
    private(set) var isRunning = false

    var onData: (@Sendable ([UInt8]) -> Void)?
    var onExit: (@Sendable (Int32?) -> Void)?
    var windowSize: () -> winsize = { winsize() }

    private var masterFD: Int32 = -1
    private var stdinFD: Int32 = -1
    private var io: DispatchIO?
    private var monitor: DispatchSourceProcess?
    private let readQueue = DispatchQueue(label: "GrokBuild.hosted-process.read")
    private let pending = PendingOutput()

    deinit {
        signalGroup()
        tearDownIO()
        monitor?.cancel()
        monitor = nil
    }

    func start(
        executable: String,
        args: [String],
        environment: [String],
        currentDirectory: String?
    ) {
        if isRunning { return }
        if startPty(
            executable: executable,
            args: args,
            environment: environment,
            currentDirectory: currentDirectory
        ) {
            return
        }
        startPipes(
            executable: executable,
            args: args,
            environment: environment,
            currentDirectory: currentDirectory
        )
    }

    func send(_ data: ArraySlice<UInt8>) {
        guard isRunning else { return }
        let fd = stdinFD >= 0 ? stdinFD : masterFD
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, !raw.isEmpty else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    func terminate() {
        signalGroup()
        tearDownIO()
        isRunning = false
    }

    func setWindowSize(_ size: winsize) {
        guard masterFD >= 0 else { return }
        var window = size
        _ = ioctl(masterFD, TIOCSWINSZ, &window)
    }

    private func startPty(
        executable: String,
        args: [String],
        environment: [String],
        currentDirectory: String?
    ) -> Bool {
        guard let pair = Self.openPtyPair() else { return false }
        var size = windowSize()
        _ = ioctl(pair.master, TIOCSWINSZ, &size)
        let spawned = spawn(
            executable: executable,
            args: args,
            environment: environment,
            currentDirectory: currentDirectory,
            childStdin: pair.slave,
            childStdout: pair.slave,
            childStderr: pair.slave,
            closeInChild: [pair.master],
            closeInParent: [pair.slave]
        )
        guard spawned else {
            close(pair.master)
            close(pair.slave)
            return false
        }
        masterFD = pair.master
        stdinFD = pair.master
        armIO(on: pair.master)
        return true
    }

    private func startPipes(
        executable: String,
        args: [String],
        environment: [String],
        currentDirectory: String?
    ) {
        var stdinPipe = [Int32](repeating: 0, count: 2)
        var stdoutPipe = [Int32](repeating: 0, count: 2)
        guard stdinPipe.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0 else { return }
        guard stdoutPipe.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0 else {
            close(stdinPipe[0]); close(stdinPipe[1])
            return
        }
        let spawned = spawn(
            executable: executable,
            args: args,
            environment: environment,
            currentDirectory: currentDirectory,
            childStdin: stdinPipe[0],
            childStdout: stdoutPipe[1],
            childStderr: stdoutPipe[1],
            closeInChild: [stdinPipe[1], stdoutPipe[0]],
            closeInParent: [stdinPipe[0], stdoutPipe[1]]
        )
        guard spawned else {
            close(stdinPipe[0]); close(stdinPipe[1])
            close(stdoutPipe[0]); close(stdoutPipe[1])
            return
        }
        stdinFD = stdinPipe[1]
        masterFD = stdoutPipe[0]
        armIO(on: stdoutPipe[0])
    }

    private func spawn(
        executable: String,
        args: [String],
        environment: [String],
        currentDirectory: String?,
        childStdin: Int32,
        childStdout: Int32,
        childStderr: Int32,
        closeInChild: [Int32],
        closeInParent: [Int32]
    ) -> Bool {
        var argv = args
        if argv.first != executable {
            argv.insert(executable, at: 0)
        }
        guard let cArgs = CStringArray(argv), let cEnv = CStringArray(environment) else {
            return false
        }

        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_adddup2(&actions, childStdin, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, childStdout, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, childStderr, STDERR_FILENO)
        for fd in closeInChild {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        if childStdin > 2 { posix_spawn_file_actions_addclose(&actions, childStdin) }
        if childStdout > 2 && childStdout != childStdin {
            posix_spawn_file_actions_addclose(&actions, childStdout)
        }
        if childStderr > 2 && childStderr != childStdin && childStderr != childStdout {
            posix_spawn_file_actions_addclose(&actions, childStderr)
        }
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory)
        }

        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attr, cArgs.base, cEnv.base)
        guard rc == 0 else { return false }

        for fd in closeInParent { close(fd) }
        pid = child
        isRunning = true
        armExitMonitor()
        return true
    }

    private func armIO(on fd: Int32) {
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: readQueue) { _ in
            close(fd)
        }
        self.io = io
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: 64 * 1024, queue: readQueue) { [weak self] done, data, _ in
            self?.handleRead(done: done, data: data)
        }
    }

    private func handleRead(done: Bool, data: DispatchData?) {
        if let data, data.count > 0 {
            var bytes = [UInt8](repeating: 0, count: data.count)
            bytes.withUnsafeMutableBytes { dest in
                data.copyBytes(to: dest, from: 0..<data.count)
            }
            enqueue(bytes)
        } else if done {
            return
        }
        // Re-arm only when this read op finished. Partial deliveries use
        // done=false; starting another op then would stack read chains.
        if done, isRunning {
            io?.read(offset: 0, length: 64 * 1024, queue: readQueue) { [weak self] done, data, _ in
                self?.handleRead(done: done, data: data)
            }
        }
    }

    private func enqueue(_ bytes: [UInt8]) {
        let callback = onData
        let box = pending
        if box.append(bytes) {
            DispatchQueue.main.async {
                callback?(box.take())
            }
        }
    }

    private func armExitMonitor() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.reap()
        }
        source.activate()
        monitor = source
    }

    private func reap() {
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)
        isRunning = false
        monitor?.cancel()
        monitor = nil
        onExit?(status)
    }

    private func signalGroup() {
        guard pid > 0 else { return }
        if getpgid(pid) == pid {
            kill(-pid, SIGTERM)
        }
        kill(pid, SIGTERM)
    }

    private func tearDownIO() {
        let stdin = stdinFD
        let master = masterFD
        stdinFD = -1
        masterFD = -1
        io?.close()
        io = nil
        if stdin >= 0 && stdin != master {
            close(stdin)
        }
    }

    private static func openPtyPair() -> (master: Int32, slave: Int32)? {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { return nil }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            close(master)
            return nil
        }
        guard let name = ptsname(master) else {
            close(master)
            return nil
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            return nil
        }
        return (master, slave)
    }
}

/// Lock-protected output coalescer. `append` returns true when the caller
/// should schedule a main-queue drain.
private final class PendingOutput: Sendable {
    private struct State {
        var chunks: [[UInt8]] = []
        var scheduled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ bytes: [UInt8]) -> Bool {
        state.withLock { state in
            state.chunks.append(bytes)
            if state.scheduled { return false }
            state.scheduled = true
            return true
        }
    }

    func take() -> [UInt8] {
        state.withLock { state in
            var merged: [UInt8] = []
            merged.reserveCapacity(state.chunks.reduce(0) { $0 + $1.count })
            for chunk in state.chunks { merged.append(contentsOf: chunk) }
            state.chunks.removeAll(keepingCapacity: true)
            state.scheduled = false
            return merged
        }
    }
}

/// Null-terminated C string vector that lives until `posix_spawn` returns.
private final class CStringArray {
    let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init?(_ strings: [String]) {
        base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        var ready = 0
        for (index, string) in strings.enumerated() {
            guard let copy = strdup(string) else {
                for i in 0..<ready { free(base[i]) }
                base.deallocate()
                return nil
            }
            base[index] = copy
            ready += 1
        }
        base[strings.count] = nil
        count = strings.count
    }

    deinit {
        for i in 0..<count { free(base[i]) }
        base.deallocate()
    }
}
