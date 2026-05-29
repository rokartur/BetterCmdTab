import AppKit
import Combine
import ObjectiveC

@MainActor
final class SwitcherPanel: NSPanel {
    private var prefCancellable: AnyCancellable?

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
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
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
        guard isVisible else {
            super.resignKey()
            return
        }
        // Swallow `super.resignKey()` to suppress the glass dim animation's
        // notification — but the internal `_isKey` has already flipped to false,
        // so without reclaiming, the panel stops being key: its controls (hover
        // action buttons) stop receiving clicks and keyboard focus drifts. Re-key
        // on the next runloop so the panel stays interactive while it's on screen.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            self.makeKeyAndOrderFront(nil)
        }
    }

    func present() {
        guard let content = contentView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let screen = activeScreen()
        let visible = screen.visibleFrame
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
        alphaValue = CGFloat(Preferences.shared.panelOpacity) / 100
        makeKeyAndOrderFront(nil)
        // Activate the app while the switcher is shown. `NSGlassEffectView`'s
        // active/inactive look is decided window-server-side from the owning app's
        // real activation state — the in-process `appearsActive` override can't
        // reach it — so a non-activating accessory app's glass renders dimmed
        // unless we actually become active. The controller captured the previously
        // frontmost app first and restores it on cancel.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        CATransaction.commit()
        onFrameDidChange?(Self.cgGlobalFrame(from: frame))
        // A non-activating panel isn't always granted key on the first
        // `makeKeyAndOrderFront` if another app is mid-activation when the switcher
        // opens; re-key on the next runloop (same approach as `resignKey`) so the
        // panel always holds key while it's on screen.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            self.makeKeyAndOrderFront(nil)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alphaValue = 0
        // Hiding the content view tears the glass/visual-effect layer out of the
        // compositor in the same transaction as `orderOut`, so the window server
        // has no last-sampled backdrop left to flash as a ghost after we vanish.
        // `present()` un-hides it.
        contentView?.isHidden = true
        orderOut(nil)
        CATransaction.commit()
        onFrameDidChange?(nil)
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
        Self.preferredScreen()
    }

    static func preferredScreen() -> NSScreen {
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            return mouseScreen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
