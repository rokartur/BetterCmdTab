import AppKit
import ApplicationServices
import CoreGraphics

struct WindowInfo {
    let ref: AXUIElement
    let title: String
    let isMinimized: Bool
    let isFullscreen: Bool

    init(
        ref: AXUIElement,
        title: String,
        isMinimized: Bool,
        isFullscreen: Bool = false
    ) {
        self.ref = ref
        self.title = title
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
    }
}

private struct AXRef: Hashable {
    let element: AXUIElement
    static func == (lhs: AXRef, rhs: AXRef) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
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
    static func snapshotCGWindowMap() -> [pid_t: Set<CGWindowID>] {
        let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let cfArray = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        let selfPid = getpid()
        var result: [pid_t: Set<CGWindowID>] = [:]
        for entry in cfArray {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != selfPid else { continue }
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            if layer != 0 { continue }
            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha <= 0 { continue }
            guard let widNum = entry[kCGWindowNumber as String] as? Int else { continue }
            let wid = CGWindowID(widNum)
            if let bounds = entry[kCGWindowBounds as String] as? [String: Any] {
                let w = (bounds["Width"] as? Double) ?? 0
                let h = (bounds["Height"] as? Double) ?? 0
                if w < 100 || h < 100 { continue }
            }
            result[ownerPID, default: []].insert(wid)
        }
        return result
    }

    static func windows(
        forPid pid: pid_t,
        isRegularApp: Bool = true,
        expectedCGWindowIDs: Set<CGWindowID> = []
    ) -> [WindowInfo] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.confirmedTimeout)

        var elements: [AXUIElement] = []
        var seenByElement = Set<AXRef>()
        var seenByWid = Set<CGWindowID>()

        func appendIfNew(_ e: AXUIElement) {
            let ref = AXRef(element: e)
            if seenByElement.contains(ref) { return }
            let wid = PrivateAPI.cgWindowId(of: e)
            if wid != 0 {
                if seenByWid.contains(wid) { return }
                seenByWid.insert(wid)
            }
            seenByElement.insert(ref)
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
        let needBruteScan: Bool
        if expectedCGWindowIDs.isEmpty {
            needBruteScan = isRegularApp
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
        var seenTabGroups: Set<[AXRef]> = []
        for window in elements {
            AXUIElementSetMessagingTimeout(window, Self.confirmedTimeout)
            var subroleValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
            let subrole = (subroleValue as? String) ?? ""
            guard acceptedSubroles.contains(subrole) else { continue }

            var tabsValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTabsAttribute as CFString, &tabsValue)
            if let tabs = tabsValue as? [AXUIElement], tabs.count > 1 {
                let key = tabs.map { AXRef(element: $0) }
                if seenTabGroups.contains(key) { continue }
                seenTabGroups.insert(key)
            }

            var minimizedValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
            let minimized = (minimizedValue as? Bool) ?? false

            var fullscreenValue: AnyObject?
            AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenValue)
            let fullscreen = (fullscreenValue as? Bool) ?? false

            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let windowTitle = (titleValue as? String) ?? ""

            infos.append(WindowInfo(
                ref: window,
                title: windowTitle,
                isMinimized: minimized,
                isFullscreen: fullscreen
            ))
        }

        return infos
    }
}
