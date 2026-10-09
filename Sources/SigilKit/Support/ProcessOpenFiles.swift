import Darwin
import Foundation

/// A PID alone can be reused. Capture the kernel birth identity while the
/// terminal still owns its newly spawned direct child.
public struct ChildProcessGeneration: Hashable, Sendable {
    let pid: pid_t
    let seconds: UInt64
    let microseconds: UInt64
    var startedAt: TimeInterval { Double(seconds) + Double(microseconds) / 1_000_000 }
}

/// Reads only an owned child and its descendants, never the process inventory.
/// Failed, partial or changing observations supply no identity evidence.
/// API/structure definitions: https://github.com/apple-oss-distributions/xnu/tree/main/libsyscall/wrappers/libproc
enum ProcessOpenFiles {
    struct FileIdentity: Hashable, Sendable {
        let path: String
        let device: UInt32
        let inode: UInt64
    }

    struct HeldFile: Hashable, Sendable {
        let identity: FileIdentity
        let writable: Bool
        let bornAt: TimeInterval
    }

    struct Node: Hashable, Sendable {
        let generation: ChildProcessGeneration
        let parent: pid_t
    }

    struct Snapshot: Equatable, Sendable {
        let nodes: Set<Node>
        let files: [FileIdentity: HeldFile]
    }

    /// The kernel boundary is replaceable for deterministic PID-reuse and
    /// permission-failure tests; production always uses the scoped libproc calls.
    struct Reader {
        var node: (pid_t) -> Node?
        var children: (pid_t) -> [pid_t]?
        var files: (pid_t, String) -> [FileIdentity: HeldFile]?
    }

    private static let processLimit = 64
    private static let descriptorLimit = 1024

    static func ownedChild(_ pid: pid_t) -> ChildProcessGeneration? {
        guard let node = node(pid), node.parent == getpid() else { return nil }
        return node.generation
    }

    static func snapshot(of child: ChildProcessGeneration, historyRoot: URL, reader: Reader? = nil) -> Snapshot? {
        let reader = reader ?? Reader(node: node, children: children, files: heldFiles)
        guard let root = reader.node(child.pid), root.generation == child, root.parent == getpid() else { return nil }
        let historyPath = GrokPaths.canonicalPath(historyRoot.path) + "/"
        var pending = [root]
        var nodes: Set<Node> = []
        var files: [FileIdentity: HeldFile] = [:]
        var childLists: [pid_t: Set<pid_t>] = [:]
        while let current = pending.popLast() {
            guard nodes.count < processLimit, nodes.insert(current).inserted,
                let held = reader.files(current.generation.pid, historyPath),
                let descendants = reader.children(current.generation.pid)
            else { return nil }
            files.merge(held) { old, new in old.writable ? old : new }
            childLists[current.generation.pid] = Set(descendants)
            for pid in descendants {
                guard let descendant = reader.node(pid), descendant.parent == current.generation.pid else { return nil }
                pending.append(descendant)
            }
        }
        // Recheck every generation and parent after the descriptor walk. An
        // exited/reused PID or a reparented descendant invalidates the snapshot.
        guard
            nodes.allSatisfy({ observed in
                guard reader.node(observed.generation.pid) == observed,
                    let children = reader.children(observed.generation.pid)
                else { return false }
                return Set(children) == childLists[observed.generation.pid]
            })
        else { return nil }
        return Snapshot(nodes: nodes, files: files)
    }

    private static func node(_ pid: pid_t) -> Node? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != SZOMB,
            info.pbi_start_tvsec > 0
        else { return nil }
        return Node(
            generation: ChildProcessGeneration(
                pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec),
            parent: pid_t(info.pbi_ppid))
    }

    private static func children(_ pid: pid_t) -> [pid_t]? {
        var buffer = [pid_t](repeating: 0, count: processLimit)
        let capacity = Int32(buffer.count * MemoryLayout<pid_t>.stride)
        errno = 0
        let count = proc_listchildpids(pid, &buffer, capacity)
        guard count >= 0, count < capacity, count % Int32(MemoryLayout<pid_t>.stride) == 0,
            count > 0 || errno == 0
        else { return nil }
        return Array(buffer.prefix(Int(count) / MemoryLayout<pid_t>.stride))
    }

    private static func heldFiles(_ pid: pid_t, below historyPath: String) -> [FileIdentity: HeldFile]? {
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: descriptorLimit)
        let capacity = Int32(buffer.count * MemoryLayout<proc_fdinfo>.stride)
        errno = 0
        let count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buffer, capacity)
        guard count >= 0, count < capacity, count % Int32(MemoryLayout<proc_fdinfo>.stride) == 0,
            count > 0 || errno == 0
        else { return nil }
        var files: [FileIdentity: HeldFile] = [:]
        for descriptor in buffer.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride)
        where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size
            else { return nil }
            guard
                let path = withUnsafeBytes(
                    of: info.pvip.vip_path,
                    { bytes in
                        String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
                    })
            else { return nil }
            let canonical = GrokPaths.canonicalPath(path)
            guard canonical.hasPrefix(historyPath), URL(fileURLWithPath: canonical).pathExtension == "jsonl" else {
                continue
            }
            let stat = info.pvip.vip_vi.vi_stat
            guard stat.vst_mode & S_IFMT == S_IFREG else { continue }
            let identity = FileIdentity(path: canonical, device: stat.vst_dev, inode: stat.vst_ino)
            let held = HeldFile(
                identity: identity, writable: info.pfi.fi_openflags & UInt32(FWRITE) != 0,
                bornAt: Double(stat.vst_birthtime) + Double(stat.vst_birthtimensec) / 1_000_000_000)
            if files[identity]?.writable != true { files[identity] = held }
        }
        return files
    }
}
