import Testing
import CoreGraphics
@testable import BetterCmdTab

/// Pure-logic coverage for the tap-swallowed panel-click mapping (#36). The
/// tap hit-tests clicks against the panel frame in CGEvent global coordinates
/// (top-left origin, y-down) and hands the controller a window-local point
/// (bottom-left origin, y-up); both inputs share the CG space, so the flip
/// must be exact without any screen lookup.
@Suite("Panel click window-point mapping")
struct HotkeyTapPanelClickTests {

    /// Panel frame in CGEvent global coordinates: 400×300 at (100, 50).
    private let frame = CGRect(x: 100, y: 50, width: 400, height: 300)

    @Test func topLeftCornerMapsToWindowTopEdge() {
        // CG top-left corner of the panel is AppKit's (0, height): y flips.
        let p = HotkeyTap.windowPoint(forClick: CGPoint(x: 100, y: 50), inPanelFrame: frame)
        #expect(p == CGPoint(x: 0, y: 300))
    }

    @Test func bottomRightCornerMapsToWindowOriginSide() {
        let p = HotkeyTap.windowPoint(forClick: CGPoint(x: 500, y: 350), inPanelFrame: frame)
        #expect(p == CGPoint(x: 400, y: 0))
    }

    @Test func interiorPointFlipsOnlyY() {
        // 30pt below the CG top edge is 30pt below the AppKit top edge too.
        let p = HotkeyTap.windowPoint(forClick: CGPoint(x: 250, y: 80), inPanelFrame: frame)
        #expect(p == CGPoint(x: 150, y: 270))
    }

    @Test func mappingIsFrameRelative() {
        // The same in-panel offset yields the same window point wherever the
        // panel sits on any display — the global origin must cancel out.
        let moved = frame.offsetBy(dx: -2000, dy: 700)  // e.g. a second display
        let p1 = HotkeyTap.windowPoint(forClick: CGPoint(x: 250, y: 80), inPanelFrame: frame)
        let p2 = HotkeyTap.windowPoint(
            forClick: CGPoint(x: 250 - 2000, y: 80 + 700), inPanelFrame: moved)
        #expect(p1 == p2)
    }
}
