import AppKit
import ApplicationServices
import CoreGraphics
import CoreServices
import Darwin

/// Runtime-resolved bindings for Apple private APIs used to discover windows
/// that the public `kAXWindowsAttribute` query misses (e.g. fullscreen windows
/// living on their own Spaces) and to raise a specific window across Spaces.
/// dlsym-based so the Xcode project does not need an extra linker flag or
/// bridging header.
enum PrivateAPI {
    private static let RTLD_DEFAULT_HANDLE = UnsafeMutableRawPointer(bitPattern: -2)
    private static let skyLight: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    }()

    private static func sym<T>(_ name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    // MARK: - HIServices (private)

    private static let axCreateWithRemoteTokenFn: (@convention(c) (CFData) -> Unmanaged<AXUIElement>?)? =
        sym("_AXUIElementCreateWithRemoteToken", in: RTLD_DEFAULT_HANDLE)
    private static let axGetWindowFn: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? =
        sym("_AXUIElementGetWindow", in: RTLD_DEFAULT_HANDLE)

    /// Build a remote-token AXUIElement for `(pid, axId)`. Token format is 20
    /// bytes: pid (Int32 LE) | 0 (Int32 LE) | 0x636f636f (Int32 LE) | axId (UInt64 LE).
    static func axElement(pid: pid_t, axId: UInt64) -> AXUIElement? {
        guard let fn = axCreateWithRemoteTokenFn else { return nil }
        var token = Data(count: 20)
        var pidVal = pid
        var zero: Int32 = 0
        var magic: Int32 = 0x636f636f
        var id = axId
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: &pidVal) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: &zero) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: &magic) { Data($0) })
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: &id) { Data($0) })
        return fn(token as CFData)?.takeRetainedValue()
    }

    /// AX → CGWindowID. Returns 0 on failure.
    static func cgWindowId(of element: AXUIElement) -> CGWindowID {
        guard let fn = axGetWindowFn else { return 0 }
        var id: CGWindowID = 0
        let err = fn(element, &id)
        return err == .success ? id : 0
    }

    // MARK: - SkyLight: cross-Space window raise

    private static let setFrontProcFn: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, Int32) -> CGError)? =
        sym("_SLPSSetFrontProcessWithOptions", in: skyLight)
    private static let postEventFn: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError)? =
        sym("SLPSPostEventRecordTo", in: skyLight)
    // GetProcessForPID is deprecated past macOS 10.9 and the Swift importer
    // hides it — pull the symbol via dlsym instead.
    private static let getProcessForPIDFn: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus)? =
        sym("GetProcessForPID", in: RTLD_DEFAULT_HANDLE)

    // MARK: - SkyLight: no-animation Space switch

    // `CGSConnectionID` is a plain `int`.
    private static let mainConnectionFn: (@convention(c) () -> Int32)? =
        sym("CGSMainConnectionID", in: skyLight)
    // (cid, CGSSpaceMask, CFArray<window ids>) -> CFArray<space ids>
    private static let copySpacesForWindowsFn: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?)? =
        sym("CGSCopySpacesForWindows", in: skyLight)
    // (cid) -> CFArray of per-display dicts; each carries an ordered "Spaces"
    // array (space dicts keyed by "id64") and a "Current Space" dict. Used to
    // turn the target window's Space into a signed left/right step count from
    // the display's current Space, which the synthetic swipe below then walks.
    private static let copyManagedDisplaySpacesFn: (@convention(c) (Int32) -> Unmanaged<CFArray>?)? =
        sym("CGSCopyManagedDisplaySpaces", in: skyLight)
    // (cid) -> the focused Space id. Identifies which display the synthetic
    // swipe will move, so we only post one for jumps within that display.
    private static let getActiveSpaceFn: (@convention(c) (Int32) -> UInt64)? =
        sym("CGSGetActiveSpace", in: skyLight)
    // (cid, CFArray<window ids>, CGSSpaceID) -> Void. Moves the given windows to
    // a Space. Backs the experimental "move window to adjacent Space" action.
    private static let moveWindowsToSpaceFn: (@convention(c) (Int32, CFArray, UInt64) -> Void)? =
        sym("CGSMoveWindowsToManagedSpace", in: skyLight)

    // MARK: - SkyLight: current-Space queries (read-only)

    /// The id of the currently focused Space, or nil when the private API is
    /// unavailable. Used by the "only current Space" switcher filter.
    static func activeSpace() -> UInt64? {
        guard let mainConnection = mainConnectionFn, let getActive = getActiveSpaceFn else { return nil }
        let space = getActive(mainConnection())
        return space == 0 ? nil : space
    }

    /// Maps each window id to the first Space it belongs to. Windows whose Space
    /// can't be resolved are omitted; the result is empty when the private API is
    /// unavailable (callers should then degrade to showing every window).
    static func spaces(forWindows wids: [CGWindowID]) -> [CGWindowID: UInt64] {
        guard !wids.isEmpty,
              let mainConnection = mainConnectionFn,
              let copySpaces = copySpacesForWindowsFn else { return [:] }
        let cid = mainConnection()
        var result: [CGWindowID: UInt64] = [:]
        result.reserveCapacity(wids.count)
        for wid in wids where wid != 0 {
            // Query one window at a time: `CGSCopySpacesForWindows` returns the
            // union of Spaces for the whole input array, so a single call can't
            // be attributed back to individual windows.
            let list = [NSNumber(value: wid)] as CFArray
            guard let spaces = copySpaces(cid, 0x7, list)?.takeRetainedValue(),
                  CFArrayGetCount(spaces) > 0,
                  let raw = CFArrayGetValueAtIndex(spaces, 0) else { continue }
            let number = Unmanaged<CFNumber>.fromOpaque(raw).takeUnretainedValue()
            var space: UInt64 = 0
            if CFNumberGetValue(number, .sInt64Type, &space), space != 0 {
                result[wid] = space
            }
        }
        return result
    }

    /// The Space adjacent to `space` by `step` (-1 = left, +1 = right) within the
    /// same display's ordered Space list. nil at the ends or when unresolved.
    /// Backs the experimental move-window-to-adjacent-Space action.
    static func adjacentSpace(toSpace space: UInt64, step: Int) -> UInt64? {
        guard space != 0, step != 0,
              let mainConnection = mainConnectionFn,
              let copyDisplays = copyManagedDisplaySpacesFn else { return nil }
        let cid = mainConnection()
        guard let cf = copyDisplays(cid)?.takeRetainedValue() else { return nil }
        let displays = (cf as NSArray).compactMap { $0 as? [String: Any] }
        for display in displays {
            guard let spaceArray = display["Spaces"] as? [Any] else { continue }
            let ids = spaceArray.compactMap { ($0 as? [String: Any]).flatMap(spaceId) }
            guard let idx = ids.firstIndex(of: space) else { continue }
            let target = idx + step
            return ids.indices.contains(target) ? ids[target] : nil
        }
        return nil
    }

    /// Move a single window to `space`. Returns false when the private API is
    /// unavailable. Does not switch the user to that Space — call `switchToSpace`
    /// afterwards to follow the window.
    @discardableResult
    static func moveWindow(_ wid: CGWindowID, toSpace space: UInt64) -> Bool {
        guard wid != 0, space != 0,
              let mainConnection = mainConnectionFn,
              let move = moveWindowsToSpaceFn else { return false }
        move(mainConnection(), [NSNumber(value: wid)] as CFArray, space)
        return true
    }

    /// One-shot startup diagnostic. Returns the list of dlsym symbols that
    /// failed to resolve, so AppDelegate can surface a single warning instead
    /// of every call site silently no-opping.
    static func selfCheck() -> [String] {
        var missing: [String] = []
        if axCreateWithRemoteTokenFn == nil { missing.append("_AXUIElementCreateWithRemoteToken") }
        if axGetWindowFn == nil { missing.append("_AXUIElementGetWindow") }
        if setFrontProcFn == nil { missing.append("_SLPSSetFrontProcessWithOptions") }
        if postEventFn == nil { missing.append("SLPSPostEventRecordTo") }
        if getProcessForPIDFn == nil { missing.append("GetProcessForPID") }
        if mainConnectionFn == nil { missing.append("CGSMainConnectionID") }
        if copySpacesForWindowsFn == nil { missing.append("CGSCopySpacesForWindows") }
        if copyManagedDisplaySpacesFn == nil { missing.append("CGSCopyManagedDisplaySpaces") }
        if getActiveSpaceFn == nil { missing.append("CGSGetActiveSpace") }
        if moveWindowsToSpaceFn == nil { missing.append("CGSMoveWindowsToManagedSpace") }
        return missing
    }

    /// Switch instantly — no slide animation — to the Space that contains
    /// `wid`, by synthesizing a horizontal Dock-swipe gesture: the same input
    /// path a three-finger trackpad swipe drives.
    ///
    /// We used to call `CGSManagedDisplaySetCurrentSpace`, which sets the
    /// current Space directly but skips the WindowServer's space-transition
    /// machinery. Leaving a *full-screen* Space that way left the destination
    /// regular Space with no menu bar (the Apple menu and app menus never came
    /// back). Driving the legitimate gesture path keeps the menu bar correct; a
    /// near-zero progress with a high velocity collapses the slide to nothing so
    /// it still reads as instant.
    ///
    /// Returns true only when it actually posted a switch gesture — the caller
    /// then skips its own cross-Space `raiseWindow`, whose `_SLPS…` raise can
    /// win the race against the gesture and animate-switch past the target.
    /// Returns false when already on the target Space or when it can't be
    /// resolved, leaving the caller's normal raise (an animated, but
    /// menu-bar-correct, cross-Space switch) as the fallback.
    @discardableResult
    static func switchToSpace(ofWindow wid: CGWindowID) -> Bool {
        guard wid != 0,
              let mainConnection = mainConnectionFn,
              let copySpaces = copySpacesForWindowsFn,
              let copyDisplays = copyManagedDisplaySpacesFn,
              let getActiveSpace = getActiveSpaceFn else { return false }

        let cid = mainConnection()

        // The Space the target window lives on.
        let windowList = [NSNumber(value: wid)] as CFArray
        // 0x7 = current | other | user Spaces — search them all.
        guard let spaces = copySpaces(cid, 0x7, windowList)?.takeRetainedValue(),
              CFArrayGetCount(spaces) > 0,
              let raw = CFArrayGetValueAtIndex(spaces, 0) else { return false }
        let number = Unmanaged<CFNumber>.fromOpaque(raw).takeUnretainedValue()
        var targetSpace: UInt64 = 0
        guard CFNumberGetValue(number, .sInt64Type, &targetSpace), targetSpace != 0 else { return false }

        // A synthetic swipe moves whichever display owns the focused Space, so
        // anchor the step count there. How many Spaces left (−) or right (+) the
        // target sits from the focused one. nil = the target is on a different
        // display (let the caller's SLPS raise handle that — it stays menu-bar
        // correct); 0 = already there. Either way, don't post a swipe.
        let activeSpace = getActiveSpace(cid)
        guard activeSpace != 0,
              let cfDisplays = copyDisplays(cid)?.takeRetainedValue() else { return false }
        let displays = (cfDisplays as NSArray).compactMap { $0 as? [String: Any] }
        guard let steps = spaceStepDelta(displays: displays, from: activeSpace, to: targetSpace),
              steps != 0 else { return false }

        let magnitude = abs(steps)
        // Match the reference: scale velocity by the jump distance so each of the
        // `magnitude` swipes still commits instantly across several Spaces.
        let velocity = dockSwipeVelocity * Double(magnitude)
        for _ in 0..<magnitude {
            postDockSwipe(rightward: steps > 0, velocity: velocity)
        }
        return true
    }

    /// Switch to the Space on the left (`rightward == false`) or right by posting
    /// one synthetic horizontal Dock-swipe — the same instant path as
    /// `switchToSpace`, but direction-driven rather than window-driven. Backs the
    /// "three-finger swipe switches Spaces" mode.
    static func switchSpace(rightward: Bool) {
        postDockSwipe(rightward: rightward, velocity: dockSwipeVelocity)
    }

    /// Switch one Space left/right, wrapping at the ends: swiping left off the
    /// first Space lands on the last, and vice versa. At an edge it reaches the
    /// far Space by posting `count - 1` swipes the other way (one synthetic swipe
    /// = one Space step, same as the instant Space switch). Falls back to a
    /// single non-wrapping swipe when the Space layout can't be resolved.
    static func switchSpaceWrapping(rightward: Bool) {
        guard let layout = activeDisplaySpaces(), layout.count > 1 else {
            switchSpace(rightward: rightward)
            return
        }
        let target = layout.index + (rightward ? 1 : -1)
        if target >= 0 && target < layout.count {
            postDockSwipe(rightward: rightward, velocity: dockSwipeVelocity)
        } else {
            // Wrap to the opposite end.
            let steps = layout.count - 1
            let velocity = dockSwipeVelocity * Double(steps)
            for _ in 0..<steps {
                postDockSwipe(rightward: !rightward, velocity: velocity)
            }
        }
    }

    /// Ordered Space count and the active Space's index on the display that owns
    /// the focused Space (the one a swipe moves). nil when unavailable.
    private static func activeDisplaySpaces() -> (count: Int, index: Int)? {
        guard let mainConnection = mainConnectionFn,
              let getActiveSpace = getActiveSpaceFn,
              let copyDisplays = copyManagedDisplaySpacesFn else { return nil }
        let cid = mainConnection()
        let active = getActiveSpace(cid)
        guard active != 0, let cf = copyDisplays(cid)?.takeRetainedValue() else { return nil }
        let displays = (cf as NSArray).compactMap { $0 as? [String: Any] }
        for display in displays {
            guard let spaceArray = display["Spaces"] as? [Any] else { continue }
            let ids = spaceArray.compactMap { ($0 as? [String: Any]).flatMap(spaceId) }
            guard let idx = ids.firstIndex(of: active) else { continue }
            return (ids.count, idx)
        }
        return nil
    }

    /// On the display that owns `activeSpace` (the one a swipe would move),
    /// return `targetSpace`'s signed offset from it (negative = left, positive =
    /// right). nil if `targetSpace` lives on a different display, so the caller
    /// falls back rather than swiping the wrong display.
    private static func spaceStepDelta(displays: [[String: Any]], from activeSpace: UInt64, to targetSpace: UInt64) -> Int? {
        for display in displays {
            guard let spaceArray = display["Spaces"] as? [Any] else { continue }
            let ids = spaceArray.compactMap { ($0 as? [String: Any]).flatMap(spaceId) }
            guard let currentIndex = ids.firstIndex(of: activeSpace) else { continue }
            guard let targetIndex = ids.firstIndex(of: targetSpace) else { return nil }
            return targetIndex - currentIndex
        }
        return nil
    }

    /// A Space's 64-bit id from its CGS dictionary. Recent macOS uses "id64";
    /// older builds spelled it "ManagedSpaceID".
    private static func spaceId(_ dict: [String: Any]) -> UInt64? {
        if let n = dict["id64"] as? NSNumber { return n.uint64Value }
        if let n = dict["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        return nil
    }

    // MARK: - SkyLight: synthetic Dock-swipe (instant Space switch)

    /// Base horizontal velocity for the synthetic swipe — high enough that the
    /// WindowServer skips the slide animation (InstantSpaceSwitcher's default).
    private static let dockSwipeVelocity = 2000.0

    /// Undocumented CGS gesture event type / field ids, shared with
    /// `SpaceSwipeSuppressor`. (Values from the IOHID/CGS private headers.)
    private enum Swipe {
        static let eventType: UInt32 = 55       // kCGSEventType
        static let hidType: UInt32 = 110        // kCGEventGestureHIDType
        static let motion: UInt32 = 123         // kCGEventGestureSwipeMotion
        static let progress: UInt32 = 124       // kCGEventGestureSwipeProgress
        static let velocityX: UInt32 = 129      // kCGEventGestureSwipeVelocityX
        static let velocityY: UInt32 = 130      // kCGEventGestureSwipeVelocityY
        static let phase: UInt32 = 132          // kCGEventGesturePhase

        static let dockControl: Int64 = 30      // kCGSEventDockControl
        static let dockSwipe: Int64 = 23        // kIOHIDEventTypeDockSwipe
        static let horizontal: Int64 = 1        // kCGGestureMotionHorizontal

        static let phaseBegan: Int64 = 1        // kCGSGesturePhaseBegan
        static let phaseChanged: Int64 = 2      // kCGSGesturePhaseChanged
        static let phaseEnded: Int64 = 4        // kCGSGesturePhaseEnded
    }

    /// Post one complete horizontal Dock-swipe (Began → Changed → Ended) in the
    /// given direction. All three phases are required — a partial sequence
    /// leaves the WindowServer mid-gesture and the switch never commits. The
    /// progress is ±FLT_TRUE_MIN: signed so the direction registers, but far too
    /// small to render any travel.
    private static func postDockSwipe(rightward: Bool, velocity: Double) {
        let tiny = Double(Float.leastNonzeroMagnitude)
        let progress = rightward ? tiny : -tiny
        let vx = rightward ? velocity : -velocity
        for phase in [Swipe.phaseBegan, Swipe.phaseChanged, Swipe.phaseEnded] {
            guard let ev = CGEvent(source: nil) else { return }
            ev.setIntegerValueField(field(Swipe.eventType), value: Swipe.dockControl)
            ev.setIntegerValueField(field(Swipe.hidType), value: Swipe.dockSwipe)
            ev.setIntegerValueField(field(Swipe.phase), value: phase)
            ev.setDoubleValueField(field(Swipe.progress), value: progress)
            ev.setIntegerValueField(field(Swipe.motion), value: Swipe.horizontal)
            ev.setDoubleValueField(field(Swipe.velocityX), value: vx)
            ev.setDoubleValueField(field(Swipe.velocityY), value: vx)
            ev.post(tap: .cgSessionEventTap)
        }
    }

    /// `CGEventField` is a `uint32_t`-backed enum; the gesture field ids aren't
    /// declared cases, so bit-cast the raw value to address them (same trick as
    /// `SpaceSwipeSuppressor`).
    private static func field(_ raw: UInt32) -> CGEventField {
        unsafeBitCast(raw, to: CGEventField.self)
    }

    /// Raise a specific window across Spaces (including a fullscreen window
    /// living on its own Space). The public `kAXRaiseAction` and
    /// `NSRunningApplication.activate()` cannot switch the user to a Space
    /// they're not on; SkyLight's private `_SLPSSetFrontProcessWithOptions` +
    /// `SLPSPostEventRecordTo` synthetic event do.
    ///
    /// Returns true when both SLPS calls dispatched successfully — the caller
    /// can then skip the `NSWorkspace.openApplication` fallback (which would
    /// otherwise race and reset focus to the app's last-active window rather
    /// than the one we just raised).
    @discardableResult
    static func raiseWindow(pid: pid_t, wid: CGWindowID) -> Bool {
        guard wid != 0 else { return false }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard let getPSN = getProcessForPIDFn, getPSN(pid, &psn) == noErr else { return false }
        guard let setFront = setFrontProcFn, let postEvent = postEventFn else { return false }

        // mode 2 = userGenerated — required for the Space switch to occur.
        let setErr = setFront(&psn, wid, 2)

        // Post a synthetic event so the window server promotes our raise
        // request. Without this, fullscreen windows often stay backgrounded.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x0d
        bytes[0x3a] = 0x80
        var widLE = wid
        withUnsafeBytes(of: &widLE) { src in
            for i in 0..<4 { bytes[0x3c + i] = src[i] }
        }
        bytes[0x20] = 0x02
        let postErr = bytes.withUnsafeMutableBufferPointer { buf -> CGError in
            postEvent(&psn, buf.baseAddress!)
        }
        return setErr == .success && postErr == .success
    }
}
