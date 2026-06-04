import AppKit
import ApplicationServices
import CoreGraphics
import os

struct WindowInfo {
    let ref: AXUIElement
    /// WindowServer id of this window, resolved once during the scan. The stable
    /// identity across AX element churn — used for z-order ranking, MRU, and
    /// matching a window across refreshes without re-querying `_AXUIElementGetWindow`.
    let cgWindowID: CGWindowID
    let title: String
    let isMinimized: Bool
    let isFullscreen: Bool
    /// In-content `AXTabs` children of this window (the deep tab strip some apps
    /// expose, e.g. via an `AXTabGroup`). Empty for the common case — most apps,
    /// including Finder/Terminal/TextEdit, do NOT expose this. Native window
    /// tabs are represented by `tabWindows` instead.
    let tabs: [AXUIElement]
    /// Native macOS window-tab siblings, when this is the collapsed front tab of
    /// a group (Finder/Terminal/TextEdit/Ghostty/…). Each entry is a real
    /// NSWindow (own title + CGWindowID) at the same on-screen frame; raising
    /// one selects that tab. Includes this window itself, in tab order. Empty
    /// for an ordinary single window and whenever "expand tabs as windows" is on
    /// (each tab is then its own `WindowInfo`).
    let tabWindows: [TabWindowRef]

    init(
        ref: AXUIElement,
        cgWindowID: CGWindowID = 0,
        title: String,
        isMinimized: Bool,
        isFullscreen: Bool = false,
        tabs: [AXUIElement] = [],
        tabWindows: [TabWindowRef] = []
    ) {
        self.ref = ref
        self.cgWindowID = cgWindowID
        self.title = title
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.tabs = tabs
        self.tabWindows = tabWindows
    }
}

/// One window in a native macOS window-tab group. Each tab is a distinct
/// NSWindow — own AX element, title, and CGWindowID — sharing the group's
/// on-screen frame; AX exposes only the front tab, the others are recovered by
/// the brute-force scan. Raising a tab's window selects that tab.
struct TabWindowRef {
    let ref: AXUIElement
    let title: String
    let cgWindowID: CGWindowID
}

/// Hashable wrapper around `AXUIElement` whose equality follows the CF identity
/// contract (`CFEqual`), not raw pointer or `CFHash` integer comparison. Use
/// this as a dictionary key when the value semantically belongs to a specific
/// AX element — CFHash alone is non-unique across distinct elements and would
/// silently collide.
struct AXRef: Hashable {
    let element: AXUIElement
    static func == (lhs: AXRef, rhs: AXRef) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Per-pid window inventory captured from `CGWindowListCopyWindowInfo`.
/// `ids` is the membership set used to confirm AX scan coverage; `zOrder`
/// preserves the front-to-back ordering returned by WindowServer so we can
/// surface windows in the switcher in the same order the user sees them
/// stacked on screen instead of whatever arbitrary order AX returns.
struct CGWindowSnapshot {
    let ids: [pid_t: Set<CGWindowID>]
    let zOrder: [pid_t: [CGWindowID]]

    static let empty = CGWindowSnapshot(ids: [:], zOrder: [:])

    func ids(for pid: pid_t) -> Set<CGWindowID> { ids[pid] ?? [] }
    func zOrder(for pid: pid_t) -> [CGWindowID] { zOrder[pid] ?? [] }
}

enum WindowEnumerator {
    /// 1024 covers fullscreen windows that get allocated late in the AX
    /// element id space. With CG hint + early-exit the scan typically stops
    /// well before this cap.
    private static let bruteForceLimit: UInt64 = 1024
    /// Consecutive brute-scan ids allowed past the last newly-accepted window
    /// before giving up. Guards the case where the CG hint contains a window id
    /// the AX API can never resolve to an element (layer-0 composited overlays
    /// etc.): the `isSubset` early-exit can then never fire, so without this
    /// bound the loop probes all 1024 ids — each a ~0.025s AX IPC, up to ~25s
    /// pinning a core, on every refresh/bump for that pid. AX ids for one app's
    /// windows cluster tightly, so 256 is far above any real inter-window gap;
    /// the budget only counts the *trailing* run after the last accept and
    /// resets on every hit, so sparse-but-valid (and late-allocated fullscreen)
    /// ids are never cut off — only an unbounded unresolvable tail is.
    private static let bruteForceStaleBudget: UInt64 = 256
    private static let preFilterTimeout: Float = 0.025
    private static let confirmedTimeout: Float = 0.2

    /// Snapshot of every window grouped by owner pid via the public
    /// `CGWindowListCopyWindowInfo` API. Uses `.optionAll` (not
    /// `.optionOnScreenOnly`) so fullscreen windows living on their own
    /// Spaces are included — they're invisible from the current Space and
    /// would otherwise drop out of the hint set, causing the brute scan to
    /// miss them entirely.
    ///
    /// The returned snapshot preserves WindowServer z-order per pid so
    /// callers can sort their AX results by what the user actually sees,
    /// rather than the arbitrary order `kAXWindowsAttribute` exposes.
    static func snapshotCGWindowMap() -> CGWindowSnapshot {
        let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        // Cast to `[NSDictionary]`, not `[[String: Any]]`: the entries stay
        // toll-free-bridged CFDictionaries (no per-window Swift dictionary
        // allocated, no eager bridge of the ~10 keys we never read). Only the
        // 5 fields below get bridged, on access. This runs on the cold-reveal
        // full-scan path and on every coalesced bump, so the saved allocations
        // add up.
        guard let cfArray = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [NSDictionary] else {
            return .empty
        }
        var ids: [pid_t: Set<CGWindowID>] = [:]
        var zOrder: [pid_t: [CGWindowID]] = [:]
        for entry in cfArray {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            if layer != 0 { continue }
            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha <= 0 { continue }
            guard let widNum = entry[kCGWindowNumber as String] as? Int else { continue }
            let wid = CGWindowID(widNum)
            if let bounds = entry[kCGWindowBounds as String] as? NSDictionary {
                let w = (bounds["Width"] as? Double) ?? 0
                let h = (bounds["Height"] as? Double) ?? 0
                if w < 100 || h < 100 { continue }
            }
            if ids[ownerPID, default: []].insert(wid).inserted {
                zOrder[ownerPID, default: []].append(wid)
            }
        }
        return CGWindowSnapshot(ids: ids, zOrder: zOrder)
    }

    /// Back-compat entry point for the cold full-catalog paths (`AppCatalog`,
    /// `AppCatalogCache.computeEntries`) that don't carry a per-pid coverage
    /// memo. Discards the uncoverable-wid set `enumerate` returns. The hot
    /// incremental path (`AppCatalogCache.bumpApps`) calls `enumerate` directly
    /// to thread the memo that suppresses the repeat brute scan.
    static func windows(
        forPid pid: pid_t,
        isRegularApp: Bool = true,
        expectedCGWindowIDs: Set<CGWindowID> = [],
        cgZOrder: [CGWindowID] = []
    ) -> [WindowInfo] {
        enumerate(
            forPid: pid,
            isRegularApp: isRegularApp,
            expectedCGWindowIDs: expectedCGWindowIDs,
            cgZOrder: cgZOrder
        ).windows
    }

    /// Whether the brute-force AX token scan is worth running. True only for a
    /// regular app whose CG hint still has a *coverable* window the AX
    /// windows-list pass missed: wids already proven AX-unresolvable
    /// (`knownUncoverable`, memoized by a prior full sweep) are subtracted
    /// first, so a permanently-unresolvable surface (HUD/NSPanel/sheet sized
    /// like a window) can no longer force a fresh 256-id sweep on every refresh.
    /// Pure — the testable decision seam. Empty hint ⇒ false (nothing to find).
    static func needsBruteScan(
        isRegularApp: Bool,
        expectedCGWindowIDs: Set<CGWindowID>,
        coveredWids: Set<CGWindowID>,
        knownUncoverable: Set<CGWindowID>
    ) -> Bool {
        guard isRegularApp else { return false }
        return !expectedCGWindowIDs.subtracting(knownUncoverable).isSubset(of: coveredWids)
    }

    /// CG-hint wids a full sweep could not resolve to an accepted AX window —
    /// the set memoized so the next refresh skips re-discovering the same gap.
    /// Self-pruning: a wid that leaves the CG hint (surface closed) or that AX
    /// later does resolve simply drops out next time this is recomputed.
    static func uncoverableWids(
        expectedCGWindowIDs: Set<CGWindowID>,
        coveredWids: Set<CGWindowID>
    ) -> Set<CGWindowID> {
        expectedCGWindowIDs.subtracting(coveredWids)
    }

    /// Full per-pid window enumeration. Returns the windows plus the
    /// `uncoverableWids` the caller should memoize (keyed on this same
    /// `expectedCGWindowIDs`) to short-circuit `needsBruteScan` next time.
    static func enumerate(
        forPid pid: pid_t,
        isRegularApp: Bool = true,
        expectedCGWindowIDs: Set<CGWindowID> = [],
        cgZOrder: [CGWindowID] = [],
        knownUncoverable: Set<CGWindowID> = []
    ) -> (windows: [WindowInfo], uncoverable: Set<CGWindowID>) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.confirmedTimeout)

        var elements: [AXUIElement] = []
        var seenByElement = Set<AXRef>()
        var seenByWid = Set<CGWindowID>()
        // Remember each accepted element's WindowServer id so the build pass can
        // stamp `WindowInfo.cgWindowID` without a second `_AXUIElementGetWindow`.
        var widByElement: [AXRef: CGWindowID] = [:]

        func appendIfNew(_ e: AXUIElement) {
            let ref = AXRef(element: e)
            if seenByElement.contains(ref) { return }
            let wid = PrivateAPI.cgWindowId(of: e)
            // Drop AX elements without a WindowServer id. Two cases produce
            // this and neither belongs in the switcher: (1) a window mid-
            // destruction — after `kAXCloseAction` / pressing the close
            // button, `kAXWindowsAttribute` still lists the dying element
            // for ~100–300ms while `_AXUIElementGetWindow` already returns 0.
            // Letting these through caused the just-closed row to flash back
            // on the next cache refresh. (2) Pre-registered windows that have
            // not yet been promoted to a real CG window — also not user-
            // actionable. The brute-force scan already enforced this; the
            // AX-windows-list path silently didn't, which is the asymmetry
            // that allowed the flicker. Keep both paths consistent.
            guard wid != 0 else { return }
            if seenByWid.contains(wid) { return }
            seenByWid.insert(wid)
            seenByElement.insert(ref)
            widByElement[ref] = wid
            elements.append(e)
        }

        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let axWindows = windowsValue as? [AXUIElement] {
            for w in axWindows { appendIfNew(w) }
        }

        // Snapshot which elements the app's own window list exposed, before the
        // brute scan runs. This is the discriminator for native window tabs:
        // AppKit lists only the FRONT tab of a group, so any window the brute
        // scan recovers at the same frame as an AX-listed window is a background
        // tab — never a genuinely separate window (two real overlapping windows
        // are both in the AX list). Drives collapse/expand below.
        let axListRefs = seenByElement

        // Skip brute-force AX scan when the CG window list says AX already has
        // every on-screen window covered. Apps with no CG-AX gap (the common
        // case) pay zero brute-scan cost.
        // An empty CG hint means WindowServer reported no qualifying on-screen
        // windows for this pid (the snapshot uses `.optionAll`, so fullscreen and
        // other-Space windows are already covered). The brute-force token scan
        // would only rediscover windows that have a CGWindowID, so there is
        // nothing for it to find — skip it instead of probing 1024 ids for
        // nothing. Brute-scan stays gated to the real case: a CG hint the AX
        // window list didn't fully cover.
        let needBruteScan = needsBruteScan(
            isRegularApp: isRegularApp,
            expectedCGWindowIDs: expectedCGWindowIDs,
            coveredWids: seenByWid,
            knownUncoverable: knownUncoverable
        )

        if needBruteScan {
            let acceptedSubroles: Set<String> = [
                kAXStandardWindowSubrole as String,
                kAXDialogSubrole as String,
            ]
            // `axId` of the last iteration that produced a newly-accepted
            // window; `nil` until the first accept so the stale-budget break
            // never fires before any window is found (the rare all-unresolvable
            // CG hint then still falls back to the full `bruteForceLimit` scan).
            var lastAcceptedAxId: UInt64?
            for axId: UInt64 in 0..<bruteForceLimit {
                // Early exit once every *coverable* CG-hint window is found.
                // Known-uncoverable wids are excluded so a memoized unresolvable
                // surface can't keep the loop spinning to the stale budget on the
                // one re-sweep an expected-set change still triggers.
                if !expectedCGWindowIDs.isEmpty,
                   expectedCGWindowIDs.subtracting(knownUncoverable).isSubset(of: seenByWid) {
                    break
                }
                // Wasted-work bound: once we have accepted at least one window
                // but have run a full budget of ids past it with nothing new,
                // the remaining ids are almost certainly unresolvable (an
                // unresolvable CG id keeps `isSubset` from ever completing).
                if let last = lastAcceptedAxId, axId - last > bruteForceStaleBudget {
                    Log.switcher.debug("brute AX scan: stopping at id \(axId) for pid \(pid) — \(bruteForceStaleBudget) ids past last accept (\(seenByWid.count) found, CG hint not fully covered)")
                    break
                }
                guard let e = PrivateAPI.axElement(pid: pid, axId: axId) else { continue }
                AXUIElementSetMessagingTimeout(e, Self.preFilterTimeout)

                var elemPid: pid_t = 0
                guard AXUIElementGetPid(e, &elemPid) == .success, elemPid == pid else { continue }

                var roleValue: AnyObject?
                AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &roleValue)
                guard (roleValue as? String) == (kAXWindowRole as String) else { continue }

                AXUIElementSetMessagingTimeout(e, Self.confirmedTimeout)

                var subroleValue: AnyObject?
                AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &subroleValue)
                guard let subrole = subroleValue as? String, acceptedSubroles.contains(subrole) else { continue }

                let wid = PrivateAPI.cgWindowId(of: e)
                guard wid != 0 else { continue }

                if !expectedCGWindowIDs.isEmpty {
                    // CG hint mode: only accept windows the CG list confirmed.
                    if !expectedCGWindowIDs.contains(wid) { continue }
                } else {
                    // Legacy size filter when no CG hint available.
                    var sizeValue: AnyObject?
                    AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sizeValue)
                    if let sv = sizeValue, CFGetTypeID(sv) == AXValueGetTypeID() {
                        var size = CGSize.zero
                        AXValueGetValue(sv as! AXValue, .cgSize, &size)
                        if size.width < 100 || size.height < 100 { continue }
                    } else {
                        continue
                    }
                }

                let before = seenByWid.count
                appendIfNew(e)
                // `appendIfNew` grows `seenByWid` only on a genuine accept
                // (new element, new non-zero wid). Use that as the hit signal
                // so the stale budget measures the gap since real progress.
                if seenByWid.count != before { lastAcceptedAxId = axId }
            }
        }

        var infos: [WindowInfo] = []
        infos.reserveCapacity(elements.count)

        let acceptedSubroles: Set<String> = [
            kAXStandardWindowSubrole as String,
            kAXDialogSubrole as String,
        ]
        // Fetch all five per-window attributes in a single AX round-trip rather
        // than five sequential ones. The scan is bound by cross-process AX IPC
        // latency, not CPU, so collapsing 5 IPCs → 1 per window is the largest
        // reveal-latency win here (measured ~70% faster end-to-end, byte-
        // identical results vs the per-attribute reads). With options 0 a
        // missing attribute comes back as an AXValue error placeholder, which
        // the `as?` casts treat as absent — same fallback as before.
        let attrNames = [
            kAXSubroleAttribute,
            kAXTabsAttribute,
            kAXMinimizedAttribute,
            "AXFullScreen" as CFString,
            kAXTitleAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute,
        ] as CFArray
        // Per-window attributes, fetched once each (one AX IPC per window —
        // same round-trip count as processing inline). We materialize them up
        // front because the merged-window dedup below needs to know which
        // frames belong to a native tab group *before* deciding what to drop,
        // and that fact can come from any window in the list regardless of
        // iteration order.
        struct RawWindow {
            let element: AXUIElement
            let cgWindowID: CGWindowID
            let tabs: [AXUIElement]
            let minimized: Bool
            let fullscreen: Bool
            let title: String
            let frameKey: String?
            let fromAXList: Bool
        }
        var raws: [RawWindow] = []
        raws.reserveCapacity(elements.count)
        for window in elements {
            AXUIElementSetMessagingTimeout(window, Self.confirmedTimeout)
            var valuesRef: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(window, attrNames, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef) == .success,
                  let values = valuesRef as? [AnyObject], values.count == 7 else { continue }

            let subrole = (values[0] as? String) ?? ""
            guard acceptedSubroles.contains(subrole) else { continue }

            let tabs = (values[1] as? [AXUIElement]) ?? []
            let minimized = (values[2] as? Bool) ?? false
            let fullscreen = (values[3] as? Bool) ?? false
            let windowTitle = (values[4] as? String) ?? ""
            // Minimized windows legitimately share (0, 0); fullscreen windows
            // each fill the same display bounds, so two separate fullscreen
            // windows of one app (each on its own Space — recovered by the brute
            // scan) share a frame yet are NOT tabs (macOS never tabs fullscreen
            // windows). Excluding both from frame-grouping prevents collapsing a
            // real off-Space fullscreen window into an unrelated row (issue #10).
            let frameKey = (minimized || fullscreen) ? nil : frameKeyFromAttributes(values[5], values[6])

            raws.append(RawWindow(
                element: window,
                cgWindowID: widByElement[AXRef(element: window)] ?? 0,
                tabs: tabs,
                minimized: minimized,
                fullscreen: fullscreen,
                title: windowTitle,
                frameKey: frameKey,
                fromAXList: axListRefs.contains(AXRef(element: window))
            ))
        }

        // Native macOS window tabs: each tab is its own NSWindow at the group's
        // shared frame, but AppKit exposes only the FRONT tab in the app's window
        // list — the background tabs surface only via the brute scan. So a
        // brute-only window whose frame matches an AX-listed window of the same
        // app is a background tab, never a separate window (two real overlapping
        // windows are both AX-listed — issue #10 stays safe). Collapse keeps the
        // front tab and attaches the rest as `tabWindows` for the `\` peek;
        // expand emits one row per tab. No reliance on `AXTabs` (which these
        // apps don't expose).
        let expand = UserDefaults.standard.bool(forKey: Preferences.Keys.expandTabsAsWindows)
        let resolution = resolveTabStacks(
            frameKeys: raws.map(\.frameKey),
            fromAXList: raws.map(\.fromAXList),
            expand: expand
        )
        for (i, raw) in raws.enumerated() where resolution.keep[i] {
            let siblings = resolution.siblingIndices[i] ?? []
            let tabWindows: [TabWindowRef] = siblings.isEmpty ? [] :
                ([i] + siblings).map { idx in
                    TabWindowRef(ref: raws[idx].element, title: raws[idx].title, cgWindowID: raws[idx].cgWindowID)
                }
            infos.append(WindowInfo(
                ref: raw.element,
                cgWindowID: raw.cgWindowID,
                title: raw.title,
                isMinimized: raw.minimized,
                isFullscreen: raw.fullscreen,
                tabs: raw.tabs.count > 1 ? raw.tabs : [],
                tabWindows: tabWindows
            ))
        }

        // Wids the CG hint listed but no accepted AX window covered — memoize so
        // the next refresh with the same hint skips the brute sweep entirely.
        let uncoverable = uncoverableWids(expectedCGWindowIDs: expectedCGWindowIDs, coveredWids: seenByWid)
        return (sortedByZOrder(infos, cgZOrder: cgZOrder), uncoverable)
    }

    /// Result of grouping a pid's windows into native tab stacks.
    /// `keep[i]` is false for background-tab windows folded into their front tab
    /// (collapse mode only). `siblingIndices[front]` lists the background-tab
    /// indices folded under that kept front window, so the caller can attach
    /// them as `tabWindows` for the `\` peek.
    struct TabResolution {
        let keep: [Bool]
        let siblingIndices: [Int: [Int]]
    }

    /// Decide which windows to surface and which are native background tabs.
    /// Pure (no AX) so it is unit-testable. `frameKeys[i] == nil` means the
    /// window is unframeable/minimized/fullscreen and is never treated as a tab.
    ///
    /// - expand: every window is kept as its own row (one entry per tab); no
    ///   grouping.
    /// - collapse: every AX-listed window is kept; a brute-only window whose
    ///   frame matches an AX-listed window's frame is dropped and recorded as a
    ///   background tab of the first AX-listed window at that frame. Brute-only
    ///   windows at a frame with no AX-listed window are kept (e.g. fullscreen
    ///   windows the public list misses), preserving prior behavior.
    static func resolveTabStacks(frameKeys: [String?], fromAXList: [Bool], expand: Bool) -> TabResolution {
        let n = frameKeys.count
        var keep = [Bool](repeating: true, count: n)
        guard !expand else { return TabResolution(keep: keep, siblingIndices: [:]) }

        var axFrames = Set<String>()
        var frontForFrame: [String: Int] = [:]
        for i in 0..<n where fromAXList[i] {
            guard let f = frameKeys[i] else { continue }
            axFrames.insert(f)
            if frontForFrame[f] == nil { frontForFrame[f] = i }
        }
        var siblings: [Int: [Int]] = [:]
        for i in 0..<n where !fromAXList[i] {
            guard let f = frameKeys[i], axFrames.contains(f) else { continue }
            keep[i] = false
            if let front = frontForFrame[f] { siblings[front, default: []].append(i) }
        }
        return TabResolution(keep: keep, siblingIndices: siblings)
    }

    /// Stringify a window's (position, size) for dedup. Returns nil when
    /// either attribute is missing or fails to decode — defaults to "keep
    /// the window" rather than collapsing on incomplete data.
    private static func frameKeyFromAttributes(_ posValue: AnyObject, _ sizeValue: AnyObject) -> String? {
        guard CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        // Round to whole pixels — tab-sibling NSWindows occasionally differ
        // by a sub-pixel due to autosize; the visual outline is identical.
        let x = Int(origin.x.rounded()), y = Int(origin.y.rounded())
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        return "\(x),\(y),\(w),\(h)"
    }

    /// Re-orders the AX-derived window list to match the WindowServer
    /// z-order returned by `CGWindowListCopyWindowInfo` (front-to-back).
    /// Windows missing a CG id, or absent from the snapshot (e.g. on a
    /// hidden Space when CG omits them) keep their original AX-relative
    /// order at the tail — that's the same fallback behavior as before
    /// the z-order pass, just applied to a smaller subset.
    private static func sortedByZOrder(_ infos: [WindowInfo], cgZOrder: [CGWindowID]) -> [WindowInfo] {
        guard !cgZOrder.isEmpty, infos.count > 1 else { return infos }
        var rank: [CGWindowID: Int] = [:]
        rank.reserveCapacity(cgZOrder.count)
        for (i, wid) in cgZOrder.enumerated() { rank[wid] = i }

        let indexed = infos.enumerated().map { (offset, info) -> (rank: Int, fallback: Int, info: WindowInfo) in
            let wid = info.cgWindowID
            let r = (wid != 0 ? rank[wid] : nil) ?? Int.max
            return (r, offset, info)
        }
        return indexed.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.fallback < rhs.fallback
        }.map { $0.info }
    }

    /// Fetch titles for a tab group's `AXTab` children. Each tab is a separate
    /// AX element so the call is N IPCs — keep off the reveal path and only
    /// invoke when the user actually drills in.
    static func tabTitles(for tabs: [AXUIElement]) -> [String] {
        var titles: [String] = []
        titles.reserveCapacity(tabs.count)
        for tab in tabs {
            AXUIElementSetMessagingTimeout(tab, Self.confirmedTimeout)
            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleValue)
            titles.append((titleValue as? String) ?? "")
        }
        return titles
    }

    /// Recursively locate a window's tab buttons. Apps that use AppKit's native
    /// window-tab feature (Finder, Terminal, some older browsers) expose
    /// `AXTabs` directly on the window, but Safari/Chrome/Arc/Edge nest their
    /// tab strip several levels deep inside an `AXTabGroup`. DFS through the
    /// AX tree with a depth cap so a deep but tab-less hierarchy doesn't burn
    /// time, and return the first non-empty `AXTabs` we find.
    static func tabs(in window: AXUIElement) -> [AXUIElement] {
        if let direct = tabsAttribute(of: window), direct.count > 1 {
            return direct
        }
        return findTabsRecursive(in: window, depth: 0)
    }

    private static let tabSearchMaxDepth = 6

    private static func tabsAttribute(of element: AXUIElement) -> [AXUIElement]? {
        var value: AnyObject?
        AXUIElementSetMessagingTimeout(element, Self.confirmedTimeout)
        guard AXUIElementCopyAttributeValue(element, kAXTabsAttribute as CFString, &value) == .success,
              let arr = value as? [AXUIElement], !arr.isEmpty else {
            return nil
        }
        return arr
    }

    private static func findTabsRecursive(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < tabSearchMaxDepth else { return [] }
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return []
        }
        for child in children {
            if let tabs = tabsAttribute(of: child), tabs.count > 1 {
                return tabs
            }
            let nested = findTabsRecursive(in: child, depth: depth + 1)
            if !nested.isEmpty { return nested }
        }
        return []
    }
}
