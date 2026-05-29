import AppKit
import ApplicationServices
import CoreGraphics

struct WindowInfo {
    let ref: AXUIElement
    /// WindowServer id of this window, resolved once during the scan. The stable
    /// identity across AX element churn — used for z-order ranking, MRU, and
    /// matching a window across refreshes without re-querying `_AXUIElementGetWindow`.
    let cgWindowID: CGWindowID
    let title: String
    let isMinimized: Bool
    let isFullscreen: Bool
    /// `AXTabs` children of this window (browsers, tabbed Finder, iTerm, …).
    /// Empty when the window has no tab group or only a single tab — drill-in
    /// is only meaningful with at least two tabs.
    let tabs: [AXUIElement]

    init(
        ref: AXUIElement,
        cgWindowID: CGWindowID = 0,
        title: String,
        isMinimized: Bool,
        isFullscreen: Bool = false,
        tabs: [AXUIElement] = []
    ) {
        self.ref = ref
        self.cgWindowID = cgWindowID
        self.title = title
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.tabs = tabs
    }
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

    static func windows(
        forPid pid: pid_t,
        isRegularApp: Bool = true,
        expectedCGWindowIDs: Set<CGWindowID> = [],
        cgZOrder: [CGWindowID] = []
    ) -> [WindowInfo] {
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
        let needBruteScan: Bool
        if expectedCGWindowIDs.isEmpty {
            needBruteScan = false
        } else {
            needBruteScan = isRegularApp && !expectedCGWindowIDs.isSubset(of: seenByWid)
        }

        if needBruteScan {
            let acceptedSubroles: Set<String> = [
                kAXStandardWindowSubrole as String,
                kAXDialogSubrole as String,
            ]
            for axId: UInt64 in 0..<bruteForceLimit {
                // Early exit once CG hint fully covered.
                if !expectedCGWindowIDs.isEmpty, expectedCGWindowIDs.isSubset(of: seenByWid) {
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

                appendIfNew(e)
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
            let tabs: [AXUIElement]?
            let minimized: Bool
            let fullscreen: Bool
            let title: String
            let frameKey: String?
        }
        var raws: [RawWindow] = []
        raws.reserveCapacity(elements.count)
        // Frames occupied by a native macOS window-tab group. Only these are
        // eligible for the merged-window dedup further down.
        var tabGroupFrames: Set<String> = []
        for window in elements {
            AXUIElementSetMessagingTimeout(window, Self.confirmedTimeout)
            var valuesRef: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(window, attrNames, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef) == .success,
                  let values = valuesRef as? [AnyObject], values.count == 7 else { continue }

            let subrole = (values[0] as? String) ?? ""
            guard acceptedSubroles.contains(subrole) else { continue }

            let tabs = values[1] as? [AXUIElement]
            let minimized = (values[2] as? Bool) ?? false
            let fullscreen = (values[3] as? Bool) ?? false
            let windowTitle = (values[4] as? String) ?? ""
            // Minimized windows legitimately share (0, 0) — never frame-dedup them.
            let frameKey = minimized ? nil : frameKeyFromAttributes(values[5], values[6])

            if let tabs, tabs.count > 1, let frameKey { tabGroupFrames.insert(frameKey) }

            raws.append(RawWindow(
                element: window,
                cgWindowID: widByElement[AXRef(element: window)] ?? 0,
                tabs: tabs,
                minimized: minimized,
                fullscreen: fullscreen,
                title: windowTitle,
                frameKey: frameKey
            ))
        }

        var seenTabGroups: Set<[AXRef]> = []
        var addedTabGroupForPid = false
        // Native macOS window tabs (Finder, Terminal, TextEdit, Ghostty, ...)
        // expose each tab as its own AXWindow with its own CGWindowID — but
        // they share the same on-screen frame because only one tab renders at
        // a time and macOS keeps the merged-window outline identical across
        // tabs. Collapsing by (origin × size) keeps one row per visual merged
        // window. Crucially this is gated on `tabGroupFrames`: two genuinely
        // separate windows that merely overlap (e.g. two maximized Chrome
        // windows, which don't use native window tabs) must NOT collapse —
        // doing so was issue #10, where the second maximized window vanished
        // from the switcher.
        var seenFrames: Set<String> = []
        for raw in raws {
            var windowTabs: [AXUIElement] = []
            if let tabs = raw.tabs, tabs.count > 1 {
                if addedTabGroupForPid { continue }
                let key = tabs.map { AXRef(element: $0) }
                if seenTabGroups.contains(key) { continue }
                seenTabGroups.insert(key)
                windowTabs = tabs
                addedTabGroupForPid = true
            }

            if let frameKey = raw.frameKey, tabGroupFrames.contains(frameKey) {
                if seenFrames.contains(frameKey) { continue }
                seenFrames.insert(frameKey)
            }

            infos.append(WindowInfo(
                ref: raw.element,
                cgWindowID: raw.cgWindowID,
                title: raw.title,
                isMinimized: raw.minimized,
                isFullscreen: raw.fullscreen,
                tabs: windowTabs
            ))
        }

        return sortedByZOrder(infos, cgZOrder: cgZOrder)
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
