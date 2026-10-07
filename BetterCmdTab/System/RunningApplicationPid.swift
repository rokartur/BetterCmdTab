import AppKit
import Darwin
import os

extension NSRunningApplication {
    /// Use instead of `processIdentifier`, which macOS 27 reports as -1 for an app whose
    /// bundle executable execs another binary (the Emacs for Mac OS X launcher, #209).
    var pid: pid_t {
        let reported = processIdentifier
        guard reported == -1, let path = executableURL?.path, let launchDate else { return reported }
        let key = "\(path)@\(launchDate.timeIntervalSinceReferenceDate)"
        if let recovered = Self.recoveredPids.withLock({ $0[key] }) { return recovered }
        guard let found = Self.pidOfProcess(executablePath: path, startedNear: launchDate) else { return reported }
        Self.recoveredPids.withLock { $0[key] = found }
        return found
    }

    // A process-table scan costs ~1 ms and `pid` is read many times per ⌘Tab.
    // ponytail: entries outlive their process, one per launch of such an app; evict on termination if that ever adds up.
    private static let recoveredPids = OSAllocatedUnfairLock<[String: pid_t]>(initialState: [:])

    /// Several instances can share one executable (Parall, `open -n`), so the closest start wins.
    /// The 2 s window keeps an instance that quit before its first read from resolving to a live sibling.
    static func pidOfProcess(executablePath: String, startedNear launchDate: Date) -> pid_t? {
        let capacity = proc_listallpids(nil, 0) + 32
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size))
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var best: (pid: pid_t, distance: TimeInterval)?
        for pid in pids.prefix(Int(max(count, 0))) {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
                  String(cString: pathBuffer) == executablePath else { continue }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            let started = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            let distance = abs(started - launchDate.timeIntervalSince1970)
            guard distance < 2 else { continue }
            if let best, best.distance <= distance { continue }
            best = (pid, distance)
        }
        return best?.pid
    }
}
