import AppKit
import ObjectiveC

@MainActor
final class SwitcherPanel: NSPanel {
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
        CATransaction.commit()
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
