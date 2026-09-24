import Darwin

extension TerminalController {
    /// True while a command started from this shell holds the terminal, for
    /// example `npm run dev` or `vim`. False at the shell prompt.
    public var hasForegroundJob: Bool {
        let pid = processID
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        let foreground = info.kp_eproc.e_tpgid
        return foreground > 0 && foreground != info.kp_eproc.e_pgid
    }
}
