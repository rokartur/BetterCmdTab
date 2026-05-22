import AppKit

enum AppCatalog {
    static func fastAppList(orderedBy mru: [pid_t]) -> [NSRunningApplication] {
        let selfPid = getpid()
        let regulars = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPid }
        let byPid = Dictionary(uniqueKeysWithValues: regulars.map { ($0.processIdentifier, $0) })

        var ordered: [NSRunningApplication] = []
        ordered.reserveCapacity(regulars.count)
        var seen = Set<pid_t>()
        for pid in mru {
            if let app = byPid[pid] {
                ordered.append(app)
                seen.insert(pid)
            }
        }
        for app in regulars where !seen.contains(app.processIdentifier) {
            ordered.append(app)
        }
        return ordered
    }

    static func snapshot(orderedBy mru: [pid_t]) -> [SwitcherRow] {
        let selfPid = getpid()
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != selfPid else { return false }
            return app.activationPolicy == .regular || app.activationPolicy == .accessory
        }

        let count = candidates.count
        guard count > 0 else { return [] }

        let cgMap = WindowEnumerator.snapshotCGWindowMap()

        var windowsBuffer: [[WindowInfo]] = Array(repeating: [], count: count)
        windowsBuffer.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let app = candidates[i]
                let pid = app.processIdentifier
                buffer[i] = WindowEnumerator.windows(
                    forPid: pid,
                    isRegularApp: app.activationPolicy == .regular,
                    expectedCGWindowIDs: cgMap[pid] ?? []
                )
            }
        }

        var enriched: [(app: NSRunningApplication, windows: [WindowInfo])] = []
        enriched.reserveCapacity(count)
        for i in 0..<count {
            let app = candidates[i]
            let windows = windowsBuffer[i]
            if app.activationPolicy == .regular {
                enriched.append((app: app, windows: windows))
            } else if app.activationPolicy == .accessory, !windows.isEmpty {
                enriched.append((app: app, windows: windows))
            }
        }

        let byPid = Dictionary(uniqueKeysWithValues: enriched.map { ($0.app.processIdentifier, $0) })

        var ordered: [(app: NSRunningApplication, windows: [WindowInfo])] = []
        ordered.reserveCapacity(enriched.count)
        var seen = Set<pid_t>()
        for pid in mru {
            if let entry = byPid[pid] {
                ordered.append(entry)
                seen.insert(pid)
            }
        }
        for entry in enriched where !seen.contains(entry.app.processIdentifier) {
            ordered.append(entry)
        }

        var rows: [SwitcherRow] = []
        rows.reserveCapacity(ordered.count * 2)

        for entry in ordered {
            if entry.windows.isEmpty {
                rows.append(SwitcherRow(
                    app: entry.app,
                    window: nil,
                    windowTitle: "",
                    isMinimized: false
                ))
            } else {
                for win in entry.windows {
                    rows.append(SwitcherRow(
                        app: entry.app,
                        window: win.ref,
                        windowTitle: win.title,
                        isMinimized: win.isMinimized,
                        isFullscreen: win.isFullscreen
                    ))
                }
            }
        }

        return rows.enumerated().sorted { lhs, rhs in
            let pa = Self.statusPriority(lhs.element)
            let pb = Self.statusPriority(rhs.element)
            if pa != pb { return pa < pb }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    private static func statusPriority(_ row: SwitcherRow) -> Int {
        if row.app.isHidden { return 2 }
        if row.isMinimized { return 1 }
        return 0
    }
}
