import AppKit

@MainActor
enum IconCache {
    private static let capacity = 64
    private static var cache: [pid_t: NSImage] = [:]
    private static var order: [pid_t] = []

    static func icon(for row: SwitcherRow) -> NSImage? {
        let pid = row.pid
        if let cached = cache[pid] {
            touch(pid)
            return cached
        }
        guard let image = row.app.icon else { return nil }
        cache[pid] = image
        order.append(pid)
        evictIfNeeded()
        return image
    }

    static func evict(_ pid: pid_t) {
        if cache.removeValue(forKey: pid) != nil {
            if let idx = order.firstIndex(of: pid) {
                order.remove(at: idx)
            }
        }
    }

    static func clear() {
        cache.removeAll()
        order.removeAll()
    }

    /// Eagerly populate icons for the given pids so the first reveal pays no
    /// `NSRunningApplication.icon` decode latency on the main thread. Safe to
    /// call repeatedly; existing entries are touched, missing entries fetched.
    static func prewarm(pids: [pid_t]) {
        let apps = NSWorkspace.shared.runningApplications
        let byPid = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        for pid in pids {
            guard cache[pid] == nil, let app = byPid[pid], let image = app.icon else { continue }
            cache[pid] = image
            order.append(pid)
        }
        evictIfNeeded()
    }

    private static func touch(_ pid: pid_t) {
        if let idx = order.firstIndex(of: pid) {
            order.remove(at: idx)
            order.append(pid)
        }
    }

    private static func evictIfNeeded() {
        while order.count > capacity {
            let victim = order.removeFirst()
            cache.removeValue(forKey: victim)
        }
    }
}
