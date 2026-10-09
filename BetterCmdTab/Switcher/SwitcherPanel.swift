import AppKit
import Combine
import ObjectiveC
import os

@MainActor
final class SwitcherPanel: NSPanel {
    /// Space behavior for this transient overlay. `.canJoinAllSpaces` alone
    /// keeps it on every Desktop and over other apps' full-screen Spaces — the
    /// app is an LSUIElement accessory, so no full-screen-auxiliary binding is
    /// needed. `.fullScreenAuxiliary` was removed for #46: it bound the panel as
    /// an auxiliary of a full-screen window's Space, so quitting that full-screen
    /// app destroyed the panel's all-Spaces membership and it went invisible on
    /// the other Spaces. `.stationary`/`.ignoresCycle` are cycling / Exposé-group
    /// flags, orthogonal to Space membership.
    static let canonicalCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .stationary,
        .ignoresCycle
    ]

    private var prefCancellable: AnyCancellable?
    /// True between `present()` and a hide. `resignKey()` reads this and `isFadingOut`, not
    /// `isVisible`: the boot prewarm orders the panel in off-screen without presenting.
    private var isPresented = false

    /// The screen the owning controller resolved for this open session. Set
    /// before `present()` so positioning matches the metrics the controller
    /// computed for the same screen. Cleared on `dismiss()`. Nil → resolve live.
    var targetScreen: NSScreen?

    /// Invoked whenever the panel is shown or relayed out (with its frame in
    /// CGEvent global / top-left-origin coordinates) and when it's hidden (with
    /// `nil`). SwitcherController forwards this to the hotkey tap so an outside
    /// click can be hit-tested off the main thread.
    var onFrameDidChange: ((CGRect?) -> Void)?

    /// Wall clock (not uptime — time asleep counts toward staleness) of the
    /// last moment the panel was on screen with known-fresh content. After a
    /// long hidden stretch WindowServer may have purged the cached layer
    /// surfaces, so trusting them on the next `present()` composites empty
    /// glass / stale rows for a beat (#146). Updated by `present()` and
    /// `dismiss()`.
    private var lastOnScreenAt = Date.timeIntervalSinceReferenceDate

    /// Hidden-for-longer-than-this triggers a full unconditional redraw in
    /// `present()`. Deliberately generous so the extra full paint never lands
    /// on rapid ⌘Tab cycles — surface purge needs sustained idleness, not
    /// seconds.
    private static let staleSurfaceThreshold: TimeInterval = 300

    /// On-screen frame a hide parked away from; `present()` restores it so the
    /// "frame unchanged → skip `setFrame`" fast path still holds. Nil when the
    /// panel isn't parked.
    private var parkedFrame: NSRect?

    /// Off-screen origin for a hidden panel (same trick as the boot prewarm).
    /// Zeroing `alphaValue` and hiding the content view isn't enough on macOS
    /// 26: the glass backdrop is composited window-server-side, so its last
    /// sampled frame — a cutout of the app that was behind us — can keep
    /// compositing over the app we just activated for as long as the window
    /// stays ordered in, which on the commit path is the whole activation
    /// (#146). Parking the window off every display puts that residue where
    /// nobody can see it, whichever of the two knobs the server ignores.
    private static let parkedOrigin = NSPoint(x: -20000, y: -20000)

    /// Move the (already invisible) panel off every display. Keeps the window
    /// ordered and key, so WindowServer focus routing is unchanged — only
    /// `orderOut` disturbs that, which is why `vanish()` can't just do it.
    private func park() {
        guard parkedFrame == nil else { return }
        parkedFrame = frame
        setFrameOrigin(Self.parkedOrigin)
    }

    /// Replace the inherited `-[NSWindow appearsActive]` getter for
    /// `SwitcherPanel` instances with a constant `true`. Dynamic NSColors used
    /// by row views (`.labelColor`, `.controlAccentColor`,
    /// `.tertiaryLabelColor`) resolve via the host window's `appearsActive`;
    /// when the panel transiently resigns key — e.g. Cmd+Q on a row terminates
    /// the frontmost app and the system briefly hands key to the next app
    /// before our `didResignKey` observer reclaims it — those colors render
    /// in their dimmed "inactive" form for one or more frames. Reclaiming key
    /// can't fully hide that gap because AppKit's appearsActive flip happens
    /// before our handler is even invoked. Overriding the getter at the ObjC
    /// runtime level forces every consumer (NSColor resolution,
    /// NSVisualEffectView/NSGlassEffectView, control drawing) to see the
    /// panel as always-active while it's on screen. NSWindow.appearsActive
    /// isn't `open` in Swift's overlay, so a Swift `override var` won't
    /// compile — runtime method replacement is the only way to intercept it.
    private static let installAppearsActiveOverride: Void = {
        let cls: AnyClass = SwitcherPanel.self
        let sel = NSSelectorFromString("appearsActive")
        guard let original = class_getInstanceMethod(cls, sel),
              let encoding = method_getTypeEncoding(original) else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        let imp = imp_implementationWithBlock(block)
        class_replaceMethod(cls, sel, imp, encoding)
    }()

    init() {
        _ = Self.installAppearsActiveOverride
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: .nonactivatingPanel,
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        titleVisibility = .hidden
        animationBehavior = .none
        collectionBehavior = Self.canonicalCollectionBehavior
        isReleasedWhenClosed = false
        animationBehavior = .none
        applyScreenSharingPolicy()
        prefCancellable = Preferences.shared.$hideFromScreenSharing
            .sink { [weak self] hide in
                guard let self else { return }
                self.applyScreenSharingPolicy(hide: hide)
            }
    }

    /// Apply the "Hide from screen sharing" preference to `sharingType`.
    /// `.none` makes the window invisible to ScreenCaptureKit, CGWindowList,
    /// and screen-sharing apps (Zoom, Meet, Teams, QuickTime). `.readOnly` is
    /// the default — captured normally.
    ///
    /// Honored by ScreenCaptureKit from macOS 14.6 onwards; on earlier
    /// versions the flag still affects CGWindowList but capture apps using
    /// SCK may still see the window. We set it unconditionally because the
    /// API itself exists since 10.0 and the no-op case is harmless.
    private func applyScreenSharingPolicy(hide: Bool? = nil) {
        let shouldHide = hide ?? Preferences.shared.hideFromScreenSharing
        sharingType = shouldHide ? .none : .readOnly
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Swallow `resignKey` while the panel is on screen. The internal
    /// `_isKey` flip has already happened by the time AppKit calls this — but
    /// `super.resignKey()` is what posts `NSWindow.didResignKeyNotification`,
    /// which NSGlassEffectView listens to in order to animate its
    /// active→inactive transition. Suppressing the notification keeps the
    /// glass backdrop from playing its dim-out animation on transient key
    /// loss (e.g. Cmd+Q on a row terminating the frontmost app). The
    /// `didResignKey` observer in SwitcherController still reclaims key on
    /// the next runloop so internal NSWindow state self-heals.
    override func resignKey() {
        // A running fade-out swallows too, so its glass doesn't dim. Past it, pass through:
        // re-keying a dismissed or vanished panel would yank focus from the commit's target.
        guard isVisible, isPresented || isFadingOut else {
            super.resignKey()
            return
        }
        // Swallow `super.resignKey()` to suppress the glass dim animation's
        // notification — but the internal `_isKey` has already flipped to false,
        // so without reclaiming, the panel stops being key: its controls (hover
        // action buttons) stop receiving clicks and keyboard focus drifts. Re-key
        // on the next runloop so the panel stays interactive while it's on screen.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.isPresented else { return }
            if !self.isKeyWindow { self.makeKeyAndOrderFront(nil) }
            // NSGlassEffectView's active look is decided window-server-side from
            // the owning app's real activation state (the in-process
            // appearsActive override can't reach it), so a transient app
            // deactivation during switching dims the glass. Re-activate while the
            // panel is on screen so it always reads as active.
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// `opacity` is the resolved per-shortcut panel opacity (#74), 30–100.
    func present(opacity: Int = 100) {
        guard let content = contentView else { return }
        // Growing/shrinking for a drill-in, a search filter or a row count change
        // can glide; a first reveal (or a re-reveal from the off-screen park)
        // must land at its final size in one frame. Captured before the un-park
        // below undoes the evidence.
        let wasPresented = isPresented
        let onScreen = isVisible && parkedFrame == nil && !content.isHidden
        let resizeAnimates = wasPresented && onScreen && SwitcherMotion.isEnabled
        let fadeIn = wasPresented ? 0 : TimeInterval(Preferences.shared.fadeInDurationMs) / 1000
        isPresented = true
        hideAfterFadeOut = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Un-park before the frame comparison so an unchanged layout still skips
        // `setFrame`; alpha is 0 here, so the move never shows.
        if let parkedFrame {
            setFrameOrigin(parkedFrame.origin)
            self.parkedFrame = nil
        }
        let fitting = Log.reveal.withIntervalSignpost("present.layout") { () -> NSSize in
            content.layoutSubtreeIfNeeded()
            return content.fittingSize
        }
        let screen = activeScreen()
        let visible = screen.visibleFrame
        // Hard safety: never let the panel extend past the visible frame, even if
        // an extreme app/window count makes the content larger than the screen.
        // The grid/preview layouts add columns to avoid this, but clamp here as a
        // backstop so the window stays on-screen rather than spilling off the top
        // and bottom.
        let size = NSSize(
            width: min(fitting.width, visible.width),
            height: min(fitting.height, visible.height)
        )
        let hanging = (content as? SwitcherStackView)?.shelfExtent ?? 0
        let origin = Self.origin(of: size, in: visible, position: Preferences.shared.verticalPosition, hanging: hanging)
        let newFrame = NSRect(origin: origin, size: size)
        if frame != newFrame {
            if resizeAnimates {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = SwitcherMotion.duration
                    context.timingFunction = SwitcherMotion.timing
                    animator().setFrame(newFrame, display: false)
                }
            } else {
                setFrame(newFrame, display: true)
            }
        }
        // Undo a hide's zeroed alpha and hidden content before ordering front (#208).
        content.isHidden = false
        let alpha = CGFloat(opacity) / 100
        if !wasPresented, fadeIn == 0 { alphaValue = alpha }
        // An on-screen panel here is mid-fade-out: fade back in from its current alpha.
        if fadeIn > 0, !onScreen { alphaValue = 0 }
        // A hide turned mouse events off for its fade-out or ordered linger.
        ignoresMouseEvents = false
        // After a long hidden stretch, don't trust cached layer contents —
        // WindowServer may have purged them, which would show as see-through
        // glass with missing rows for the first frames (#146). Redraw the whole
        // tree in this same transaction; must come after the un-hide above
        // (hidden views don't draw). Gated so rapid ⌘Tab opens never pay it.
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastOnScreenAt > Self.staleSurfaceThreshold {
            content.display()
        }
        lastOnScreenAt = now
        // The WindowServer order-front + app activation; split out so Instruments
        // shows it apart from the autolayout pass above when chasing reveal spikes.
        Log.reveal.withIntervalSignpost("present.orderFront") {
            // #46: WindowServer collapses the panel's `.canJoinAllSpaces`
            // membership to a single Space when a full-screen Space is destroyed,
            // leaving the panel invisible on every other Space (switching still
            // works). Re-stick it onto the visible Space(s) via CGS before
            // ordering front so it composites on the Space we're about to show it
            // on. Re-writing `collectionBehavior` didn't undo the collapse.
            PrivateAPI.pinWindowToVisibleSpaces(CGWindowID(windowNumber))
            makeKeyAndOrderFront(nil)
            // Activate the app while the switcher is shown. `NSGlassEffectView`'s
            // active/inactive look is decided window-server-side from the owning
            // app's real activation state — the in-process `appearsActive` override
            // can't reach it — so a non-activating accessory app's glass renders
            // dimmed unless we actually become active. The controller captured the
            // previously frontmost app first and restores it on cancel.
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        CATransaction.commit()
        if fadeIn > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeIn
                animator().alphaValue = alpha
            }
        }
        // `newFrame`, not `frame`: mid-animation the window is still catching up,
        // and the hit region has to describe where the panel is landing.
        onFrameDidChange?(Self.cgGlobalFrame(from: newFrame))
        // A non-activating panel isn't always granted key on the first
        // `makeKeyAndOrderFront` if another app is mid-activation when the switcher
        // opens; re-key on the next runloop (same approach as `resignKey`) so the
        // panel always holds key while it's on screen.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.isPresented else { return }
            if !self.isKeyWindow { self.makeKeyAndOrderFront(nil) }
        }
    }

    /// Hide the panel after its fade-out (#208), then run `cleanup`.
    func dismiss(then cleanup: @escaping () -> Void) {
        isPresented = false
        ignoresMouseEvents = true
        targetScreen = nil
        onFrameDidChange?(nil)
        fadeOut { [weak self] in
            guard let self else { return }
            self.hide(orderingOut: true)
            self.lastOnScreenAt = Date.timeIntervalSinceReferenceDate
            cleanup()
        }
    }

    /// Commit-time hide that keeps the window ordered: `dismiss()` waits for the
    /// activation's AX focus writes, and `ignoresMouseEvents` lets clicks through until then.
    func vanish() {
        isPresented = false
        ignoresMouseEvents = true
        onFrameDidChange?(nil)
        fadeOut { [weak self] in self?.hide(orderingOut: false) }
    }

    /// The hide the running fade-out ends with; nil when none is running.
    /// `present()` clears it, which is what cancels a fade-out.
    private var hideAfterFadeOut: (() -> Void)?
    var isFadingOut: Bool { hideAfterFadeOut != nil }
    /// An interrupted fade still calls its completion, at the end of the
    /// runloop turn: a later fade-out's hide must not run on that call.
    private var fadeOutGeneration = 0

    private func fadeOut(then hide: @escaping () -> Void) {
        // `dismiss()` after `vanish()`: the running fade ends with the order-out.
        if hideAfterFadeOut != nil {
            hideAfterFadeOut = hide
            return
        }
        let duration = TimeInterval(Preferences.shared.fadeOutDurationMs) / 1000
        guard duration > 0, isVisible, alphaValue > 0 else { return hide() }
        fadeOutGeneration &+= 1
        let generation = fadeOutGeneration
        hideAfterFadeOut = hide
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.endFadeOut(generation) }
        })
    }

    private func endFadeOut(_ generation: Int) {
        guard generation == fadeOutGeneration, let hide = hideAfterFadeOut else { return }
        hideAfterFadeOut = nil
        hide()
    }

    private func hide(orderingOut: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alphaValue = 0
        // The server tears the out-of-process glass layer down a frame after us; zero alpha and
        // drop it now so its last sampled backdrop can't ghost over the app behind.
        contentView?.isHidden = true
        // A window `vanish()` leaves ordered would otherwise keep an alpha-immune
        // server-side glass residue over the app we're activating (#146).
        park()
        if orderingOut { orderOut(nil) }
        CATransaction.commit()
    }

    /// Convert a Cocoa global rect (bottom-left origin, y-up) to the CGEvent
    /// global coordinate space (top-left origin of the primary display, y-down)
    /// used by `CGEvent.location`. Multi-display safe: both spaces are anchored
    /// to the menu-bar screen, so the same primary-height flip applies to every
    /// display's coordinates.
    private static func cgGlobalFrame(from cocoaRect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?
            .frame.height ?? NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: cocoaRect.minX,
            y: primaryHeight - cocoaRect.maxY,
            width: cocoaRect.width,
            height: cocoaRect.height
        )
    }

    /// `.top` pins the top edge 20% down the visible frame (eye height, #175);
    /// a panel too tall for that slides up rather than spilling off the bottom.
    /// `hanging` is the window shelf's (#211) share of the height: `.center`
    /// centers the rest, so the switcher stays put while the shelf comes and goes.
    static func origin(of size: NSSize, in visible: NSRect, position: SwitcherVerticalPosition, hanging: CGFloat = 0) -> NSPoint {
        let x = visible.midX - size.width / 2
        switch position {
        case .center:
            let centered = visible.midY - (size.height + hanging) / 2
            return NSPoint(x: x, y: max(visible.minY, centered))
        case .top:
            let top = visible.maxY - visible.height * 0.2
            return NSPoint(x: x, y: max(visible.minY, top - size.height))
        }
    }

    func activeScreen() -> NSScreen {
        targetScreen ?? Self.preferredScreen()
    }

    /// Resolve the screen for `mode`. `mouseCursor`/`mainDisplay` are cheap live
    /// reads; `activeWindow` (the monitor being worked on — the bright-menu-bar
    /// display, or the frontmost app's window when displays share one Space) is
    /// supplied by the controller as `capturedScreen`, resolved off-main before
    /// our key panel stole frontmost. It falls back to cursor → main when
    /// unavailable (private API missing, no window to measure, or the capture not
    /// yet landed) — every signal it needs is off-main-only, so this stays free of
    /// AX/CGS work on the reveal path.
    static func preferredScreen(mode: SwitcherDisplayMode? = nil,
                                capturedScreen: NSScreen? = nil) -> NSScreen {
        switch mode ?? Preferences.shared.switcherDisplayMode {
        case .mouseCursor:
            return mouseScreen() ?? mainDisplayScreen()
        case .mainDisplay:
            return mainDisplayScreen()
        case .activeWindow:
            return capturedScreen ?? mouseScreen() ?? mainDisplayScreen()
        }
    }

    /// The `NSScreen` whose `CGDirectDisplayID` matches `displayID`, or nil when no
    /// live screen does (e.g. the display was unplugged between an off-main capture
    /// and this main-actor lookup). Main-actor only (`NSScreen.screens`).
    static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// Screen under the mouse pointer, or nil if the pointer is off all screens.
    static func mouseScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = ScreenSelection.index(
            containing: NSEvent.mouseLocation,
            in: screens,
            frame: { $0.frame }
        ) else { return nil }
        return screens[index]
    }

    /// "Main display" from System Settings → Displays — the origin-zero screen.
    /// `NSScreen.main` is intentionally only a fallback: it means "screen with
    /// the key window", which is the active screen, not the primary.
    static func mainDisplayScreen() -> NSScreen {
        // "Main display" = the origin-zero screen. Found directly (no [CGRect]
        // allocation); ScreenSelection.mainDisplayIndex stays for unit tests.
        if let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return main
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
