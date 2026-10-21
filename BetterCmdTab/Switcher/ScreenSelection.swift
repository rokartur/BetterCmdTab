import CoreGraphics
import Foundation

/// Pure screen-picking geometry, split out from `NSScreen` so it is unit
/// testable without a live WindowServer. Each function's rects share one
/// coordinate space supplied by the caller: Cocoa for screen picking, CG
/// (top-left origin) for `pointerWarpTarget`.
enum ScreenSelection {

    /// Index of the screen containing the cursor `point`, or nil when the
    /// point is in a gap/outside the current display arrangement. Uses
    /// `NSMouseInRect`'s unflipped convention rather than `CGRect.contains`:
    /// a cursor resting at the top edge of a display reports
    /// `y == frame.maxY`, so the top edge is inside and the bottom edge
    /// outside; x keeps `[minX, maxX)`. The first match preserves the
    /// caller's ordering if display frames overlap.
    static func index<C: Collection>(
        containing point: CGPoint,
        in candidates: C,
        frame: (C.Element) -> CGRect
    ) -> C.Index? {
        candidates.firstIndex { candidate in
            let r = frame(candidate)
            return point.x >= r.minX && point.x < r.maxX
                && point.y > r.minY && point.y <= r.maxY
        }
    }

    /// Index of the screen frame with the greatest area of overlap with `rect`.
    /// Returns nil when `screenFrames` is empty or nothing overlaps `rect`.
    static func indexOfMaxOverlap(rect: CGRect, screenFrames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (i, frame) in screenFrames.enumerated() {
            let inter = frame.intersection(rect)
            guard !inter.isNull else { continue }
            let area = max(0, inter.width) * max(0, inter.height)
            guard area > 0 else { continue }
            if best == nil || area > best!.area { best = (i, area) }
        }
        return best?.index
    }

    /// Center of the display holding most of `windowBounds`, or nil when the
    /// pointer is already over the window or on that display. All values in CG global space.
    static func pointerWarpTarget(windowBounds: CGRect, pointer: CGPoint, displayBounds: [CGRect]) -> CGPoint? {
        guard !windowBounds.contains(pointer),
              let i = indexOfMaxOverlap(rect: windowBounds, screenFrames: displayBounds),
              !displayBounds[i].contains(pointer) else { return nil }
        return CGPoint(x: displayBounds[i].midX, y: displayBounds[i].midY)
    }

    /// Index of the "Main display" — the screen whose frame origin is (0, 0),
    /// matching System Settings → Displays. Returns nil when none is at origin.
    static func mainDisplayIndex(screenFrames: [CGRect]) -> Int? {
        screenFrames.firstIndex { $0.origin == .zero }
    }

    /// What a display mode needs the switcher's off-main capture to resolve
    /// before the panel can be placed. Pure mapping, kept out of the controller
    /// so the "which signal does this mode follow" decision is testable on its
    /// own.
    ///
    /// `separateSpaces` is `NSScreen.screensHaveSeparateSpaces`, and it is the
    /// whole reason `.activeWindow` isn't a fixed answer. The menu-bar display
    /// (`SLSCopyActiveMenuBarDisplayIdentifier`) is a Spaces concept: it only
    /// tells displays apart when that setting is ON. With one Space spanning
    /// every display there is a single menu bar, on the main display, so the
    /// call always succeeds with the same answer and "the monitor I'm working on"
    /// silently collapses into "main display". Reading the frontmost app's own
    /// window geometry is what holds in that configuration — and asking for the
    /// menu bar *first* is what would break it, because a successful wrong answer
    /// never falls through.
    enum CaptureNeed {
        /// The monitor showing the active Space (bright menu bar).
        case activeMonitor
        /// The monitor the frontmost app's window sits on.
        case activeApp
        /// Nothing to capture: the panel resolves cursor/main-display live on the
        /// main actor, so the open path must not pay for an off-main capture.
        case live

        init(_ mode: SwitcherDisplayMode, separateSpaces: Bool) {
            switch mode {
            case .activeWindow: self = separateSpaces ? .activeMonitor : .activeApp
            case .mouseCursor, .mainDisplay: self = .live
            }
        }
    }

    /// Where the switcher panel should open, as resolved off the main thread.
    /// Plain values only: `NSScreen.screens` is main-thread-only, so a capture
    /// can't name a screen, so the caller places it back on the main actor.
    enum CaptureTarget {
        case displayID(CGDirectDisplayID)
        case axBounds(CGRect)
    }

    /// Flip a rect from Accessibility coordinates (top-left origin of the primary
    /// display, y-down) into Cocoa coordinates (bottom-left origin, y-up).
    /// `primaryMaxY` is the primary ("Main display") height — pass the origin-zero
    /// screen's `frame.maxY`, which equals its height since its `minY` is 0. Both
    /// spaces are anchored to that screen's corner, so this one flip is correct
    /// for windows on every display — including secondaries above/below (Cocoa y
    /// past the primary's range) or to the left (negative x, carried unchanged).
    static func cocoaRect(forAXBounds ax: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: ax.minX,
            y: primaryMaxY - ax.minY - ax.height,
            width: ax.width,
            height: ax.height
        )
    }
}
