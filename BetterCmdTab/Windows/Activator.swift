import AppKit
import ApplicationServices

/// Direction for moving a window between displays or Spaces.
enum MoveDirection {
    case left, right, up, down
}

/// Lightweight window arrangement applied to the highlighted window without
/// leaving the switcher — tile to a screen half or corner quarter, fill the
/// screen, or recenter. Pure AX frame writes (position + size); no private
/// APIs, no window-manager entitlements. Computed against the window's current
/// screen `visibleFrame` so the menu bar / Dock are never covered.
enum WindowArrangement {
    case tileLeftHalf
    case tileRightHalf
    case tileTopLeft
    case tileTopRight
    case tileBottomLeft
    case tileBottomRight
    case maximize
    case center

    /// Side a repeated-press width cycle applies to, or nil if this arrangement
    /// isn't a left/right half (corners and maximize/center never width-cycle).
    var cyclingSide: TileSide? {
        switch self {
        case .tileLeftHalf: return .left
        case .tileRightHalf: return .right
        default: return nil
        }
    }

    /// Target Cocoa frame for `window` on `screen`, given the window's current
    /// size (used by `.center`, which preserves size). `nil` arguments fall back
    /// to the visible frame. Pure function so it can be unit-tested.
    /// Cocoa coordinates are bottom-left origin, so "top" corners sit at `midY`.
    static func frame(for arrangement: WindowArrangement, visibleFrame v: CGRect, windowSize: CGSize) -> CGRect {
        switch arrangement {
        case .tileLeftHalf:
            return CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case .tileRightHalf:
            return CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .tileTopLeft:
            return CGRect(x: v.minX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .tileTopRight:
            return CGRect(x: v.midX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .tileBottomLeft:
            return CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height / 2)
        case .tileBottomRight:
            return CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height / 2)
        case .maximize:
            return v
        case .center:
            // Keep the window's size (clamped to the visible frame) and center it.
            let w = min(windowSize.width, v.width)
            let h = min(windowSize.height, v.height)
            return CGRect(x: v.minX + (v.width - w) / 2, y: v.minY + (v.height - h) / 2, width: w, height: h)
        }
    }

    // MARK: - Repeated-press width cycle (½ → ⅔ → ⅓)

    enum TileSide { case left, right }

    /// Width fractions a left/right tile steps through on repeated presses when
    /// "cycle tile widths" is on: half → two-thirds → one-third → half…
    static let widthCycle: [CGFloat] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0]

    /// Full-height tile flush to `side` at width `fraction` of the visible frame.
    static func tileFrame(side: TileSide, fraction: CGFloat, visibleFrame v: CGRect) -> CGRect {
        let w = v.width * fraction
        let x = side == .left ? v.minX : v.maxX - w
        return CGRect(x: x, y: v.minY, width: w, height: v.height)
    }

}

/// Tracks the repeated-press width cycle (½ → ⅔ → ⅓) per window so it advances
/// reliably on *every* window — including apps that don't honor an exact AX size
/// write (min/max constraints, character-cell increments, fixed-height panels).
/// Earlier logic re-derived the position from the window's resulting frame, so a
/// window that landed even slightly off "full-height flush half" looked untiled
/// and the cycle reset to ½ on each press. We instead remember the index we last
/// applied and advance it whenever the same window is tiled to the same side.
@MainActor
enum TileCycler {
    private static var lastWindowId: CGWindowID = 0
    private static var lastSide: WindowArrangement.TileSide?
    private static var lastIndex = 0

    /// Clear cycle state so the next tile press restarts at ½. Called when a
    /// non-cycling arrangement (maximize / center / a corner) intervenes — so
    /// tile-left → maximize → tile-left restarts at ½ rather than resuming a
    /// stale index — and used as a test seam.
    static func reset() {
        lastWindowId = 0
        lastSide = nil
        lastIndex = 0
    }

    /// Width fraction to apply for tiling `windowId` to `side`. Re-tiling the same
    /// window to the same side steps through `WindowArrangement.widthCycle`; a
    /// different window, a different side, or the first press starts at ½.
    /// `windowId == 0` means the window id couldn't be resolved (see
    /// `PrivateAPI.cgWindowId`); treat it as non-continuable so two distinct
    /// unidentifiable windows never inherit each other's cycle position.
    static func nextFraction(windowId: CGWindowID, side: WindowArrangement.TileSide) -> CGFloat {
        let cycle = WindowArrangement.widthCycle
        let continuing = windowId != 0 && side == lastSide && windowId == lastWindowId
        let index = continuing ? (lastIndex + 1) % cycle.count : 0
        lastWindowId = windowId
        lastSide = side
        lastIndex = index
        return cycle[index]
    }
}

/// Remembers each window's frame from BEFORE its most recent arrange / move so a
/// "restore previous size" chord (⌃⌘⌫ by default) can put it back — e.g.
/// maximize → tile-left → restore returns the maximized frame. Keyed by
/// `CGWindowID` (stable across AX calls, the same key `TileCycler` uses).
/// `wasFullscreen` is captured too, so restoring a window that was in native full
/// screen re-enters full screen instead of merely resizing. Pure state container
/// so the save/restore decision is unit-testable.
@MainActor
enum PreviousFrameStore {
    struct Saved: Equatable {
        let cocoaRect: CGRect
        let wasFullscreen: Bool
    }
    private static var frames: [CGWindowID: Saved] = [:]
    /// Cap so a long session can't grow the table unbounded. Window ids are
    /// recycled by the WindowServer, so an evicted entry only costs one missed
    /// restore; eviction is arbitrary-key (a stale id is as good as any to drop).
    static let maxEntries = 64

    static func save(windowId: CGWindowID, cocoaRect: CGRect, wasFullscreen: Bool) {
        guard windowId != 0 else { return }
        if frames[windowId] == nil, frames.count >= maxEntries, let victim = frames.keys.first {
            frames.removeValue(forKey: victim)
        }
        frames[windowId] = Saved(cocoaRect: cocoaRect, wasFullscreen: wasFullscreen)
    }

    static func saved(for windowId: CGWindowID) -> Saved? {
        windowId == 0 ? nil : frames[windowId]
    }

    /// Test seam / cleanup.
    static func reset() { frames.removeAll() }
}

enum Activator {
    private static let finderBundleID = "com.apple.finder"

    /// The app that was frontmost when `hideAllApps()` last ran, so `showAllApps()`
    /// can raise it back on top (the window the user hid everything from). Pid for
    /// the same-session fast path, bundleID as a fallback if the app was relaunched.
    /// Nil once consumed or when nothing qualified.
    private static var lastHideFrontmost: (pid: pid_t, bundleID: String?)?

    /// Pure: choose which running pid `showAllApps()` should raise last, given the
    /// remembered hide-time identity and the live running set. Match by pid first
    /// (same session — but only if the bundleID still agrees, guarding pid reuse),
    /// then by bundleID (app relaunched under a new pid). Returns nil when nothing
    /// was remembered or it's gone, so the caller leaves focus as-is. Operates on
    /// plain tuples so it's unit-testable without `NSRunningApplication`.
    static func showAllRaisePid(
        remembered: (pid: pid_t, bundleID: String?)?,
        running: [(pid: pid_t, bundleID: String?, terminated: Bool)]
    ) -> pid_t? {
        guard let remembered else { return nil }
        if let hit = running.first(where: { $0.pid == remembered.pid && !$0.terminated }),
           remembered.bundleID == nil || hit.bundleID == remembered.bundleID {
            return hit.pid
        }
        if let bid = remembered.bundleID {
            return running.first(where: { $0.bundleID == bid && !$0.terminated })?.pid
        }
        return nil
    }

    /// Focus the app with the given bundle ID, launching it if it isn't running.
    /// Backs the direct-activation hotkeys (jump straight to a chosen app).
    static func activateOrLaunch(bundleID: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            activateApp(running)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    static func activateApp(_ app: NSRunningApplication) {
        if app.isHidden {
            app.unhide()
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        var windowsValue: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
        let windows = (windowsValue as? [AXUIElement]) ?? []
        if windows.isEmpty {
            openFreshWindow(for: app)
            return
        }
        for window in windows {
            var minimizedValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
            if (minimizedValue as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                break
            }
        }
        bringToFront(app)
    }

    /// `instantSpace`: when the target window lives on another Space or in full
    /// screen, jump there with no slide animation (private SkyLight) before
    /// raising. No-op when the window is already on the current Space.
    static func activate(_ row: SwitcherRow, instantSpace: Bool = false) {
        switch row.subject {
        case .launchable(let installed):
            launch(installed)
        case .running(let app):
            activateRunning(app: app, window: row.window, isFullscreen: row.isFullscreen, instantSpace: instantSpace)
        case .recentlyClosed(let entry):
            reopen(entry)
        }
    }

    /// Launch a not-yet-running app discovered by `InstalledAppsIndex`.
    private static func launch(_ installed: InstalledApp) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: installed.url, configuration: config) { _, _ in }
    }

    /// Reopen a recently closed (i.e. quit) app: relaunch it, or just activate
    /// it if it's somehow already running again. Recently-closed entries are
    /// app-level only, so there's no per-document/window restore here.
    private static func reopen(_ entry: RecentEntry) {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: entry.bundleID).first {
            activateProcess(running)
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        }
    }

    private static func activateRunning(app: NSRunningApplication, window: AXUIElement?, isFullscreen: Bool, instantSpace: Bool) {
        let pid = app.processIdentifier

        if app.isHidden {
            app.unhide()
        }

        guard let window else {
            if isFullscreen {
                bringToFront(app)
            } else {
                openFreshWindow(for: app)
            }
            return
        }

        // Parity with `activateApp`/`focusedWindow`: cap AX messaging so a wedged
        // target can't stall the (main-thread) raise + focus writes below.
        AXUIElementSetMessagingTimeout(window, 0.2)

        var minimizedValue: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
        if (minimizedValue as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        let wid = PrivateAPI.cgWindowId(of: window)

        // Jump to the window's Space instantly (no slide) before raising, so the
        // raise lands on the now-current Space instead of animating across. This
        // posts a synthetic Dock-swipe (see PrivateAPI.switchToSpace); when it
        // fires we must NOT also do the cross-Space `raiseWindow` below, whose
        // `_SLPS…` raise can win the race and animate-switch past the target.
        let postedSpaceSwitch = instantSpace && wid != 0 && PrivateAPI.switchToSpace(ofWindow: wid)

        // Order matches process activation first (synchronous
        // path via NSRunningApplication.activate), then per-window raise via
        // AX + SLPS. `NSWorkspace.openApplication` was racing — its async
        // completion fired after our raise and overrode focus with the app's
        // last-active window.
        activateProcess(app)

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)

        if wid != 0 && !postedSpaceSwitch {
            PrivateAPI.raiseWindow(pid: pid, wid: wid)
        }

        // Non-AppKit windowing (Ghostty/Alacritty/Wezterm GPU-rendered apps)
        // doesn't auto-route keyboard focus on NSApplication activation —
        // it listens for AX focus changes. Write directly; we're already
        // post-activation so the AX server accepts.
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        // `activateProcess` (NSRunningApplication.activate) brings the app forward
        // asynchronously; its effect can land *after* the writes above and
        // re-select the app's last-used window — the app then shows active in the
        // menu bar while our target window never takes key focus (the intermittent
        // "switched app but wrong/no window focused" bug). Re-assert raise + focus
        // once activation has settled, but only while our target is still frontmost
        // so we never yank focus the user may have since moved elsewhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// Activate a specific tab inside `window`. Same window-bringing steps as
     /// `activateRunning`, then press the tab's AX element so the host app
     /// selects it. Some browsers (Chrome, Arc) respond to `kAXPressAction`;
     /// others (Safari for non-current tabs) only flip selection via the
     /// `kAXSelectedAttribute` write. Try the press first, then the attribute —
     /// neither call short-circuits, so doing both is safe.
    static func activateTab(in app: NSRunningApplication, window: AXUIElement, tab: AXUIElement, instantSpace: Bool) {
        let pid = app.processIdentifier

        if app.isHidden {
            app.unhide()
        }

        var minimizedValue: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
        if (minimizedValue as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        let wid = PrivateAPI.cgWindowId(of: window)
        let postedSpaceSwitch = instantSpace && wid != 0 && PrivateAPI.switchToSpace(ofWindow: wid)

        activateProcess(app)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if wid != 0 && !postedSpaceSwitch {
            PrivateAPI.raiseWindow(pid: pid, wid: wid)
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        AXUIElementPerformAction(tab, kAXPressAction as CFString)
        AXUIElementSetAttributeValue(tab, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    }

    private static func activateProcess(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            _ = app.activate(from: NSRunningApplication.current, options: [])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private static func bringToFront(_ app: NSRunningApplication, completion: (() -> Void)? = nil) {
        if let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            cfg.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                completion?()
            }
            return
        }
        if #available(macOS 14.0, *) {
            _ = app.activate(from: NSRunningApplication.current, options: [])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        completion?()
    }

    private static func openFreshWindow(for app: NSRunningApplication) {
        if app.bundleIdentifier == finderBundleID {
            openNewFinderWindow()
            bringToFront(app)
            return
        }
        guard let url = app.bundleURL else {
            bringToFront(app)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private static func openNewFinderWindow() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([home], withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: config) { _, _ in }
    }

    static func closeWindow(_ row: SwitcherRow) {
        guard let window = row.window, let pid = row.pid else { return }
        let isFullscreen = row.isFullscreen

        // Acting on our own window (the Settings window now appears in the
        // switcher): the AX press runs in-process and drives NSWindow /
        // window-management code, which must execute on the main thread —
        // running it off-main trips the main-thread checker and crashes the
        // whole app. `DispatchQueue.main` guarantees the real main thread;
        // a `Task { @MainActor }` would NOT, because the awaited
        // `nonisolated async` press hops back onto the generic executor
        // (SE-0338). Our own window's close button is available immediately,
        // so no retry is needed. Cross-process targets stay off-main.
        if pid == getpid() {
            DispatchQueue.main.async {
                Self.performCloseButtonPress(window: window)
            }
            return
        }

        Task.detached(priority: .userInitiated) {
            if isFullscreen {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                let wid = PrivateAPI.cgWindowId(of: window)
                if wid != 0 {
                    PrivateAPI.raiseWindow(pid: pid, wid: wid)
                }
                // Space transition typically ~400ms on Apple Silicon. 450ms
                // gives headroom without blocking a worker thread.
                try? await Task.sleep(nanoseconds: 450_000_000)
                postKeyShortcut(pid: pid, keyCode: 13, axModifiers: 0)
                return
            }

            await pressCloseButton(window: window, pid: pid, attempts: 3)
        }
    }

    private static func pressCloseButton(window: AXUIElement, pid: pid_t, attempts: Int) async {
        for i in 0..<attempts {
            if performCloseButtonPress(window: window) { return }
            if i < attempts - 1 {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        // Fallback for windows that don't expose an AX close button (System
        // Settings panes, the Accessibility permission window, some dialogs):
        // focus the window, then post ⌘W to the owning app.
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let wid = PrivateAPI.cgWindowId(of: window)
        if wid != 0 {
            PrivateAPI.raiseWindow(pid: pid, wid: wid)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        postKeyShortcut(pid: pid, keyCode: 13, axModifiers: 0) // ⌘W
    }

    /// Single synchronous attempt to press a window's AX close button. Returns
    /// true if the button was found and pressed. Safe to call on any thread for
    /// a cross-process window; for our OWN window the caller must be on the
    /// main thread (it drives NSWindow teardown in-process).
    @discardableResult
    private static func performCloseButtonPress(window: AXUIElement) -> Bool {
        var buttonValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonValue)
        guard err == .success, CFGetTypeID(buttonValue as CFTypeRef) == AXUIElementGetTypeID() else {
            return false
        }
        return AXUIElementPerformAction(buttonValue as! AXUIElement, kAXPressAction as CFString) == .success
    }

    static func minimizeWindow(_ row: SwitcherRow) {
        guard let window = row.window, let app = row.app else { return }
        let wasMinimized = row.isMinimized

        let apply = {
            if wasMinimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                DispatchQueue.main.async {
                    if #available(macOS 14.0, *) {
                        _ = app.activate(from: NSRunningApplication.current, options: [])
                    } else {
                        app.activate(options: [.activateIgnoringOtherApps])
                    }
                }
                return
            }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }

        // Mutating AX state on our own window must happen on the main thread
        // (same window-management constraint as closeWindow). Other apps stay
        // off-main so a slow cross-process AX call never blocks ours.
        if app.processIdentifier == getpid() {
            DispatchQueue.main.async(execute: apply)
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: apply)
        }
    }

    private static func postKeyShortcut(pid: pid_t, keyCode: CGKeyCode, axModifiers: Int) {
        let src = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }

        var flags: CGEventFlags = []
        if (axModifiers & 8) == 0 { flags.insert(.maskCommand) }
        if (axModifiers & 1) != 0 { flags.insert(.maskShift) }
        if (axModifiers & 2) != 0 { flags.insert(.maskAlternate) }
        if (axModifiers & 4) != 0 { flags.insert(.maskControl) }

        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }

    /// Zoom (green-button maximize) the row's window by pressing its AX zoom
    /// button. Apps without a zoom button (some dialogs/utilities) are no-ops.
    static func zoomWindow(_ row: SwitcherRow) {
        guard let window = row.window, let app = row.app else { return }
        let apply = {
            var buttonValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(window, kAXZoomButtonAttribute as CFString, &buttonValue)
            guard err == .success, CFGetTypeID(buttonValue as CFTypeRef) == AXUIElementGetTypeID() else { return }
            AXUIElementPerformAction(buttonValue as! AXUIElement, kAXPressAction as CFString)
        }
        // Our own window must mutate on the main thread (window-management
        // constraint, same as close/minimize); other apps stay off-main.
        if app.processIdentifier == getpid() {
            DispatchQueue.main.async(execute: apply)
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: apply)
        }
    }

    /// Toggle native (green-button) full screen on the row's window via the AX
    /// `AXFullScreen` attribute — the same attribute the window scan reads.
    /// Direction comes from `row.isFullscreen` (captured at scan time). Our own
    /// window mutates on the main thread (window-management constraint, same as
    /// close/minimize); other apps stay off-main so a slow cross-process AX write
    /// never blocks ours. No-op for rows without a window (placeholder /
    /// launchable) or apps that don't expose the attribute.
    static func toggleFullscreen(_ row: SwitcherRow) {
        guard let window = row.window, let app = row.app else { return }
        let target: CFBoolean = row.isFullscreen ? kCFBooleanFalse : kCFBooleanTrue
        let apply = {
            _ = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, target)
        }
        if app.processIdentifier == getpid() {
            DispatchQueue.main.async(execute: apply)
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: apply)
        }
    }

    static func hideApp(_ row: SwitcherRow) {
        guard let app = row.app else { return }
        if app.isHidden {
            app.unhide()
            if #available(macOS 14.0, *) {
                _ = app.activate(from: NSRunningApplication.current, options: [])
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        } else {
            app.hide()
        }
    }

    /// Hide every regular (Dock-presence) app, clearing the screen to the desktop.
    /// A single, idempotent action — NOT a toggle. Apps the user added to "Keep
    /// apps visible" are skipped (read straight from `UserDefaults`; key mirrors
    /// `Preferences.Keys.hideAllExcludedBundleIDs`, so the two must stay in sync).
    ///
    /// Other apps are hidden with `.hide()`, background first (occluded — no flash,
    /// no focus change) then the frontmost last, so only one transition shows.
    ///
    /// Finder is handled differently. It can't be hidden with `.hide()`: macOS
    /// keeps one app active and falls back to Finder, so hiding it just makes the
    /// system re-promote (un-hide) it — that read as a toggle and left its window
    /// on screen. Instead we MINIMIZE Finder's windows via Accessibility (already
    /// granted), clearing them from the desktop while Finder stays the active
    /// desktop owner — no toggle. Skipped when the user excluded Finder.
    /// `showAllApps()` un-minimizes them again.
    static func hideAllApps() {
        let excluded = Set(UserDefaults.standard.stringArray(forKey: "Switcher.hideAllExcludedBundleIDs") ?? [])
        let selfPid = getpid()
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPid = frontApp?.processIdentifier
        // Remember the hide-time frontmost app so `showAllApps()` can raise it back
        // on top (the window the user hid everything from). Skip self; otherwise
        // record it even if it's in the keep-visible set — it stays the app the
        // user wants to return to. Require a bundleID (real user apps always have
        // one): it lets the show-side pid match confirm identity, so a recycled pid
        // belonging to a different process can't be raised by mistake. Always
        // assign (value or nil) so a stale entry from a previous hide can't be reused.
        if let frontApp, frontApp.activationPolicy == .regular,
           frontApp.processIdentifier != selfPid,
           let bid = frontApp.bundleIdentifier {
            lastHideFrontmost = (frontApp.processIdentifier, bid)
        } else {
            lastHideFrontmost = nil
        }
        let running = NSWorkspace.shared.runningApplications
        let targets = running.filter { app in
            app.activationPolicy == .regular
                && app.processIdentifier != selfPid
                && app.bundleIdentifier != finderBundleID
                && !app.isHidden
                && !(app.bundleIdentifier.map(excluded.contains) ?? false)
        }
        // frontmost hidden last (its hide is the only visible transition).
        for app in targets.sorted(by: { ($1.processIdentifier == frontPid ? 1 : 0) > ($0.processIdentifier == frontPid ? 1 : 0) }) {
            app.hide()
        }
        if !excluded.contains(finderBundleID),
           let finderPid = running.first(where: { $0.bundleIdentifier == finderBundleID })?.processIdentifier {
            DispatchQueue.global(qos: .userInitiated).async {
                setFinderWindowsMinimized(true, pid: finderPid)
            }
        }
    }

    /// Unhide every regular app currently hidden (by `hideAllApps()` or a manual
    /// ⌘H) and un-minimize Finder's windows (the counterpart to hideAllApps()'s
    /// Finder minimize). Raises the app that was frontmost when `hideAllApps()`
    /// last ran *last*, so the window the user hid everything from returns on top.
    /// When there's no remembered hide-time app (show-all without a prior shortcut
    /// hide, or after a relaunch), it activates nothing — the apps just reappear
    /// and focus stays put, the old stateless behaviour.
    static func showAllApps() {
        let running = NSWorkspace.shared.runningApplications
        let runningIDs = running.map {
            (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, terminated: $0.isTerminated)
        }
        let targetPid = showAllRaisePid(remembered: lastHideFrontmost, running: runningIDs)
        lastHideFrontmost = nil
        let raiseTarget = targetPid.flatMap { pid in running.first { $0.processIdentifier == pid } }
        // Unhide everything except the raise target first, so the target's
        // activation below is the final, on-top transition (no focus thrash).
        for app in running
        where app.activationPolicy == .regular && app.isHidden && app.processIdentifier != targetPid {
            app.unhide()
        }
        if let finderPid = running.first(where: { $0.bundleIdentifier == finderBundleID })?.processIdentifier {
            DispatchQueue.global(qos: .userInitiated).async {
                setFinderWindowsMinimized(false, pid: finderPid)
            }
        }
        // Raise the hide-time source app last so it ends frontmost. Unhide it first
        // if it was hidden. activateProcess() is the same app-level raise the rest
        // of the file uses.
        if let raiseTarget {
            if raiseTarget.isHidden { raiseTarget.unhide() }
            activateProcess(raiseTarget)
        }
    }

    /// Set the minimized state of every window of `pid` (used for Finder, which
    /// can't be `.hide()`'d — see `hideAllApps()`). Cross-process AX, so call
    /// off-main; a short messaging timeout keeps a wedged Finder from stalling.
    private static func setFinderWindowsMinimized(_ minimized: Bool, pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return }
        let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        for window in windows {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value)
        }
    }

    static func quitApp(_ row: SwitcherRow) {
        guard let app = row.app else { return }
        if app.bundleIdentifier == finderBundleID {
            return
        }
        app.terminate()
    }

    /// SIGKILL the row's app. Use when the AppleEvent that `terminate()` sends
    /// is being ignored (hung event loop, runaway script). Finder is guarded
    /// like `quitApp` — killing it would log the user out via launchd respawn
    /// loops on some setups.
    static func forceQuitApp(_ row: SwitcherRow) {
        guard let app = row.app else { return }
        if app.bundleIdentifier == finderBundleID {
            return
        }
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }

    // MARK: - Move window between displays / Spaces

    /// Resolve the focused window of the system's frontmost app. The switcher
    /// panel is a non-activating `NSPanel`, so this still returns the user's
    /// real window while the switcher is open — window-management chords act on
    /// the *current* window, not the highlighted switcher row.
    /// Nil if there's no frontmost app, it's us, or it has no focused window.
    static func frontmostFocusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindow(pid: app.processIdentifier)
    }

    /// Focused window of `pid` via AX. A short messaging timeout keeps a wedged
    /// app from stalling the caller. Safe to call off the main thread: the AX
    /// request is serviced in the target process and only the (thread-safe)
    /// AXUIElement crosses back — so the switcher can resolve it during the
    /// primed phase without blocking the reveal critical path. Nil for self, an
    /// invalid pid, or no focused window.
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard pid > 0, pid != getpid() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let windowValue = focused,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        return (windowValue as! AXUIElement)
    }

    /// The window's bounds in **Accessibility coordinates** (top-left origin of
    /// the primary display, y-down) read synchronously via the AX API. Returns
    /// nil if the attributes are missing/typed wrong. Call OFF the main thread —
    /// `AXUIElementCopyAttributeValue` can block up to the messaging timeout on a
    /// busy app. The caller converts to Cocoa coordinates and picks a screen.
    static func axBounds(of window: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              CFGetTypeID(posRef as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// Arrange an explicit window on its current screen. Used by the switcher
    /// for the window it captured at open time (see `openFocusedWindow`).
    /// Always on main: `applyArrangement` reads `NSScreen.screens` (documented
    /// main-thread only — off-main access throws `NSInternalInconsistencyException`
    /// on macOS Tahoe) and the MainActor cycle/pref state. The AX writes are cheap.
    static func arrange(window: AXUIElement, _ arrangement: WindowArrangement) {
        DispatchQueue.main.async {
            Self.applyArrangement(window: window, arrangement: arrangement)
        }
    }

    /// Move an explicit window to the adjacent display in `direction`. On main for
    /// the same `NSScreen.screens` main-thread reason as `arrange(window:)`.
    static func moveToDisplay(window: AXUIElement, direction: MoveDirection) {
        DispatchQueue.main.async {
            Self.repositionToAdjacentDisplay(window: window, direction: direction)
        }
    }

    /// Arrange the frontmost app's focused window on its current screen. Backs
    /// the global window-management hotkeys (#7) when the switcher is closed —
    /// here a live `frontmostApplication` read is correct because no panel is up.
    static func arrangeFrontmostWindow(_ arrangement: WindowArrangement) {
        guard let window = frontmostFocusedWindow() else { return }
        arrange(window: window, arrangement)
    }

    /// Move the frontmost app's focused window to the adjacent display. Global
    /// (switcher-closed) counterpart of `moveToDisplay(window:direction:)`.
    static func moveFrontmostWindowToDisplay(direction: MoveDirection) {
        guard let window = frontmostFocusedWindow() else { return }
        moveToDisplay(window: window, direction: direction)
    }

    /// Restore an explicit window to the frame snapshotted before its last
    /// arrange/move (see `PreviousFrameStore`). No-op if nothing was saved for it.
    /// On main for the same `NSScreen.screens` reason as `arrange(window:)`.
    static func restoreFrame(window: AXUIElement) {
        DispatchQueue.main.async {
            Self.applyRestore(window: window)
        }
    }

    /// Restore the frontmost app's focused window. Global (switcher-closed)
    /// counterpart of `restoreFrame(window:)`.
    static func restoreFrontmostWindowFrame() {
        guard let window = frontmostFocusedWindow() else { return }
        restoreFrame(window: window)
    }

    private static func applyArrangement(window: AXUIElement, arrangement: WindowArrangement) {
        guard !NSScreen.screens.isEmpty else { return }
        let mainHeight = NSScreen.screens[0].frame.maxY

        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              CFGetTypeID(posRef as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef as CFTypeRef) == AXValueGetTypeID() else { return }
        var axPos = CGPoint.zero
        var axSize = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &axPos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize)

        let cocoaRect = CGRect(
            x: axPos.x,
            y: mainHeight - axPos.y - axSize.height,
            width: axSize.width,
            height: axSize.height
        )
        guard let screen = screenContaining(rect: cocoaRect) else { return }
        // Snapshot the pre-arrange frame so ⌃⌘⌫ can restore it (see
        // `PreviousFrameStore` / `restoreFrame`). Captured here — after we know an
        // arrange will actually run — keyed by the window's CGWindowID.
        let preArrangeId = PrivateAPI.cgWindowId(of: window)
        let wasFullscreen = isFullscreen(window: window)
        MainActor.assumeIsolated {
            PreviousFrameStore.save(windowId: preArrangeId, cocoaRect: cocoaRect, wasFullscreen: wasFullscreen)
        }
        let v = screen.visibleFrame
        // Left/right halves width-cycle (½→⅔→⅓) on repeated presses when the
        // user enabled it; corners/maximize/center always use their fixed frame.
        // `applyArrangement` only runs inside `DispatchQueue.main.async`, so the
        // MainActor reads (pref + cycle state) are safe via `assumeIsolated`. The
        // cycle is tracked by window id, not re-derived from the resulting frame,
        // so it advances even on apps that don't honor an exact size write.
        let target: CGRect
        if let side = arrangement.cyclingSide,
           MainActor.assumeIsolated({ Preferences.shared.cycleTileWidths }) {
            let wid = preArrangeId
            let fraction = MainActor.assumeIsolated { TileCycler.nextFraction(windowId: wid, side: side) }
            target = WindowArrangement.tileFrame(side: side, fraction: fraction, visibleFrame: v)
        } else {
            // A non-cycling arrangement (corner / maximize / center) breaks the
            // tile cycle, so the next tile-left/right restarts at ½ rather than
            // resuming a stale index.
            MainActor.assumeIsolated { TileCycler.reset() }
            target = WindowArrangement.frame(for: arrangement, visibleFrame: v, windowSize: axSize)
        }

        // Order: size first, then position. Some apps clamp position against the
        // *old* size; setting size first lets the position land correctly.
        var newSize = CGSize(width: target.width, height: target.height)
        if let sizeValue = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        var newAXPos = CGPoint(x: target.minX, y: mainHeight - (target.minY + target.height))
        if let posValue = AXValueCreate(.cgPoint, &newAXPos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        // Re-assert size after the move: an app that resisted the first resize
        // (min-size constraints relative to the old origin) often accepts it now.
        if let sizeValue = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private static func repositionToAdjacentDisplay(window: AXUIElement, direction: MoveDirection) {
        guard !NSScreen.screens.isEmpty else { return }
        // AX coordinates are top-left origin (y down) anchored at the main screen;
        // Cocoa screen frames are bottom-left origin. `mainHeight` bridges them.
        let mainHeight = NSScreen.screens[0].frame.maxY

        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              CFGetTypeID(posRef as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef as CFTypeRef) == AXValueGetTypeID() else { return }
        var axPos = CGPoint.zero
        var axSize = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &axPos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize)

        let cocoaRect = CGRect(
            x: axPos.x,
            y: mainHeight - axPos.y - axSize.height,
            width: axSize.width,
            height: axSize.height
        )
        guard let current = screenContaining(rect: cocoaRect),
              let target = adjacentScreen(to: current, direction: direction) else { return }

        // Snapshot the pre-move frame so ⌃⌘⌫ can return the window to the display
        // it came from (see `PreviousFrameStore`).
        let preMoveId = PrivateAPI.cgWindowId(of: window)
        let wasFullscreen = isFullscreen(window: window)
        MainActor.assumeIsolated {
            PreviousFrameStore.save(windowId: preMoveId, cocoaRect: cocoaRect, wasFullscreen: wasFullscreen)
        }

        let cv = current.visibleFrame
        let tv = target.visibleFrame
        let relX = cv.width > 0 ? (cocoaRect.minX - cv.minX) / cv.width : 0
        let relY = cv.height > 0 ? (cocoaRect.minY - cv.minY) / cv.height : 0
        var newX = tv.minX + relX * tv.width
        var newY = tv.minY + relY * tv.height
        // Clamp so the window stays on-screen (no resize).
        newX = min(max(newX, tv.minX), max(tv.minX, tv.maxX - axSize.width))
        newY = min(max(newY, tv.minY), max(tv.minY, tv.maxY - axSize.height))

        var newAXPos = CGPoint(x: newX, y: mainHeight - (newY + axSize.height))
        guard let value = AXValueCreate(.cgPoint, &newAXPos) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    /// Read a window's native full-screen state. Best-effort: any AX failure or a
    /// window that doesn't expose `AXFullScreen` reads as not-full-screen.
    private static func isFullscreen(window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &ref) == .success,
              let flag = ref as? Bool else { return false }
        return flag
    }

    /// Put `window` back to its `PreviousFrameStore` snapshot. Re-enters full
    /// screen if it was full-screen before; otherwise exits full screen (if it's
    /// in it now) and writes the saved position + size. Same size-first ordering
    /// and Cocoa↔AX flip as `applyArrangement`.
    private static func applyRestore(window: AXUIElement) {
        guard !NSScreen.screens.isEmpty else { return }
        let wid = PrivateAPI.cgWindowId(of: window)
        guard let saved = MainActor.assumeIsolated({ PreviousFrameStore.saved(for: wid) }) else { return }

        if saved.wasFullscreen {
            if !isFullscreen(window: window) {
                _ = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
            }
            return
        }
        // A full-screen window ignores frame writes — drop out of it first. The
        // exit animates, so the position/size below is best-effort on that frame;
        // the common restore (un-maximize, un-tile) isn't full-screen and lands
        // immediately.
        if isFullscreen(window: window) {
            _ = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        }

        let mainHeight = NSScreen.screens[0].frame.maxY
        let target = saved.cocoaRect
        var newSize = CGSize(width: target.width, height: target.height)
        if let sizeValue = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        var newAXPos = CGPoint(x: target.minX, y: mainHeight - (target.minY + target.height))
        if let posValue = AXValueCreate(.cgPoint, &newAXPos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        // Re-assert size (apps that clamped against the old origin often accept it
        // now), mirroring `applyArrangement`.
        if let sizeValue = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private static func screenContaining(rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            intersectionArea(a.frame, rect) < intersectionArea(b.frame, rect)
        }
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        return max(0, i.width) * max(0, i.height)
    }

    private static func adjacentScreen(to current: NSScreen, direction: MoveDirection) -> NSScreen? {
        let c = CGPoint(x: current.frame.midX, y: current.frame.midY)
        let candidates = NSScreen.screens.filter { $0 != current }.filter { s in
            let p = CGPoint(x: s.frame.midX, y: s.frame.midY)
            switch direction {
            case .left: return p.x < c.x
            case .right: return p.x > c.x
            case .up: return p.y > c.y     // Cocoa y increases upward
            case .down: return p.y < c.y
            }
        }
        return candidates.min { a, b in
            let pa = CGPoint(x: a.frame.midX, y: a.frame.midY)
            let pb = CGPoint(x: b.frame.midX, y: b.frame.midY)
            switch direction {
            case .left, .right: return abs(pa.x - c.x) < abs(pb.x - c.x)
            case .up, .down: return abs(pa.y - c.y) < abs(pb.y - c.y)
            }
        }
    }
}
