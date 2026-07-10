import CoreGraphics
import Foundation
import Testing
@testable import BetterCmdTab

@Suite("ScreenSelection")
struct ScreenSelectionTests {

    // Two side-by-side 1000x1000 displays: A at origin, B to its right.
    private let screenA = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    private let screenB = CGRect(x: 1000, y: 0, width: 1000, height: 1000)

    @Test("cursor on the second screen picks that screen")
    func cursorOnSecondScreen() {
        #expect(ScreenSelection.index(
            containing: CGPoint(x: 1500, y: 500),
            in: [screenA, screenB],
            frame: { $0 }
        ) == 1)
    }

    @Test("cursor selection supports displays in every direction")
    func cursorOnOffsetScreens() {
        let left = CGRect(x: -1000, y: 0, width: 1000, height: 1000)
        let above = CGRect(x: 0, y: 1000, width: 1000, height: 1000)
        let below = CGRect(x: 0, y: -1000, width: 1000, height: 1000)

        #expect(ScreenSelection.index(
            containing: CGPoint(x: -500, y: 500), in: [screenA, left], frame: { $0 }
        ) == 1)
        #expect(ScreenSelection.index(
            containing: CGPoint(x: 500, y: 1500), in: [screenA, above], frame: { $0 }
        ) == 1)
        #expect(ScreenSelection.index(
            containing: CGPoint(x: 500, y: -500), in: [screenA, below], frame: { $0 }
        ) == 1)
    }

    @Test("cursor in a gap between displays has no screen")
    func cursorInDisplayGap() {
        let separated = CGRect(x: 1200, y: 0, width: 1000, height: 1000)
        #expect(ScreenSelection.index(
            containing: CGPoint(x: 1100, y: 500), in: [screenA, separated], frame: { $0 }
        ) == nil)
    }

    @Test("cursor on a shared edge belongs to only the adjoining screen")
    func cursorOnSharedEdge() {
        #expect(ScreenSelection.index(
            containing: CGPoint(x: 1000, y: 500), in: [screenA, screenB], frame: { $0 }
        ) == 1)
    }

    @Test("cursor at the top edge of a display belongs to that display")
    func cursorOnTopEdge() {
        // NSEvent.mouseLocation reports y == frame.maxY when the cursor rests
        // against the top of a screen (e.g. flung toward the menu bar), so the
        // top edge must be inside — CGRect.contains semantics return nil here
        // and silently fall back to the main display (#93).
        #expect(ScreenSelection.index(
            containing: CGPoint(x: 500, y: 1000), in: [screenA, screenB], frame: { $0 }
        ) == 0)
    }

    @Test("stacked displays: the shared horizontal edge belongs to the lower screen")
    func cursorOnStackedSharedEdge() {
        let above = CGRect(x: 0, y: 1000, width: 1000, height: 1000)
        #expect(ScreenSelection.index(
            containing: CGPoint(x: 500, y: 1000), in: [above, screenA], frame: { $0 }
        ) == 1)
    }

    @Test("window fully on the second screen picks that screen")
    func fullyOnSecond() {
        let win = CGRect(x: 1200, y: 200, width: 400, height: 300)
        #expect(ScreenSelection.indexOfMaxOverlap(rect: win, screenFrames: [screenA, screenB]) == 1)
    }

    @Test("straddling window picks the screen with the larger overlap")
    func straddlePicksLargerOverlap() {
        // 600 wide window from x=800: 200pt on A (800..1000), 400pt on B (1000..1400).
        let win = CGRect(x: 800, y: 200, width: 600, height: 300)
        #expect(ScreenSelection.indexOfMaxOverlap(rect: win, screenFrames: [screenA, screenB]) == 1)
    }

    @Test("window matching no screen returns nil")
    func noOverlapIsNil() {
        let win = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        #expect(ScreenSelection.indexOfMaxOverlap(rect: win, screenFrames: [screenA, screenB]) == nil)
    }

    @Test("empty screen list returns nil")
    func emptyScreensIsNil() {
        #expect(ScreenSelection.indexOfMaxOverlap(rect: screenA, screenFrames: []) == nil)
    }

    @Test("main display is the origin-zero screen regardless of array order")
    func mainDisplayIsOriginZero() {
        // B (non-zero origin) listed first; A (origin zero) second.
        #expect(ScreenSelection.mainDisplayIndex(screenFrames: [screenB, screenA]) == 1)
    }

    @Test("main display nil when no screen sits at the origin")
    func mainDisplayNilWhenNoOrigin() {
        let offset = CGRect(x: 10, y: 10, width: 1000, height: 1000)
        #expect(ScreenSelection.mainDisplayIndex(screenFrames: [screenB, offset]) == nil)
    }

    @Test("equal overlap on two screens picks the first one")
    func equalOverlapPicksFirstScreen() {
        // 600 wide window from x=700: 300pt on A (700..1000), 300pt on B (1000..1300).
        // Equal area → the strict `>` keeps the earliest max, so A (index 0) wins.
        let win = CGRect(x: 700, y: 200, width: 600, height: 300)
        #expect(ScreenSelection.indexOfMaxOverlap(rect: win, screenFrames: [screenA, screenB]) == 0)
    }

    @Test("a screen touched only on its edge with zero area is not chosen")
    func edgeTouchingScreenIsNotChosen() {
        // Window lies entirely on B (1000..1500); its left edge touches A at x=1000
        // with a zero-width intersection. A's zero-area touch is skipped, B wins.
        let win = CGRect(x: 1000, y: 200, width: 500, height: 300)
        #expect(ScreenSelection.indexOfMaxOverlap(rect: win, screenFrames: [screenA, screenB]) == 1)
    }

    // AX bounds are top-left origin / y-down, anchored at the primary display's
    // top; Cocoa is bottom-left / y-up. Primary here is 1000pt tall (maxY=1000).
    @Test("AX→Cocoa flip mirrors y for a window on the primary display")
    func axFlipOnPrimary() {
        // 100pt below the primary's top, 300pt tall: Cocoa bottom = 1000-100-300.
        let cocoa = ScreenSelection.cocoaRect(forAXBounds: CGRect(x: 200, y: 100, width: 400, height: 300), primaryMaxY: 1000)
        #expect(cocoa == CGRect(x: 200, y: 600, width: 400, height: 300))
    }

    @Test("AX→Cocoa flip carries x through for a right-hand secondary")
    func axFlipOnRightSecondary() {
        // Secondary to the right shares the y-axis; only x differs. Top-aligned:
        // Cocoa bottom = 1000-0-500.
        let cocoa = ScreenSelection.cocoaRect(forAXBounds: CGRect(x: 1200, y: 0, width: 400, height: 500), primaryMaxY: 1000)
        #expect(cocoa == CGRect(x: 1200, y: 500, width: 400, height: 500))
    }

    @Test("AX→Cocoa flip yields y above the primary for a top secondary")
    func axFlipOnTopSecondary() {
        // Display ABOVE primary → negative AX y. Cocoa bottom = 1000-(-400)-300 =
        // 1100, i.e. past the primary's top edge.
        let cocoa = ScreenSelection.cocoaRect(forAXBounds: CGRect(x: 0, y: -400, width: 200, height: 300), primaryMaxY: 1000)
        #expect(cocoa == CGRect(x: 0, y: 1100, width: 200, height: 300))
    }

    @Test("AX→Cocoa flip yields negative y for a bottom secondary")
    func axFlipOnBottomSecondary() {
        // Display BELOW primary → AX y past the primary's height. Cocoa bottom =
        // 1000-1100-300 = -400.
        let cocoa = ScreenSelection.cocoaRect(forAXBounds: CGRect(x: 0, y: 1100, width: 200, height: 300), primaryMaxY: 1000)
        #expect(cocoa == CGRect(x: 0, y: -400, width: 200, height: 300))
    }

    @Test("flip then max-overlap picks the secondary a reordered window sits on")
    func axFlipComposedPicksCorrectScreen() {
        // End-to-end of the pure half: AX (1200,0,400,500) on the right secondary
        // B flips to Cocoa (1200,500,400,500) and resolves to B (index 1) — the
        // result is independent of which screen happened to be `screens.first`.
        let cocoa = ScreenSelection.cocoaRect(forAXBounds: CGRect(x: 1200, y: 0, width: 400, height: 500), primaryMaxY: 1000)
        #expect(ScreenSelection.indexOfMaxOverlap(rect: cocoa, screenFrames: [screenA, screenB]) == 1)
    }
}
