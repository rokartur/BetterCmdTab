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
    /// True when this window is a background tab of a native tab group kept as
    /// its own row ("expand tabs as windows"). A tabbed-away window is ordered
    /// out and belongs to no Space, which is also the phantom-window signal —
    /// this flag exempts it from that filter so expand mode keeps its rows.
    let isTabSibling: Bool

    init(
        ref: AXUIElement,
        cgWindowID: CGWindowID = 0,
        title: String,
        isMinimized: Bool,
        isFullscreen: Bool = false,
        tabs: [AXUIElement] = [],
        tabWindows: [TabWindowRef] = [],
        isTabSibling: Bool = false
    ) {
        self.ref = ref
        self.cgWindowID = cgWindowID
        self.title = title
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.tabs = tabs
        self.tabWindows = tabWindows
        self.isTabSibling = isTabSibling
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
    /// Wids WindowServer reports at a non-switchable window level — Dock level
    /// (20) and above (menus, status items, pop-ups, overlays, HUDs, notification
    /// panels, screensaver) plus the sub-normal desktop band (< 0). Dropped during
    /// enumeration so they never become switcher rows even though AX lists them as
    /// standard windows. Floating/modal/utility windows (levels 1–19) are NOT here
    /// — they are legitimate user windows and stay in the switcher.
    let nonNormalLayer: [pid_t: Set<CGWindowID>]
    /// Wids WindowServer reports as currently ordered in (`kCGWindowIsOnscreen`).
    /// A tabbed-away native-tab window is ordered out while its front tab is
    /// ordered in — the discriminator the tab-stack resolver uses on macOS
    /// builds where AppKit lists background tabs in `kAXWindowsAttribute`.
    let onscreen: [pid_t: Set<CGWindowID>]

    static let empty = CGWindowSnapshot(ids: [:], zOrder: [:], nonNormalLayer: [:], onscreen: [:])

    func ids(for pid: pid_t) -> Set<CGWindowID> { ids[pid] ?? [] }
    func zOrder(for pid: pid_t) -> [CGWindowID] { zOrder[pid] ?? [] }
    func nonNormalLayer(for pid: pid_t) -> Set<CGWindowID> { nonNormalLayer[pid] ?? [] }
    func onscreen(for pid: pid_t) -> Set<CGWindowID> { onscreen[pid] ?? [] }
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

    /// Lowest CGWindow level we treat as a non-switchable overlay: Dock level
    /// (20). Windows at this level and above are system surfaces (Dock, menus,
    /// status items, pop-ups, overlays, HUDs, notification panels, screensaver);
    /// levels 1–19 (floating "keep on top", modal panel, utility) are legitimate
    /// user windows kept in the switcher.
    static let dockWindowLevel = Int(CGWindowLevelForKey(.dockWindow))

    /// Classification of a `CGWindowListCopyWindowInfo` entry for snapshot
    /// bucketing. `.normal` windows feed the id/z-order hint; `.nonNormalLayer`
    /// windows (Dock-level-and-above overlays plus the sub-normal desktop band)
    /// are recorded so enumeration can drop them; `.excluded` covers invisible or
    /// sub-100px surfaces ignored entirely. Layer takes precedence: a
    /// non-switchable-layer window is `.nonNormalLayer` even if also tiny/transparent.
    enum CGWindowBucket: Equatable {
        case normal
        case nonNormalLayer
        case excluded
    }

    static func cgWindowBucket(layer: Int, alpha: Double, width: Double, height: Double) -> CGWindowBucket {
        // Drop only non-switchable surfaces: Dock level (20) and above, plus the
        // sub-normal desktop band (< 0). Levels 1–19 — floating ("keep on top"),
        // modal panels, utility windows — are real user windows and stay. The
        // Teams notification phantom sits at level 20 (Dock), so it's still caught.
        if layer >= Self.dockWindowLevel || layer < 0 { return .nonNormalLayer }
        if alpha <= 0 { return .excluded }
        if width < 100 || height < 100 { return .excluded }
        return .normal
    }

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
        // 6 fields below get bridged, on access. This runs on the cold-reveal
        // full-scan path and on every coalesced bump, so the saved allocations
        // add up.
        guard let cfArray = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [NSDictionary] else {
            return .empty
        }
        var ids: [pid_t: Set<CGWindowID>] = [:]
        var zOrder: [pid_t: [CGWindowID]] = [:]
        var nonNormalLayer: [pid_t: Set<CGWindowID>] = [:]
        var onscreen: [pid_t: Set<CGWindowID>] = [:]
        for entry in cfArray {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let widNum = entry[kCGWindowNumber as String] as? Int else { continue }
            let wid = CGWindowID(widNum)
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1.0
            // Missing bounds key => treat as large enough, preserving the prior
            // "no bounds -> keep" behavior. A present-but-empty bounds dict yields
            // 0 and is correctly excluded by the size gate inside cgWindowBucket.
            var width = Double.greatestFiniteMagnitude
            var height = Double.greatestFiniteMagnitude
            if let bounds = entry[kCGWindowBounds as String] as? NSDictionary {
                width = (bounds["Width"] as? Double) ?? 0
                height = (bounds["Height"] as? Double) ?? 0
            }
            switch cgWindowBucket(layer: layer, alpha: alpha, width: width, height: height) {
            case .normal:
                if ids[ownerPID, default: []].insert(wid).inserted {
                    zOrder[ownerPID, default: []].append(wid)
                }
                if (entry[kCGWindowIsOnscreen as String] as? Bool) == true {
                    onscreen[ownerPID, default: []].insert(wid)
                }
            case .nonNormalLayer:
                nonNormalLayer[ownerPID, default: []].insert(wid)
            case .excluded:
                break
            }
        }
        return CGWindowSnapshot(ids: ids, zOrder: zOrder, nonNormalLayer: nonNormalLayer, onscreen: onscreen)
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
        cgZOrder: [CGWindowID] = [],
        nonNormalLayerWids: Set<CGWindowID> = [],
        onscreenWids: Set<CGWindowID> = []
    ) -> [WindowInfo] {
        enumerate(
            forPid: pid,
            isRegularApp: isRegularApp,
            expectedCGWindowIDs: expectedCGWindowIDs,
            cgZOrder: cgZOrder,
            nonNormalLayerWids: nonNormalLayerWids,
            onscreenWids: onscreenWids
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
        knownUncoverable: Set<CGWindowID> = [],
        nonNormalLayerWids: Set<CGWindowID> = [],
        onscreenWids: Set<CGWindowID> = []
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
            // Drop windows WindowServer reports at a non-normal window level
            // (notification panels/HUDs/overlays). These are AX-listed as
            // standard windows but are not user-switchable — e.g. the Teams
            // Notification Center helper's off-screen "Window" at layer 20.
            if nonNormalLayerWids.contains(wid) { return }
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
            let frame: CGRect?
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
            let frame = (minimized || fullscreen) ? nil : frameFromAttributes(values[5], values[6])

            raws.append(RawWindow(
                element: window,
                cgWindowID: widByElement[AXRef(element: window)] ?? 0,
                tabs: tabs,
                minimized: minimized,
                fullscreen: fullscreen,
                title: windowTitle,
                frame: frame,
                fromAXList: axListRefs.contains(AXRef(element: window))
            ))
        }

        // Native macOS window tabs: each tab is its own NSWindow at the group's
        // shared frame. On current macOS AppKit exposes only the FRONT tab in
        // the app's window list — the background tabs surface only via the
        // brute scan, so a brute-only window at an AX-listed window's exact
        // frame is a background tab (two real overlapping windows are both
        // AX-listed — issue #10 stays safe). Shapes that rule misses (issue
        // #81) — a background tab left at its stale pre-merge frame
        // (CotEditor), or AX-listed on macOS builds that list every tab window
        // (Sonoma) — are caught by the near-frame rule: ordered out near an
        // ordered-in front's frame and spaceless / on the front's own Space.
        // Ordered-in windows and windows on another Space are never folded.
        // Collapse keeps the front tab and attaches the rest as `tabWindows`
        // for the `\` peek; expand emits one row per tab. No reliance on
        // `AXTabs` (which these apps don't expose).
        let expand = UserDefaults.standard.bool(forKey: Preferences.Keys.expandTabsAsWindows)
        let frames = raws.map(\.frame)
        let fromAXList = raws.map(\.fromAXList)
        let onscreen = raws.map { onscreenWids.contains($0.cgWindowID) }
        // Space membership is one WindowServer IPC per window, so resolve it
        // only for the windows the near-frame tab rule can act on (plus their
        // on-screen fronts, for the same-Space comparison). Empty for apps
        // without a tab-shaped group — the common case pays nothing.
        var spaceless = [Bool](repeating: false, count: raws.count)
        var spaceOf = [UInt64?](repeating: nil, count: raws.count)
        let spaceQueryIndices = tabSpaceQueryIndices(frames: frames, fromAXList: fromAXList, onscreen: onscreen)
        if !spaceQueryIndices.isEmpty {
            let membership = PrivateAPI.spaceMembership(forWindows: spaceQueryIndices.map { raws[$0].cgWindowID })
            for i in spaceQueryIndices {
                spaceless[i] = membership.spaceless.contains(raws[i].cgWindowID)
                spaceOf[i] = membership.resolved[raws[i].cgWindowID]
            }
        }
        let resolution = resolveTabStacks(
            frames: frames,
            fromAXList: fromAXList,
            onscreen: onscreen,
            spaceless: spaceless,
            spaceOf: spaceOf,
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
                tabWindows: tabWindows,
                isTabSibling: resolution.tabSibling[i]
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
    /// them as `tabWindows` for the `\` peek. `tabSibling[i]` is true for
    /// background tabs kept as their own rows (expand mode only) — the flag that
    /// exempts them from the phantom-window filter, since a tabbed-away window
    /// is spaceless just like an Electron helper.
    struct TabResolution {
        let keep: [Bool]
        let siblingIndices: [Int: [Int]]
        let tabSibling: [Bool]
    }

    /// How far a tabbed-away window's stale frame may drift from the group's
    /// on-screen frame and still count as the same tab stack. Some apps
    /// (CotEditor, issue #81) never update a background tab's NSWindow frame
    /// after merging, so it keeps the pre-merge cascade offset (~21pt);
    /// Finder/Terminal keep siblings byte-identical. 50pt matches AltTab's
    /// tab-sibling tolerance and stays well under any deliberate window offset.
    static let tabFrameTolerance: CGFloat = 50

    /// Whether `frame` is close enough to `front` to be the same tab stack:
    /// identical rounded size, origin within `tabFrameTolerance` on both axes.
    static func isNearTabFrame(_ frame: CGRect, _ front: CGRect) -> Bool {
        frame.size == front.size
            && abs(frame.origin.x - front.origin.x) <= tabFrameTolerance
            && abs(frame.origin.y - front.origin.y) <= tabFrameTolerance
    }

    /// Indices whose Space membership `resolveTabStacks` needs: ordered-out
    /// windows sitting near an ordered-in AX-listed window's frame that the
    /// exact-frame brute rule alone can't classify (AX-listed ones — the
    /// Sonoma shape — and brute-only ones whose stale frame drifted off the
    /// group's, the CotEditor shape), plus the ordered-in fronts themselves
    /// (for the same-Space comparison). Empty — the common case — means the
    /// caller skips the per-window `CGSCopySpacesForWindows` IPCs entirely.
    /// Pure, so the gate is unit-testable.
    static func tabSpaceQueryIndices(frames: [CGRect?], fromAXList: [Bool], onscreen: [Bool]) -> [Int] {
        let n = frames.count
        let fronts = (0..<n).filter { fromAXList[$0] && onscreen[$0] && frames[$0] != nil }
        guard !fronts.isEmpty else { return [] }
        // Exact frames of AX-listed windows: a brute-only window at one of these
        // is folded by the exact rule with no Space data needed.
        var axFrames = Set<String>()
        for i in 0..<n where fromAXList[i] {
            if let f = frames[i] { axFrames.insert(frameKey(f)) }
        }
        var indices: [Int] = []
        var neededFronts = Set<Int>()
        for i in 0..<n where !onscreen[i] {
            guard let f = frames[i] else { continue }
            if !fromAXList[i] && axFrames.contains(frameKey(f)) { continue }
            guard let front = fronts.first(where: { isNearTabFrame(f, frames[$0]!) }) else { continue }
            indices.append(i)
            neededFronts.insert(front)
        }
        return indices.isEmpty ? [] : indices + neededFronts.sorted()
    }

    /// Decide which windows to surface and which are native background tabs.
    /// Pure (no AX/CGS) so it is unit-testable. `frames[i] == nil` means the
    /// window is unframeable/minimized/fullscreen and is never treated as a tab.
    ///
    /// A window is a background tab when either:
    /// - it is brute-only at the *exact* frame of an AX-listed window — AppKit
    ///   lists only the front tab, so the brute scan is the only place
    ///   background tabs surface on current macOS. Two real overlapping
    ///   windows are both AX-listed, so issue #10 stays safe. Or:
    /// - it is ordered out (`onscreen[i] == false`) *near* an ordered-in
    ///   AX-listed front's frame (same size, origin within
    ///   `tabFrameTolerance`), and WindowServer reports it spaceless or on the
    ///   front's own Space. This catches the shapes the exact rule misses
    ///   (issue #81): apps that leave a background tab's frame at its stale
    ///   pre-merge cascade offset (CotEditor), and macOS builds that AX-list
    ///   every tab window (Sonoma). Ordered-in windows (real overlapping
    ///   windows, issue #10) and windows resolved to a *different* Space (a
    ///   same-frame window on another desktop) are never folded.
    ///
    /// - expand: every window is kept as its own row (one entry per tab);
    ///   background tabs are flagged `tabSibling` instead of folded.
    /// - collapse: background tabs are dropped and recorded as siblings of
    ///   their front window. Brute-only windows matching no AX-listed window
    ///   are kept (e.g. fullscreen windows the public list misses), preserving
    ///   prior behavior.
    static func resolveTabStacks(
        frames: [CGRect?],
        fromAXList: [Bool],
        onscreen: [Bool],
        spaceless: [Bool],
        spaceOf: [UInt64?],
        expand: Bool
    ) -> TabResolution {
        let n = frames.count
        // Exact-frame front: the ordered-in AX-listed window (the visible front
        // tab) when present, else the first AX-listed one (prior behavior).
        var frontForFrame: [String: Int] = [:]
        for i in 0..<n where fromAXList[i] {
            guard let f = frames[i] else { continue }
            let key = frameKey(f)
            if let current = frontForFrame[key] {
                if !onscreen[current] && onscreen[i] { frontForFrame[key] = i }
            } else {
                frontForFrame[key] = i
            }
        }
        let nearFronts = (0..<n).filter { fromAXList[$0] && onscreen[$0] && frames[$0] != nil }
        var isTab = [Bool](repeating: false, count: n)
        var siblings: [Int: [Int]] = [:]
        for i in 0..<n {
            guard let f = frames[i] else { continue }
            var front: Int?
            if !fromAXList[i], let exact = frontForFrame[frameKey(f)], exact != i {
                front = exact
            } else if !onscreen[i],
                      let near = nearFronts.first(where: { $0 != i && isNearTabFrame(f, frames[$0]!) }),
                      spaceless[i] || (spaceOf[i] != nil && spaceOf[i] == spaceOf[near]) {
                front = near
            }
            if let front {
                isTab[i] = true
                siblings[front, default: []].append(i)
            }
        }
        if expand {
            return TabResolution(keep: [Bool](repeating: true, count: n), siblingIndices: [:], tabSibling: isTab)
        }
        var keep = [Bool](repeating: true, count: n)
        for i in 0..<n where isTab[i] { keep[i] = false }
        return TabResolution(keep: keep, siblingIndices: siblings, tabSibling: [Bool](repeating: false, count: n))
    }

    /// Decode a window's (position, size) for dedup, rounded to whole pixels —
    /// tab-sibling NSWindows occasionally differ by a sub-pixel due to
    /// autosize; the visual outline is identical. Returns nil when either
    /// attribute is missing or fails to decode — defaults to "keep the window"
    /// rather than collapsing on incomplete data.
    private static func frameFromAttributes(_ posValue: AnyObject, _ sizeValue: AnyObject) -> CGRect? {
        guard CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(
            x: origin.x.rounded(), y: origin.y.rounded(),
            width: size.width.rounded(), height: size.height.rounded()
        )
    }

    /// Exact-match dictionary key for a (rounded) window frame.
    private static func frameKey(_ f: CGRect) -> String {
        "\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width)),\(Int(f.height))"
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
