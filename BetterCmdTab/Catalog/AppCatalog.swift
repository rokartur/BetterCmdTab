import AppKit

/// Synchronous `concurrentPerform` output where iteration `i` owns exactly slot
/// `i`. Swift's `UnsafeMutableBufferPointer` is conservatively non-Sendable even
/// though disjoint initialized elements are independent memory locations. This
/// wrapper contains that invariant; it must never be used for overlapping slots
/// or after the enclosing `withUnsafeMutableBufferPointer` returns.
struct DisjointWriteBuffer<Element>: @unchecked Sendable {
    private let baseAddress: UnsafeMutablePointer<Element>
    let count: Int

    init(_ buffer: UnsafeMutableBufferPointer<Element>) {
        precondition(!buffer.isEmpty && buffer.baseAddress != nil)
        baseAddress = buffer.baseAddress!
        count = buffer.count
    }

    func set(_ value: Element, at index: Int) {
        precondition(index >= 0 && index < count)
        baseAddress.advanced(by: index).pointee = value
    }
}

enum AppCatalog {
    /// `filter` lets a per-shortcut override (#74) replace the global filter;
    /// `nil` (the default) reads the global config, keeping existing callers
    /// byte-identical.
    static func fastAppList(orderedBy mru: [pid_t], filter cfg: CatalogFilter.Config? = nil, windowedPids: Set<pid_t>? = nil) -> [NSRunningApplication] {
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
        return CatalogFilter.filteredApps(ordered, cfg ?? CatalogFilter.config(), windowedPids: windowedPids)
    }

    static func snapshot(orderedBy mru: [pid_t], filter cfg: CatalogFilter.Config? = nil) -> [SwitcherRow] {
        let resolvedCfg = cfg ?? CatalogFilter.config()
        // Self is intentionally included: BetterCmdTab should appear in the
        // switcher when — and only when — it has a real standard window open
        // (the Settings window). The switcher panel is a borderless
        // non-activating NSPanel whose AX subrole isn't Standard/Dialog, so
        // WindowEnumerator filters it out; with no window the accessory-app
        // rule below drops self entirely.
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular || app.activationPolicy == .accessory
        }

        let count = candidates.count
        guard count > 0 else { return [] }

        let cgSnapshot = WindowEnumerator.snapshotCGWindowMap()

        var windowsBuffer: [[WindowInfo]] = Array(repeating: [], count: count)
        windowsBuffer.withUnsafeMutableBufferPointer { buffer in
            let output = DisjointWriteBuffer(buffer)
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let app = candidates[i]
                let pid = app.processIdentifier
                output.set(WindowEnumerator.windows(
                    forPid: pid,
                    isRegularApp: app.activationPolicy == .regular,
                    expectedCGWindowIDs: cgSnapshot.ids(for: pid),
                    cgZOrder: cgSnapshot.zOrder(for: pid),
                    nonNormalLayerWids: cgSnapshot.nonNormalLayer(for: pid),
                    onscreenWids: cgSnapshot.onscreen(for: pid)
                ), at: i)
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
                    rows.append(SwitcherRow.from(app: entry.app, window: win))
                }
            }
        }

        // Compute each row's status bucket once — `statusPriority` reads the
        // live `app.isHidden` (an ObjC call) — then sort the precomputed keys.
        // The old comparator called it twice per comparison (O(n log n) ObjC
        // queries); decorating up front makes it O(n). Tie-break on the
        // original offset keeps the order byte-identical to before.
        let sorted = rows.enumerated()
            .map { (priority: Self.statusPriority($0.element, sinkHiddenApps: resolvedCfg.sinkHiddenApps), offset: $0.offset, row: $0.element) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.offset < rhs.offset
            }
            .map { $0.row }
        return CatalogFilter.filteredRows(sorted, resolvedCfg)
    }

    private static func statusPriority(_ row: SwitcherRow, sinkHiddenApps: Bool) -> Int {
        // Mirror AppCatalogCache.statusPriority so cold and cached snapshots
        // agree on ordering; see there for the bucketing rationale.
        if row.window == nil, !row.isPlaceholder { return 2 }
        if sinkHiddenApps, row.isHidden { return 2 }
        if row.isMinimized { return 1 }
        return 0
    }
}
