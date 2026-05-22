import AppKit

@MainActor
final class SwitcherPanel: NSPanel {
    init() {
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
        makeKeyAndOrderFront(nil)
        CATransaction.commit()
    }

    func dismiss() {
        orderOut(nil)
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
