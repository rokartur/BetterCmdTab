import AppKit
import ApplicationServices

/// Direction for moving a window between displays or Spaces.
enum MoveDirection {
    case left, right, up, down
}

/// Lightweight window arrangement applied to the highlighted window without
/// leaving the switcher — tile to a screen half, fill the screen, or recenter.
/// Pure AX frame writes (position + size); no private APIs, no window-manager
/// entitlements. Computed against the window's current screen `visibleFrame`
/// so the menu bar / Dock are never covered.
enum WindowArrangement {
    case tileLeftHalf
    case tileRightHalf
    case maximize
    case center

    /// Target Cocoa frame for `window` on `screen`, given the window's current
    /// size (used by `.center`, which preserves size). `nil` arguments fall back
    /// to the visible frame. Pure function so it can be unit-tested.
    static func frame(for arrangement: WindowArrangement, visibleFrame v: CGRect, windowSize: CGSize) -> CGRect {
        switch arrangement {
        case .tileLeftHalf:
            return CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case .tileRightHalf:
            return CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .maximize:
            return v
        case .center:
            // Keep the window's size (clamped to the visible frame) and center it.
            let w = min(windowSize.width, v.width)
            let h = min(windowSize.height, v.height)
            return CGRect(x: v.minX + (v.width - w) / 2, y: v.minY + (v.height - h) / 2, width: w, height: h)
        }
    }
}

enum Activator {
    private static let finderBundleID = "com.apple.finder"

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
        AXUIElementPerformAction(buttonValue as! AXUIElement, kAXPressAction as CFString)
        return true
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

    /// Move the row's window to the adjacent display in `direction`, preserving
    /// its relative position within the screen and clamping it to fit. Uses the
    /// stable Accessibility position API — no private symbols.
    static func moveWindowToDisplay(_ row: SwitcherRow, direction: MoveDirection) {
        guard let window = row.window, let _ = row.app else { return }
        // Run on main regardless of target pid: `repositionToAdjacentDisplay`
        // reads `NSScreen.screens`, which Apple documents as main-thread only.
        // Under macOS Tahoe (26) off-main `NSScreen.screens` access triggers
        // an `NSInternalInconsistencyException` (layout engine modified from a
        // background thread) the next time AppKit lays out — sometimes
        // immediately, sometimes on a later reveal. The AX position write is
        // cheap (microseconds) so keeping the whole call on main has no
        // latency cost worth chasing.
        DispatchQueue.main.async {
            Self.repositionToAdjacentDisplay(window: window, direction: direction)
        }
    }

    /// Arrange the row's window on its current screen (tile half / maximize /
    /// center). Runs on main for the same `NSScreen.screens` main-thread reason
    /// as `moveWindowToDisplay`. The AX position+size writes are cheap.
    static func arrangeWindow(_ row: SwitcherRow, _ arrangement: WindowArrangement) {
        guard let window = row.window, row.app != nil else { return }
        DispatchQueue.main.async {
            Self.applyArrangement(window: window, arrangement: arrangement)
        }
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
        let target = WindowArrangement.frame(for: arrangement, visibleFrame: screen.visibleFrame, windowSize: axSize)

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
