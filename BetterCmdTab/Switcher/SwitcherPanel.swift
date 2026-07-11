import AppKit
import Combine
import ObjectiveC
import os

@MainActor
final class SwitcherPanel: NSPanel {
    enum SpaceVisibilityDecision: Equatable {
        case none
        /// Healthy on the first sample — confirm once after a short delay, in
        /// case both AppKit indicators still carry the previous presentation's
        /// healthy values (fast dismiss→reopen).
        case verify
        /// Unhealthy on the first sample — occlusion may simply be stale this
        /// soon after order-front; re-sample before healing.
        case retry
        case heal
    }

    struct SpaceCheckGeneration {
        private(set) var value: UInt = 0

        @discardableResult
        mutating func advance() -> UInt {
            value &+= 1
            return value
        }

        func matches(_ token: UInt) -> Bool { value == token }
    }

    /// The complete, known-good Space behavior for this transient system
    /// overlay. `.canJoinAllApplications` (macOS 13+) explicitly lets overlays
    /// join other apps' full-screen and Stage Manager sets, while
    /// `.canJoinAllSpaces` keeps it available across per-display Desktops (#93).
    static let canonicalCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .stationary,
        .ignoresCycle,
        .fullScreenAuxiliary,
        .canJoinAllApplications
    ]

    private static let spaceVisibilityRetryDelay: TimeInterval = 0.05
    private static let spaceTransitionSettleDelay: TimeInterval = 0.20
    private static let spaceRecoveryVerificationDelay: TimeInterval = 0.10
    private static let maxSpaceRecoveryAttempts = 2

    private var prefCancellable: AnyCancellable?
    /// Invalidates delayed WindowServer visibility checks across dismiss/reopen
    /// and across consecutive Space changes. Without this token, a retry queued
    /// by presentation A can reorder a rapidly-opened presentation B (#64).
    private var spaceCheckGeneration = SpaceCheckGeneration()
    /// True between `present()` and `dismiss()`. The reveal edge can't key off
    /// `isVisible` alone: the boot prewarm orders the panel in off-screen via
    /// `orderFrontRegardless()` without presenting, and a chord landing in that
    /// window would then read `isVisible == true` and skip the first real
    /// presentation's Space verification.
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
        // `isPresented` (not just ordered-in): after a commit `vanish()`es the
        // panel it stays ordered until the AX focus writes settle — re-keying
        // then would re-activate this app and yank focus from the very window
        // the commit is activating.
        guard isVisible, isPresented else {
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
        // `present()` also relays out an already-visible panel during live
        // filtering. Only a real hidden→visible edge starts a new verification
        // generation; relayouts remain part of the current presentation.
        let startsNewPresentation = Self.shouldStartSpaceVerification(isAlreadyVisible: isPresented)
        isPresented = true
        if startsNewPresentation { spaceCheckGeneration.advance() }
        let spaceCheckToken = spaceCheckGeneration.value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
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
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        let newFrame = NSRect(origin: origin, size: size)
        if frame != newFrame {
            setFrame(newFrame, display: true)
        }
        // Restore opacity that `dismiss()` zeroed to mask the glass-layer
        // teardown ghost, and un-hide the content `dismiss()` hid to drop the
        // glass sample. Reset before ordering on screen so the first frame is
        // shown at the user's chosen opacity (no fade — `animationBehavior` is
        // `.none`).
        content.isHidden = false
        alphaValue = CGFloat(opacity) / 100
        // `vanish()` turned mouse events off for its invisible linger window.
        ignoresMouseEvents = false
        // The WindowServer order-front + app activation; split out so Instruments
        // shows it apart from the autolayout pass above when chasing reveal spikes.
        Log.reveal.withIntervalSignpost("present.orderFront") {
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
        onFrameDidChange?(Self.cgGlobalFrame(from: frame))
        // A non-activating panel isn't always granted key on the first
        // `makeKeyAndOrderFront` if another app is mid-activation when the switcher
        // opens; re-key on the next runloop (same approach as `resignKey`) so the
        // panel always holds key while it's on screen.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.isPresented else { return }
            if !self.isKeyWindow { self.makeKeyAndOrderFront(nil) }
            // Live filtering and title/badge refreshes call present() again only
            // to relayout. They must not fork parallel recovery chains; the one
            // started at the hidden→visible edge owns this presentation.
            // Sample immediately so a rotted panel heals at ~50ms; a healthy
            // first verdict is re-confirmed once (`.verify`) because both AppKit
            // indicators can briefly retain the previous presentation's values.
            if startsNewPresentation {
                self.healSpaceAssignmentIfNeeded(token: spaceCheckToken)
            }
        }
    }

    /// Hide the panel. `NSGlassEffectView` / `NSVisualEffectView` is a
    /// window-server-hosted layer that samples a live blur of whatever app
    /// sits behind the panel. A plain `orderOut(nil)` removes the host window
    /// immediately, but the server tears down that out-of-process glass layer
    /// a frame or two later — compositing its last sampled backdrop (a
    /// "cutout" of the app behind us) as a ghost artifact after we've already
    /// vanished. Zeroing `alphaValue` in the same transaction as `orderOut`
    /// makes any such residual frame fully transparent; `present()` restores
    /// it. No fade plays because `animationBehavior` is `.none` and implicit
    /// actions are disabled here.
    func dismiss() {
        // Cancel every queued visibility retry before the panel can be opened as
        // a new presentation. The closures remain cheap no-ops when they fire.
        spaceCheckGeneration.advance()
        isPresented = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alphaValue = 0
        // Hiding the content view tears the glass/visual-effect layer out of the
        // compositor in the same transaction as `orderOut`, so the window server
        // has no last-sampled backdrop left to flash as a ghost after we vanish.
        // `present()` un-hides it.
        contentView?.isHidden = true
        orderOut(nil)
        targetScreen = nil
        CATransaction.commit()
        onFrameDidChange?(nil)
    }

    /// Instant visual hide at commit time. The real `orderOut` (`dismiss()`)
    /// deliberately waits for the activation's off-main AX focus writes, but the
    /// user must not watch the panel linger while a busy target app runs those
    /// calls into their timeouts. Same transaction shape as `dismiss()` minus
    /// the order-out — the window stays ordered, so WindowServer focus routing
    /// is unchanged; `ignoresMouseEvents` keeps the invisible panel from
    /// swallowing clicks until `dismiss()` lands. `present()` restores both.
    func vanish() {
        spaceCheckGeneration.advance()
        isPresented = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alphaValue = 0
        contentView?.isHidden = true
        CATransaction.commit()
        ignoresMouseEvents = true
        onFrameDidChange?(nil)
    }

    /// A visible `present()` call is only a relayout. Space verification belongs
    /// to the hidden→visible reveal edge and must have one owner per session.
    static func shouldStartSpaceVerification(isAlreadyVisible: Bool) -> Bool {
        !isAlreadyVisible
    }

    /// The WindowServer can lose the `.canJoinAllSpaces` sticky tag when the
    /// Space topology changes while the panel is ordered out — e.g. quitting a
    /// full-screen app destroys its Space (#46, #64), or the active Space flips
    /// onto another display's or a live full-screen app's Space (#93/#94). The
    /// next order-front then puts the panel only on its original Space:
    /// switching still works, but the panel is invisible everywhere else.
    /// `isOnActiveSpace` alone can't detect this — for a canJoinAllSpaces window
    /// it can keep reporting true after the WindowServer has dropped the tag
    /// (#93/#94), so also require the panel to actually composite
    /// (`occlusionState.visible`; at `.popUpMenu`
    /// level nothing covers it, so on the active Space it is always visible).
    /// Occlusion state is delivered asynchronously from the WindowServer and
    /// may still be stale one runloop turn after order-front — in either
    /// direction: an unhealthy first verdict is confirmed before healing
    /// (`.retry`), and a healthy first verdict is re-checked once (`.verify`)
    /// because fast dismiss→reopen can leave both indicators reporting the
    /// previous presentation's healthy state. Runs after `present()`; the
    /// healthy path costs two property reads plus one settled confirm.
    static func spaceVisibilityDecision(
        isVisible: Bool,
        isOnActiveSpace: Bool,
        isOcclusionVisible: Bool,
        isRetry: Bool
    ) -> SpaceVisibilityDecision {
        guard isVisible else { return .none }
        guard isOnActiveSpace, isOcclusionVisible else {
            return isRetry ? .heal : .retry
        }
        return isRetry ? .none : .verify
    }

    private func healSpaceAssignmentIfNeeded(
        token: UInt,
        isRetry: Bool = false,
        recoveryAttempt: Int = 0
    ) {
        guard spaceCheckGeneration.matches(token) else { return }
        let onActiveSpace = isOnActiveSpace
        let decision = Self.spaceVisibilityDecision(
            isVisible: isVisible,
            isOnActiveSpace: onActiveSpace,
            isOcclusionVisible: occlusionState.contains(.visible),
            isRetry: isRetry
        )
        switch decision {
        case .none:
            return
        case .verify, .retry:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.spaceVisibilityRetryDelay) { [weak self] in
                self?.healSpaceAssignmentIfNeeded(
                    token: token,
                    isRetry: true,
                    recoveryAttempt: recoveryAttempt
                )
            }
            return
        case .heal:
            break
        }

        guard recoveryAttempt < Self.maxSpaceRecoveryAttempts else {
            Log.ui.fault("panel still not compositing after bounded Space recovery (#46/#64/#93/#94)")
            return
        }
        Log.ui.error("panel \(onActiveSpace ? "not compositing on active Space" : "not on active Space") after reveal/Space change — re-asserting canJoinAllSpaces (#46/#64/#93/#94)")
        reassertAllSpacesTag()
        orderOut(nil)
        makeKeyAndOrderFront(nil)
        // Unlike `orderFront`, this is honored even if a Space transition made
        // another app active between the visibility verdict and the recovery.
        orderFrontRegardless()

        // WindowServer state is asynchronous. Verify the repair and allow one
        // additional bounded recovery instead of assuming the first re-order
        // succeeded under load.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spaceRecoveryVerificationDelay) { [weak self] in
            self?.healSpaceAssignmentIfNeeded(
                token: token,
                // A recovery starts a fresh pair of samples. One stale-negative
                // verdict must not immediately trigger another visible re-order.
                isRetry: false,
                recoveryAttempt: recoveryAttempt + 1
            )
        }
    }

    /// A Space can change while the switcher is deliberately kept open (sticky
    /// mode, swipe trigger). Hidden panels can safely refresh their WindowServer
    /// tag immediately; visible panels wait for the transition's occlusion state
    /// to settle and then use the same bounded verifier as a fresh reveal.
    func activeSpaceDidChange() {
        let token = spaceCheckGeneration.advance()
        guard isVisible else {
            reassertAllSpacesTag()
            return
        }
        // NSWorkspace posts at the active-Space edge, while the WindowServer's
        // visual transition and occlusion bookkeeping may continue briefly.
        // Debounce that transition before taking the first sample; a second
        // unhealthy sample is still required by `spaceVisibilityDecision`.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spaceTransitionSettleDelay) { [weak self] in
            self?.healSpaceAssignmentIfNeeded(token: token)
        }
    }

    /// Force the WindowServer to re-apply the collection behavior. Re-assigning
    /// an identical mask may be short-circuited, so clear it first; the empty
    /// intermediate state is never user-visible (the panel is hidden or on the
    /// wrong Space whenever this runs).
    func reassertAllSpacesTag() {
        collectionBehavior = []
        // Restore the canonical mask, not the value we just read: AppKit may
        // lose the property bit as well as WindowServer's internal sticky tag.
        collectionBehavior = Self.canonicalCollectionBehavior
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

    private func activeScreen() -> NSScreen {
        targetScreen ?? Self.preferredScreen()
    }

    /// Resolve the screen for `mode`. `mouseCursor`/`mainDisplay` are cheap live
    /// reads; `activeWindow` (the active monitor — the bright-menu-bar / focused
    /// display) is supplied by the controller (`activeWindowScreen`), captured
    /// before our key panel stole frontmost — it falls back to cursor → main when
    /// unavailable (private API missing, or the capture not yet landed).
    static func preferredScreen(mode: SwitcherDisplayMode? = nil,
                                activeWindowScreen: NSScreen? = nil) -> NSScreen {
        switch mode ?? Preferences.shared.switcherDisplayMode {
        case .mouseCursor:
            return mouseScreen() ?? mainDisplayScreen()
        case .mainDisplay:
            return mainDisplayScreen()
        case .activeWindow:
            return activeWindowScreen ?? mouseScreen() ?? mainDisplayScreen()
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
